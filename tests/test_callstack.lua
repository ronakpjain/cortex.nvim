local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local callstack = require('cortex.callstack')
local checks, failures = 0, 0
local function check(name, condition)
  checks = checks + 1
  if condition then io.write('ok   ' .. name .. '\n')
  else failures = failures + 1; io.write('not ok ' .. name .. '\n') end
end

local stopped = true
local frames = {
  { id = 11, name = 'main', line = 42, source = { path = '/tmp/main.c' }, instructionPointerReference = '0x1000' },
  { id = 12, name = 'worker', line = 7, source = { path = '/tmp/tasks.c' }, instructionPointerReference = '0x1100' },
}
local session = { initialized = true, stopped_thread_id = 3, current_frame = frames[1] }
function session:request(command, args, callback)
  check('stackTrace request', command == 'stackTrace' and args.threadId == 3)
  callback(nil, { stackFrames = frames, totalFrames = #frames })
end
function session:_frame_set(frame)
  self.current_frame = frame
end

local core = {
  config = { callstack = { auto_refresh_on_stop = false } },
  _is_stopped = function() return stopped end,
  _stopped_session = function() return stopped and session or nil end,
}
callstack.setup(core)
callstack.on_session_start({ callstack = { autoOpen = false } })

local refresh_error, refresh_data
callstack.refresh(function(err, data) refresh_error, refresh_data = err, data end)
check('refresh succeeds', refresh_error == nil and refresh_data ~= nil)
check('frames loaded', #callstack._state.frames == 2)
check('frame name retained', callstack._state.frames[2].name == 'worker')
check('stopped status shown', callstack._state.status == 'stopped / refreshed')

stopped = false
local running_error
callstack.refresh(function(err) running_error = err end)
check('running refresh rejected', running_error == 'target must be stopped')

-- Late stackTrace responses must not revive a resumed view.
stopped = true
local pending
local requests = 0
local delayed = { initialized = true, stopped_thread_id = 3, current_frame = frames[1] }
function delayed:request(_, _, callback)
  requests = requests + 1
  pending = callback
end
core._stopped_session = function() return stopped and delayed or nil end
callstack.on_session_start({ callstack = { enabled = true } })
local cancelled
callstack.refresh(function(err) cancelled = err end)
stopped = false
callstack.on_session_continued()
check('resume cancels stack request', cancelled == 'target resumed')
local before_late = requests
if pending then pending(nil, { stackFrames = frames }) end
check('late stack response ignored', requests == before_late)

io.write(string.format('%d/%d call-stack checks passed\n', checks - failures, checks))
if failures > 0 then os.exit(1) end
