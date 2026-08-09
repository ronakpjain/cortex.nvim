-- Unit tests for the pure Lua cortex-debug DAP adapter.
--
--   nvim --headless --clean -u NONE -l tests/test_adapter.lua

local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local A = require('cortex.adapter')

local failures, total = 0, 0

local function check(name, ok, extra)
  total = total + 1
  if ok then
    io.stdout:write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.stdout:write('FAIL ' .. name .. (extra and ('\n     ' .. tostring(extra)) or '') .. '\n')
  end
end

local function eq(name, got, want)
  local ok = vim.deep_equal(got, want)
  check(name, ok, not ok and ('got: ' .. vim.inspect(got) .. '\nwant: ' .. vim.inspect(want)) or nil)
end

-------------------------------------------------------------------- helpers

eq('as_int hex', A.as_int('0x2000'), 0x2000)
eq('as_int dec', A.as_int('42'), 42)
eq('as_int default', A.as_int(nil, 7), 7)
eq('as_int garbage', A.as_int('abc', 3), 3)
eq('mi_quote', A.mi_quote('a"b\\c'), '"a\\"b\\\\c"')
eq('as_list scalar', A.as_list('x'), { 'x' })
eq('as_list list', A.as_list({ 1, 2 }), { 1, 2 })
eq('as_list dict', A.as_list({ a = 1 }), { { a = 1 } })
eq('as_list nil', A.as_list(nil), {})

-------------------------------------------------------------- var expansion

local vars = A.build_variable_table({ cwd = '/tmp/proj' })
eq('vars workspaceRoot', vars.workspaceRoot, '/tmp/proj')
eq(
  'expand string',
  A.expand_variables('${workspaceRoot}/build/app.elf', vars),
  '/tmp/proj/build/app.elf'
)
eq(
  'expand nested',
  A.expand_variables({ configFiles = { '${workspaceRoot}/x.cfg' } }, vars),
  { configFiles = { '/tmp/proj/x.cfg' } }
)
eq('expand unknown kept', A.expand_variables('${nope}', vars), '${nope}')

-------------------------------------------------------------------- framing

local encoded = A.encode_message({ type = 'event', event = 'initialized' })
check('encode has header', encoded:match('^Content%-Length: %d+\r\n\r\n') ~= nil, encoded)

local reader = A.Reader.new()
local msgs = reader:feed(encoded)
eq('reader one message', #msgs, 1)
eq('reader event', msgs[1].event, 'initialized')

-- split across chunks
reader = A.Reader.new()
local half = math.floor(#encoded / 2)
eq('reader partial', #reader:feed(encoded:sub(1, half)), 0)
local rest = reader:feed(encoded:sub(half + 1))
eq('reader completes', #rest, 1)

-- two messages in one chunk
reader = A.Reader.new()
eq('reader two', #reader:feed(encoded .. encoded), 2)

-------------------------------------------------------------------- MI parse

eq('c-string simple', (A.parse_c_string('"hello"')), 'hello')
eq('c-string escapes', (A.parse_c_string('"a\\nb\\\\c\\"d"')), 'a\nb\\c"d')

local rec = A.parse_mi_line('^done,value="0x1234"')
eq('result class', rec.class, 'done')
eq('result type', rec.type, 'result')
eq('result value', rec.results.value, '0x1234')

rec = A.parse_mi_line('42^done,bkpt={number="1",type="breakpoint",line="17"}')
eq('token', rec.token, 42)
eq('bkpt number', rec.results.bkpt.number, '1')
eq('bkpt line', rec.results.bkpt.line, '17')

rec = A.parse_mi_line('*stopped,reason="breakpoint-hit",bkptno="1",thread-id="1",frame={func="main",line="12"}')
eq('async type', rec.type, 'exec')
eq('async class', rec.class, 'stopped')
eq('async reason', rec.results.reason, 'breakpoint-hit')
eq('async bkptno', rec.results.bkptno, '1')
eq('async frame func', rec.results.frame.func, 'main')

rec = A.parse_mi_line('^done,stack=[frame={level="0",addr="0x08000100",func="main",file="m.c",fullname="/p/m.c",line="12"},frame={level="1",func="_start"}]')
eq('stack len', #rec.results.stack, 2)
eq('stack[1].func', rec.results.stack[1].func, 'main')
eq('stack[2].func', rec.results.stack[2].func, '_start')

rec = A.parse_mi_line('~"reading symbols\\n"')
eq('stream type', rec.type, 'stream')
eq('stream kind', rec.stream, 'console')
eq('stream output', rec.output, 'reading symbols\n')

eq('prompt', A.parse_mi_line('(gdb)').type, 'prompt')
eq('unknown', A.parse_mi_line('garbage here').type, 'unknown')

rec = A.parse_mi_line('^error,msg="No symbol \\"foo\\" in current context."')
eq('error class', rec.class, 'error')
check('record_ok false', A.record_ok(rec) == false)
eq('record_error', A.record_error(rec), 'No symbol "foo" in current context.')

rec = A.parse_mi_line('^done,threads=[{id="1",target-id="Thread 1",name="cortex"}],current-thread-id="1"')
eq('threads id', rec.results.threads[1].id, '1')
eq('current thread', rec.results['current-thread-id'], '1')

rec = A.parse_mi_line('^done,register-names=["r0","r1","","pc"]')
eq('register names', rec.results['register-names'], { 'r0', 'r1', '', 'pc' })

------------------------------------------------------------ openocd cmdline

eq('openocd defaults', A.build_openocd_argv({ configFiles = { 'i/stlink.cfg', 't/stm32f4x.cfg' } }), {
  'openocd',
  '-f',
  'i/stlink.cfg',
  '-f',
  't/stm32f4x.cfg',
  '-c',
  'gdb_port 3333',
  '-c',
  'telnet_port 4444',
})

eq('openocd custom', A.build_openocd_argv({
  serverpath = '/opt/openocd',
  searchDir = '/scripts',
  configFiles = 'board.cfg',
  gdbPort = 50000,
  telnetPort = 50001,
  openOCDLaunchCommands = { 'adapter speed 4000' },
  serverArgs = { '-d2' },
}), {
  '/opt/openocd',
  '-s',
  '/scripts',
  '-f',
  'board.cfg',
  '-c',
  'gdb_port 50000',
  '-c',
  'telnet_port 50001',
  '-c',
  'adapter speed 4000',
  '-d2',
})

--------------------------------------------------------- adapter unit bits

local adapter = A.Adapter.new()
local sent = {}
adapter._write = function(_, message)
  sent[#sent + 1] = message
end

adapter:on_initialize({ seq = 1, command = 'initialize' })
eq('initialize response', sent[1].command, 'initialize')
check('initialize success', sent[1].success == true)
check('supportsConfigurationDoneRequest', sent[1].body.supportsConfigurationDoneRequest == true)
check('supportsTerminateRequest', sent[1].body.supportsTerminateRequest == true)
check('supportsEvaluateForHovers', sent[1].body.supportsEvaluateForHovers == true)

sent = {}
adapter.current_thread = 1
adapter:_handle_stopped({ reason = 'breakpoint-hit', bkptno = '2', ['thread-id'] = '1' })
eq('stopped event', sent[1].event, 'stopped')
eq('stopped reason (pre-configurationDone => entry)', sent[1].body.reason, 'entry')
adapter.configuration_done = true
sent = {}
adapter:_handle_stopped({ reason = 'breakpoint-hit', bkptno = '2', ['thread-id'] = '1' })
eq('stopped reason breakpoint', sent[1].body.reason, 'breakpoint')
eq('hitBreakpointIds', sent[1].body.hitBreakpointIds, { 2 })
check('allThreadsStopped', sent[1].body.allThreadsStopped == true)

sent = {}
adapter:_handle_stopped({ reason = 'end-stepping-range', ['thread-id'] = '1' })
eq('stopped reason step', sent[1].body.reason, 'step')

sent = {}
adapter:_on_gdb_async({ class = 'running', results = { ['thread-id'] = 'all' } })
eq('continued event', sent[1].event, 'continued')
check('allThreadsContinued', sent[1].body.allThreadsContinued == true)

sent = {}
adapter:_handle_stopped({ reason = 'exited-normally', ['exit-code'] = '0' })
eq('exited event', sent[1].event, 'exited')
eq('terminated event', sent[2].event, 'terminated')

-- gdb path resolution
eq('gdb default path', adapter:_gdb_path({}), 'arm-none-eabi-gdb')
eq('gdb toolchainPrefix', adapter:_gdb_path({ toolchainPrefix = 'arm-none-eabi' }), 'arm-none-eabi-gdb')
eq('gdb prefix custom', adapter:_gdb_path({ toolchainPrefix = 'riscv64-unknown-elf' }), 'riscv64-unknown-elf-gdb')
eq('gdb explicit path', adapter:_gdb_path({ gdbPath = '/opt/gcc/bin/arm-none-eabi-gdb' }), '/opt/gcc/bin/arm-none-eabi-gdb')
eq('gdb toolchainPath', adapter:_gdb_path({ toolchainPath = '/opt/gcc/bin' }), '/opt/gcc/bin/arm-none-eabi-gdb')

-- target spec
eq('target default', adapter:_target_spec({}), 'localhost:3333')
eq('target port', adapter:_target_spec({ gdbPort = 50000 }), 'localhost:50000')
eq('target host', adapter:_target_spec({ gdbTarget = '192.168.1.5' }), '192.168.1.5:3333')
eq('target host:port', adapter:_target_spec({ gdbTarget = '192.168.1.5:1234' }), '192.168.1.5:1234')

io.stdout:write(string.format('\n%d/%d checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
