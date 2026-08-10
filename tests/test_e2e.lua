-- End-to-end smoke test: drives the real adapter process over DAP stdio using
-- a fake gdb (MI) and a fake OpenOCD.
--
--   nvim --headless --clean -u NONE -l tests/test_e2e.lua

local uv = vim.uv or vim.loop

local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
if root:sub(1, 1) ~= '/' then
  root = uv.cwd() .. '/' .. root
end
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

local nvim = vim.v.progpath
local tmp = uv.fs_mkdtemp('/tmp/cortex-e2e-XXXXXX')

local function wrapper(name, script)
  local path = tmp .. '/' .. name
  local fh = assert(io.open(path, 'w'))
  fh:write(string.format('#!/bin/sh\nexec %q --headless --clean -u NONE -l %q "$@"\n', nvim, script))
  fh:close()
  uv.fs_chmod(path, 493) -- 0755
  return path
end

local fake_gdb = wrapper('fake-gdb', root .. '/tests/fake_gdb.lua')
local fake_openocd = wrapper('fake-openocd', root .. '/tests/fake_openocd.lua')

-- pick a free-ish gdb port
math.randomseed(os.time())
local gdb_port = 40000 + math.random(0, 9000)

--------------------------------------------------------------- adapter proc

local stdin_pipe = uv.new_pipe(false)
local stdout_pipe = uv.new_pipe(false)
local stderr_pipe = uv.new_pipe(false)

local exited = false
local handle = uv.spawn(nvim, {
  args = { '--headless', '--clean', '-u', 'NONE', '-l', root .. '/lua/cortex/adapter_main.lua' },
  cwd = tmp,
  stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
}, function()
  exited = true
end)
check('adapter process spawned', handle ~= nil)
if not handle then
  os.exit(1)
end

local reader = A.Reader.new()
local events, responses = {}, {}
local stderr_text = {}

stdout_pipe:read_start(function(err, chunk)
  if err or not chunk then
    return
  end
  local msgs = reader:feed(chunk)
  for _, m in ipairs(msgs) do
    if m.type == 'event' then
      events[#events + 1] = m
    elseif m.type == 'response' then
      responses[#responses + 1] = m
    end
  end
end)
stderr_pipe:read_start(function(err, chunk)
  if not err and chunk then
    stderr_text[#stderr_text + 1] = chunk
  end
end)

local seq = 0
local function request(command, arguments)
  seq = seq + 1
  local msg = { seq = seq, type = 'request', command = command }
  if arguments then
    msg.arguments = arguments
  end
  stdin_pipe:write(A.encode_message(msg))
  return seq
end

local function wait_response(request_seq, timeout)
  local found
  vim.wait(timeout or 15000, function()
    for _, r in ipairs(responses) do
      if r.request_seq == request_seq then
        found = r
        return true
      end
    end
    return false
  end, 20)
  return found
end

local function wait_event(name, timeout, from)
  from = from or 1
  local found
  vim.wait(timeout or 15000, function()
    for i = from, #events do
      if events[i].event == name then
        found = events[i]
        return true
      end
    end
    return false
  end, 20)
  return found
end

------------------------------------------------------------------- sequence

local r = wait_response(request('initialize', { adapterID = 'cortex-debug', clientID = 'test' }))
check('initialize responded', r ~= nil and r.success == true, r and vim.inspect(r))
check('capabilities: configurationDone', r and r.body and r.body.supportsConfigurationDoneRequest == true)
check('capabilities: terminate', r and r.body and r.body.supportsTerminateRequest == true)
check('capabilities: setVariable', r and r.body and r.body.supportsSetVariable == true)

local launch_seq = request('launch', {
  type = 'cortex-debug',
  request = 'launch',
  servertype = 'openocd',
  cwd = tmp,
  executable = tmp .. '/app.elf',
  gdbPath = fake_gdb,
  serverpath = fake_openocd,
  configFiles = { 'interface/stlink.cfg', 'target/stm32f4x.cfg' },
  gdbPort = gdb_port,
  telnetPort = gdb_port + 1,
  runToEntryPoint = 'main',
  loadFiles = false,
})

local initialized = wait_event('initialized', 20000)
check('initialized event emitted', initialized ~= nil, table.concat(stderr_text))

r = wait_response(launch_seq, 20000)
check('launch responded', r ~= nil and r.success == true, r and vim.inspect(r))

r = wait_response(request('setBreakpoints', {
  source = { path = tmp .. '/main.c', name = 'main.c' },
  breakpoints = { { line = 12 }, { line = 20 } },
}))
check('setBreakpoints responded', r ~= nil and r.success == true, r and vim.inspect(r))
check('two breakpoints returned', r and r.body and #r.body.breakpoints == 2)
check('breakpoint verified', r and r.body and r.body.breakpoints[1].verified == true)
check('breakpoint line', r and r.body and r.body.breakpoints[1].line == 12, r and vim.inspect(r.body))

local events_before = #events + 1
r = wait_response(request('configurationDone'))
check('configurationDone responded', r ~= nil and r.success == true)

local stopped = wait_event('stopped', 10000, events_before)
check('stopped event after configurationDone', stopped ~= nil, vim.inspect(events))
check(
  'stopped body has threadId + allThreadsStopped',
  stopped and stopped.body and stopped.body.threadId == 1 and stopped.body.allThreadsStopped == true,
  stopped and vim.inspect(stopped.body)
)
check(
  'runToEntryPoint stop reported as `entry`',
  stopped and stopped.body and stopped.body.reason == 'entry',
  stopped and vim.inspect(stopped.body)
)

r = wait_response(request('threads'))
check('threads responded', r ~= nil and r.success == true)
check('one thread', r and r.body and #r.body.threads == 1, r and vim.inspect(r.body))
check('thread name', r and r.body and r.body.threads[1].name == 'cortex-m4')

r = wait_response(request('stackTrace', { threadId = 1 }))
check('stackTrace responded', r ~= nil and r.success == true)
check('two frames', r and r.body and #r.body.stackFrames == 2, r and vim.inspect(r.body))
check('frame name', r and r.body and r.body.stackFrames[1].name == 'main')
check('frame source path', r and r.body and r.body.stackFrames[1].source.path == '/tmp/main.c')
local frame_id = r and r.body and r.body.stackFrames[1].id

r = wait_response(request('scopes', { frameId = frame_id }))
check('scopes responded', r ~= nil and r.success == true)
check('two scopes', r and r.body and #r.body.scopes == 2, r and vim.inspect(r.body))
check('scope Locals', r and r.body and r.body.scopes[1].name == 'Locals')
check('scope Registers', r and r.body and r.body.scopes[2].name == 'Registers')
local locals_ref = r and r.body and r.body.scopes[1].variablesReference
local regs_ref = r and r.body and r.body.scopes[2].variablesReference

r = wait_response(request('variables', { variablesReference = locals_ref }))
check('locals responded', r ~= nil and r.success == true)
check('locals count', r and r.body and #r.body.variables == 2, r and vim.inspect(r.body))
check('local counter', r and r.body and r.body.variables[1].name == 'counter')
check('local value', r and r.body and r.body.variables[1].value == '7')

r = wait_response(request('variables', { variablesReference = regs_ref }))
check('registers responded', r ~= nil and r.success == true)
check('register count', r and r.body and #r.body.variables == 4, r and vim.inspect(r.body))
check('register pc', r and r.body and r.body.variables[4].name == 'pc')

r = wait_response(request('evaluate', { expression = 'counter', context = 'watch', frameId = frame_id }))
check('evaluate watch responded', r ~= nil and r.success == true)
check('evaluate watch value', r and r.body and r.body.result == '7', r and vim.inspect(r.body))

r = wait_response(request('evaluate', { expression = '&counter', context = 'repl', frameId = frame_id }))
check('evaluate repl responded', r ~= nil and r.success == true)
check('evaluate memoryReference', r and r.body and r.body.memoryReference == '0x20000100', r and vim.inspect(r.body))

events_before = #events + 1
r = wait_response(request('next', { threadId = 1 }))
check('next responded', r ~= nil and r.success == true)
stopped = wait_event('stopped', 8000, events_before)
check('stopped after next', stopped ~= nil and stopped.body.reason == 'step', stopped and vim.inspect(stopped.body))

events_before = #events + 1
r = wait_response(request('continue', { threadId = 1 }))
check('continue responded', r ~= nil and r.success == true)
check('continue allThreadsContinued', r and r.body and r.body.allThreadsContinued == true)
local continued = wait_event('continued', 5000, events_before)
check('continued event', continued ~= nil)

events_before = #events + 1
r = wait_response(request('pause', { threadId = 1 }))
check('pause responded', r ~= nil and r.success == true)
stopped = wait_event('stopped', 8000, events_before)
check('stopped after pause', stopped ~= nil and stopped.body.reason == 'pause', stopped and vim.inspect(stopped.body))

events_before = #events + 1
r = wait_response(request('terminate'), 10000)
check('terminate responded', r ~= nil and r.success == true)
check('terminated event', wait_event('terminated', 5000, events_before) ~= nil)

r = wait_response(request('disconnect', { terminateDebuggee = true }), 10000)
check('disconnect after terminate responded', r ~= nil and r.success == true)

vim.wait(8000, function()
  return exited
end, 50)
check('adapter process exited cleanly', exited == true)

-- The fake OpenOCD must be gone too (port released).
local released = false
vim.wait(5000, function()
  local probe = uv.new_tcp()
  local settled, connected = false, false
  probe:connect('127.0.0.1', gdb_port, function(err)
    settled = true
    connected = err == nil
    pcall(function()
      probe:close()
    end)
  end)
  vim.wait(500, function()
    return settled
  end, 20)
  if not settled then
    pcall(function()
      probe:close()
    end)
  end
  released = not connected
  return released
end, 200)
check('gdb server port released (openocd killed)', released == true)

os.execute('rm -rf ' .. vim.fn.shellescape(tmp))

local err_text = table.concat(stderr_text)
if failures > 0 and err_text ~= '' then
  io.stdout:write('\n--- adapter stderr ---\n' .. err_text .. '\n')
end
io.stdout:write(string.format('\n%d/%d checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
