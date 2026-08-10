-- Native live-watch hydration and running-state polling test.
-- This uses a small fake DAP session and telnet endpoint to verify that
-- metadata is resolved once while stopped and memory is sampled over telnet
-- after resume, including nested struct/array children.

vim.opt.rtp:prepend(vim.fn.getcwd())

local calls = 0
local sent = {}
local stopped = true

local responses = {
  root = { result = '{...}', type = 'struct Root', variablesReference = 1 },
  ['&(root)'] = { result = '0x20000000' },
  ['sizeof(root)'] = { result = '20' },
  ['root.first'] = { result = '42', type = 'uint32_t', variablesReference = 0 },
  ['&(root.first)'] = { result = '0x20000000' },
  ['sizeof(root.first)'] = { result = '4' },
  ['root.nested'] = { result = '{...}', type = 'struct Nested', variablesReference = 2 },
  ['&(root.nested)'] = { result = '0x20000004' },
  ['sizeof(root.nested)'] = { result = '4' },
  ['root.nested.value'] = { result = '-1', type = 'int32_t', variablesReference = 0 },
  ['&(root.nested.value)'] = { result = '0x20000004' },
  ['sizeof(root.nested.value)'] = { result = '4' },
  ['root.values'] = { result = '{...}', type = 'uint16_t [2]', variablesReference = 3 },
  ['&(root.values)'] = { result = '0x20000008' },
  ['sizeof(root.values)'] = { result = '4' },
  ['root.values[0]'] = { result = '0x1234', type = 'uint16_t', variablesReference = 0 },
  ['&(root.values[0])'] = { result = '0x20000008' },
  ['sizeof(root.values[0])'] = { result = '2' },
  ['root.values[1]'] = { result = '0x5678', type = 'uint16_t', variablesReference = 0 },
  ['&(root.values[1])'] = { result = '0x2000000a' },
  ['sizeof(root.values[1])'] = { result = '2' },
  ['root.ptr'] = { result = '0x20000004', type = 'struct Nested *', variablesReference = 4 },
  ['&(root.ptr)'] = { result = '0x2000000c' },
  ['sizeof(root.ptr)'] = { result = '4' },
  ['*root.ptr'] = { result = '{...}', type = 'struct Nested', variablesReference = 5 },
  ['&(*root.ptr)'] = { result = '0x20000004' },
  ['sizeof(*root.ptr)'] = { result = '4' },
  ['(*root.ptr).value'] = { result = '-1', type = 'int32_t', variablesReference = 0 },
  ['&((*root.ptr).value)'] = { result = '0x20000004' },
  ['sizeof((*root.ptr).value)'] = { result = '4' },
}

local children = {
  [1] = {
    { name = 'first', evaluateName = 'root.first', type = 'uint32_t', variablesReference = 0 },
    { name = 'nested', evaluateName = 'root.nested', type = 'struct Nested', variablesReference = 2 },
    { name = 'values', evaluateName = 'root.values', type = 'uint16_t [2]', variablesReference = 3 },
    { name = 'ptr', evaluateName = 'root.ptr', type = 'struct Nested *', variablesReference = 4 },
  },
  [2] = {
    { name = 'value', evaluateName = 'root.nested.value', type = 'int32_t', variablesReference = 0 },
  },
  [3] = {
    -- Exercise normalization of the old `array.[0]` spelling too.
    { name = '[0]', evaluateName = 'root.values.[0]', type = 'uint16_t', variablesReference = 0 },
    { name = '[1]', evaluateName = 'root.values[1]', type = 'uint16_t', variablesReference = 0 },
  },
  [4] = {
    { name = '*root.ptr', evaluateName = '*root.ptr', type = 'struct Nested', variablesReference = 5 },
  },
  [5] = {
    { name = 'value', evaluateName = '(*root.ptr).value', type = 'int32_t', variablesReference = 0 },
  },
}

local session = {
  initialized = true,
  stopped_thread_id = 1,
  current_frame = { id = 1 },
}
function session:evaluate(args, cb)
  calls = calls + 1
  if not stopped then
    error('DAP evaluate called while running')
  end
  cb(nil, responses[args.expression])
end
function session:request(command, args, cb)
  calls = calls + 1
  if not stopped then
    error('DAP ' .. command .. ' called while running')
  end
  assert(command == 'variables')
  cb(nil, { variables = children[args.variablesReference] or {} })
end

local dap = {
  listeners = {
    after = {
      event_initialized = {},
      event_continued = {},
      event_stopped = {},
      event_terminated = {},
      event_exited = {},
      disconnect = {},
    },
    before = {},
  },
  session = function()
    return session
  end,
}
package.preload.dap = function()
  return dap
end

local telnet = {
  connected = true,
  queue = 0,
}
function telnet:is_connected()
  return self.connected
end
function telnet:queue_size()
  return self.queue
end
function telnet:send(command, cb)
  sent[#sent + 1] = command
  local values = {
    -- OpenOCD prints mdw/mdh values in target numeric order; the target's
    -- little-endian byte layout is already accounted for by OpenOCD.
    ['mdw 0x20000000 1'] = '0x20000000: 12345678',
    ['mdw 0x20000004 1'] = '0x20000004: ffffffff',
    ['mdh 0x20000008 1'] = '0x20000008: 1234',
    ['mdh 0x2000000a 1'] = '0x2000000a: 5678',
    ['mdw 0x2000000c 1'] = '0x2000000c: 20000004',
  }
  cb(nil, values[command] or '')
end
function telnet:close()
  self.connected = false
end

local cortex = require('cortex')
local live_watch = require('cortex.live_watch')
local watch = cortex._watch
assert(live_watch.state == watch, 'cortex._watch does not expose live-watch state')
for _, method in ipairs({
  'setup',
  'configure',
  'on_session_start',
  'on_session_continued',
  'on_session_stopped',
  'on_session_end',
  'on_window_closed',
  'shutdown',
  'start',
  'stop',
  'open',
  'close',
  'toggle',
  'add',
  'clear',
  'refresh',
  'telnet',
  'status',
}) do
  assert(type(live_watch[method]) == 'function', 'missing live-watch method: ' .. method)
end
local original_status = live_watch.status
local delegated = {}
live_watch.status = function(...)
  delegated = { ... }
  return 'delegated'
end
assert(cortex.status('status-argument') == 'delegated', 'public status did not delegate')
assert(delegated[1] == 'status-argument', 'delegation dropped arguments')
live_watch.status = original_status

watch.active = true
watch.telnet = telnet
watch.session_config = { liveWatch = { maxDepth = 6, maxChildren = 16 } }
cortex.config.window.position = 'float'

cortex.add('root')
vim.wait(30)

local entry = assert(watch.entries[1], 'root entry missing')
assert(entry.root, 'root metadata was not hydrated')
assert(#entry.root.children == 4, 'struct children were not hydrated')
assert(entry.root.children[1].expression == 'root.first')
assert(entry.root.children[2].children[1].expression == 'root.nested.value')
assert(entry.root.children[3].children[1].expression == 'root.values[0]')
assert(entry.root.children[3].children[2].expression == 'root.values[1]')
assert(entry.root.children[4].children[1].expression == '*root.ptr')
assert(entry.root.children[4].children[1].children[1].expression == '(*root.ptr).value')
assert(#sent == 0, 'hydration should not poll before refresh')

local calls_at_stop = calls
cortex.refresh()
assert(calls > calls_at_stop, 'stopped refresh did not rehydrate metadata')
-- The stopped refresh above is allowed to use DAP; the important running-state
-- guarantee is checked below.
stopped = false
session.stopped_thread_id = nil
session.current_frame = nil
local calls_at_run = calls
local sent_at_run = #sent
cortex.refresh()
assert(calls == calls_at_run, 'running refresh issued a DAP request')
assert(#sent > sent_at_run, 'running refresh did not poll telnet memory')
assert(entry.root.children[1].value:find('0x12345678', 1, true), 'uint32 decode failed')
assert(entry.root.children[2].children[1].value:find('-1', 1, true), 'signed decode failed')
assert(entry.root.children[3].children[1].value:find('0x1234', 1, true), 'array decode failed')
assert(entry.root.children[4].value:find('0x20000004', 1, true), 'pointer decode failed')
assert(entry.root.children[4].children[1].children[1].value:find('-1', 1, true), 'pointee decode failed')

-- A pause must leave the watch buffer intact without racing a running-state
-- Telnet sample against the stopped-state DAP hydration pass.
dap.adapters = {}
cortex.setup({ live_watch = { auto_open = false } })
local on_stopped = assert(dap.listeners.after.event_stopped['cortex.nvim'])
local on_continued = assert(dap.listeners.after.event_continued['cortex.nvim'])
stopped = true
session.stopped_thread_id = 1
session.current_frame = { id = 1 }
local sent_at_pause = #sent
watch.target_state = 'stopped'
cortex.refresh()
assert(#sent == sent_at_pause, 'paused watch sampled Telnet')
on_stopped()
assert(watch.target_state == 'stopped', 'pause did not mark watch stopped')
stopped = false
session.stopped_thread_id = nil
session.current_frame = nil
on_continued()
assert(watch.target_state == 'running', 'resume did not mark watch running')
cortex.refresh()
assert(#sent > sent_at_pause, 'watch did not resume Telnet sampling')

-- The DAP listeners stay in init, but each watch transition is delegated to
-- the focused module.
local lifecycle_calls = {}
local lifecycle_methods = {
  'on_session_start',
  'on_session_continued',
  'on_session_stopped',
  'on_session_end',
}
local lifecycle_originals = {}
for _, method in ipairs(lifecycle_methods) do
  lifecycle_originals[method] = live_watch[method]
  live_watch[method] = function(config)
    lifecycle_calls[#lifecycle_calls + 1] = { method, config }
  end
end
local listener_config = { liveWatch = { enabled = false } }
dap.listeners.after.event_initialized['cortex.nvim']({ config = listener_config })
dap.listeners.after.event_continued['cortex.nvim']()
dap.listeners.after.event_stopped['cortex.nvim']()
dap.listeners.after.event_terminated['cortex.nvim']()
for index, method in ipairs(lifecycle_methods) do
  assert(lifecycle_calls[index] and lifecycle_calls[index][1] == method, 'listener did not delegate ' .. method)
end
assert(lifecycle_calls[1][2] == listener_config, 'session config was not delegated')
for _, method in ipairs(lifecycle_methods) do
  live_watch[method] = lifecycle_originals[method]
end

live_watch.configure({ telnetHost = 'debug-host', telnetPort = 5555, liveWatch = { samplesPerSecond = 8 } })
assert(
  watch.host == 'debug-host' and watch.port == 5555 and watch.rate == 8,
  'configure did not hydrate endpoint state'
)
watch.active = false
live_watch.on_session_start(listener_config)
assert(watch.target_state == 'running' and watch.session_config == listener_config, 'session start lifecycle failed')
live_watch.on_session_continued()
assert(watch.target_state == 'running', 'continued lifecycle failed')
stopped = true
session.stopped_thread_id = 1
session.current_frame = { id = 1 }
live_watch.on_session_stopped()
assert(watch.target_state == 'stopped', 'stopped lifecycle failed')
live_watch.on_session_end()
assert(watch.target_state == nil and watch.session_config == nil, 'session end lifecycle failed')

watch.winid = 999999
watch.active = true
assert(live_watch.on_window_closed('999999') == true, 'window close lifecycle ignored watch window')
assert(watch.winid == nil and not watch.active, 'window close lifecycle did not stop watch')
watch.telnet = telnet
watch.active = true
live_watch.shutdown()
assert(not watch.active and watch.target_state == nil and watch.telnet == nil, 'shutdown lifecycle failed')

print('live watch module/delegation/hydration/lifecycle: ok')
vim.cmd('qa!')
