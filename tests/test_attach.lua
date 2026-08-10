-- End-to-end smoke test for `request = "attach"` with `servertype = "external"`
-- (no OpenOCD spawned) and for `disconnect` without terminating the debuggee.
--
--   nvim --headless --clean -u NONE -l tests/test_attach.lua

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
local tmp = uv.fs_mkdtemp('/tmp/cortex-attach-XXXXXX')

local fake_gdb = tmp .. '/fake-gdb'
local fh = assert(io.open(fake_gdb, 'w'))
fh:write(
  string.format('#!/bin/sh\nexec %q --headless --clean -u NONE -l %q "$@"\n', nvim, root .. '/tests/fake_gdb.lua')
)
fh:close()
uv.fs_chmod(fake_gdb, 493)

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
check('adapter spawned', handle ~= nil)
if not handle then
  os.exit(1)
end

local reader = A.Reader.new()
local events, responses, stderr_text = {}, {}, {}
stdout_pipe:read_start(function(err, chunk)
  if err or not chunk then
    return
  end
  for _, m in ipairs(reader:feed(chunk)) do
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
  stdin_pipe:write(A.encode_message({ seq = seq, type = 'request', command = command, arguments = arguments }))
  return seq
end
local function wait_response(rs, timeout)
  local found
  vim.wait(timeout or 15000, function()
    for _, r in ipairs(responses) do
      if r.request_seq == rs then
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

local r = wait_response(request('initialize', { adapterID = 'cortex-debug' }))
check('initialize responded', r ~= nil and r.success == true)

-- `external` server type: nothing is spawned, and no port is probed, so this
-- must succeed even though no OpenOCD exists.
local attach_seq = request('attach', {
  type = 'cortex-debug',
  request = 'attach',
  servertype = 'external',
  cwd = tmp,
  gdbPath = fake_gdb,
  gdbTarget = 'localhost:3333',
  postAttachCommands = { 'monitor halt' },
})
check('initialized event', wait_event('initialized', 15000) ~= nil, table.concat(stderr_text))
r = wait_response(attach_seq, 15000)
check('attach responded', r ~= nil and r.success == true, r and vim.inspect(r))

-- No runToEntryPoint on attach => stopAtEntry default emits a synthetic stop.
local before = #events + 1
r = wait_response(request('configurationDone'))
check('configurationDone responded', r ~= nil and r.success == true)
local stopped = wait_event('stopped', 8000, before)
check(
  'synthetic entry stop on attach',
  stopped ~= nil and stopped.body.reason == 'entry',
  stopped and vim.inspect(stopped)
)

r = wait_response(request('threads'))
check('threads responded on attach', r ~= nil and r.success == true)

-- disconnect without terminateDebuggee => detach, keep target running.
r = wait_response(request('disconnect', { terminateDebuggee = false }), 10000)
check('disconnect (detach) responded', r ~= nil and r.success == true)

vim.wait(8000, function()
  return exited
end, 50)
check('adapter exited', exited == true)

os.execute('rm -rf ' .. vim.fn.shellescape(tmp))
if failures > 0 then
  io.stdout:write('\n--- stderr ---\n' .. table.concat(stderr_text) .. '\n')
end
io.stdout:write(string.format('\n%d/%d checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
