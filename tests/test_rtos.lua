local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local rtos = require('cortex.rtos')

local checks, failures = 0, 0
local function check(name, condition)
  checks = checks + 1
  if condition then
    io.write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.write('not ok ' .. name .. '\n')
  end
end

local current = true
local values = {}
local function put(expression, value)
  values[expression] = value
end

put('sizeof(pxReadyTasksLists)/sizeof(pxReadyTasksLists[0])', '2')
put('pxCurrentTCB', '0x2000')
put('uxCurrentNumberOfTasks', '2')

put('pxReadyTasksLists[0].uxNumberOfItems', '1')
put('&pxReadyTasksLists[0].xListEnd', '0x1100')
put('pxReadyTasksLists[0].xListEnd.pxNext', '0x1200')
put('((ListItem_t*)0x1200)->pvOwner', '0x2000')
put('((ListItem_t*)0x1200)->pxNext', '0x1100')

put('pxReadyTasksLists[1].uxNumberOfItems', '0')
put('xDelayedTaskList1.uxNumberOfItems', '1')
put('&xDelayedTaskList1.xListEnd', '0x2100')
put('xDelayedTaskList1.xListEnd.pxNext', '0x2200')
put('((ListItem_t*)0x2200)->pvOwner', '0x3000')
put('((ListItem_t*)0x2200)->pxNext', '0x2100')

for _, expression in ipairs({
  'xDelayedTaskList2.uxNumberOfItems',
  'xPendingReadyList.uxNumberOfItems',
  'xSuspendedTaskList.uxNumberOfItems',
  'xTasksWaitingTermination.uxNumberOfItems',
}) do
  put(expression, '0')
end

local function task_fields(address, name, priority, runtime, top, stack, ending)
  put(string.format('((TCB_t*)%s)->pcTaskName', address), string.format('"%s"', name))
  put(string.format('((TCB_t*)%s)->uxPriority', address), tostring(priority))
  put(string.format('((TCB_t*)%s)->uxBasePriority', address), tostring(priority))
  put(string.format('((TCB_t*)%s)->ulRunTimeCounter', address), tostring(runtime))
  put(string.format('((TCB_t*)%s)->pxTopOfStack', address), string.format('0x%x', top))
  put(string.format('((TCB_t*)%s)->pxStack', address), string.format('0x%x', stack))
  put(string.format('((TCB_t*)%s)->pxEndOfStack', address), string.format('0x%x', ending))
end

task_fields('0x2000', 'worker', 4, 100, 0x8f00, 0x8000, 0x9000)
task_fields('0x3000', 'blocked', 2, 20, 0x9f00, 0x9000, 0xa000)

local session = { initialized = true, stopped_thread_id = 1, current_frame = { id = 7 } }
function session:evaluate(request, callback)
  local value = values[request.expression]
  if value == nil then
    callback({ message = 'unknown expression: ' .. request.expression }, nil)
  else
    callback(nil, { result = value })
  end
end

local core = {
  config = {
    rtos = {
      enabled = true,
      max_priorities = 2,
      auto_refresh_on_stop = false,
    },
  },
  _is_stopped = function() return current end,
  _stopped_session = function() return current and session or nil end,
}
rtos.setup(core)
rtos.on_session_start({ rtos = { enabled = true } })

local result, result_data
rtos.refresh(function(err, data)
  result, result_data = err, data
end)
check('refresh succeeds', result == nil and result_data ~= nil)
check('task count is reported', result_data and result_data.task_count == 2)
check('two tasks found', result_data and #result_data.tasks == 2)
local by_name = {}
for _, task in ipairs(result_data and result_data.tasks or {}) do by_name[task.name] = task end
check('running task found', by_name.worker and by_name.worker.state == 'Running' and by_name.worker.running)
check('blocked task found', by_name.blocked and by_name.blocked.state == 'Blocked')
check('priority decoded', by_name.worker and by_name.worker.priority == 4)
check('runtime decoded', by_name.worker and by_name.worker.runtime == '100')
check('stack decoded', by_name.worker and by_name.worker.stack == '64/1024 words')
check('handle decoded', by_name.worker and by_name.worker.address == '0x2000')
check('exact task budget is not truncated', rtos._state.truncated == false)
check('GDB octal string cleanup', rtos._parse_name('"worker\\000\\000"') == 'worker')

current = false
local running_error
rtos.refresh(function(err) running_error = err end)
check('running refresh rejected', running_error == 'target must be stopped')
check('running status shown', rtos._state.status == 'target running (refresh skipped)')

-- A delayed DAP response must not restart the walk after resume.
current = true
local async_session = { initialized = true, stopped_thread_id = 1, current_frame = { id = 8 } }
local pending_callback
local evaluate_calls = 0
function async_session:evaluate(_, callback)
  evaluate_calls = evaluate_calls + 1
  pending_callback = callback
end
core._stopped_session = function() return current and async_session or nil end
rtos.on_session_start({ rtos = { enabled = true, maxPriorities = 2 } })
local cancelled_error
rtos.refresh(function(err) cancelled_error = err end)
current = false
rtos.on_session_continued()
check('resume cancels delayed refresh', cancelled_error == 'target resumed')
local calls_before_late_response = evaluate_calls
if pending_callback then pending_callback(nil, { result = '2' }) end
check('late response sends no follow-up evaluation', evaluate_calls == calls_before_late_response)

io.write(string.format('%d/%d RTOS checks passed\n', checks - failures, checks))
if failures > 0 then os.exit(1) end
