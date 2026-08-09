-- Stopped-only FreeRTOS task browser.
--
-- This module deliberately uses the active DAP/GDB session rather than the
-- OpenOCD live-watch socket.  It walks the kernel's task lists only while
-- the target is halted, and cancels every in-flight request on resume.
local api = vim.api
local ui = require('cortex.ui')

local P = {}
local core
local state = {
  session_config = nil,
  tasks = {},
  error = nil,
  truncated = false,
  priority_incomplete = false,
  status = 'not loaded',
  generation = 0,
  refreshing = false,
  cancel_refresh = nil,
  bufnr = nil,
  winid = nil,
}
P._state = state

local DEFAULTS = {
  enabled = false,
  auto_open = false,
  auto_refresh_on_stop = false,
  max_tasks = 128,
  max_priorities = nil, -- otherwise probe sizeof(ready-lists), then use 32
  tcb_type = 'TCB_t',
  list_item_type = 'ListItem_t',
  stack_growth = -1,
  stack_word_bytes = 4,
  symbols = {
    current_tcb = 'pxCurrentTCB',
    task_count = 'uxCurrentNumberOfTasks',
    ready_lists = 'pxReadyTasksLists',
    delayed_list1 = 'xDelayedTaskList1',
    delayed_list2 = 'xDelayedTaskList2',
    pending_ready_list = 'xPendingReadyList',
    suspended_list = 'xSuspendedTaskList',
    waiting_termination_list = 'xTasksWaitingTermination',
    total_runtime = 'ulTotalRunTime',
  },
  fields = {
    name = 'pcTaskName',
    priority = 'uxPriority',
    base_priority = 'uxBasePriority',
    runtime = 'ulRunTimeCounter',
    top_of_stack = 'pxTopOfStack',
    stack = 'pxStack',
    end_of_stack = 'pxEndOfStack',
  },
}

local function get(tbl, key)
  return type(tbl) == 'table' and tbl[key] or nil
end

local function config()
  local base = (core and core.config and core.config.rtos) or {}
  local session = get(state.session_config, 'rtos') or {}
  local result = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), base, session)
  -- Launch JSON normally uses camelCase while setup() uses Lua-style
  -- snake_case. Accept both without changing the adapter's pass-through data.
  local aliases = {
    auto_open = 'autoOpen',
    auto_refresh_on_stop = 'autoRefreshOnStop',
    max_tasks = 'maxTasks',
    max_priorities = 'maxPriorities',
    tcb_type = 'tcbType',
    list_item_type = 'listItemType',
    stack_growth = 'stackGrowth',
    stack_word_bytes = 'stackWordBytes',
  }
  for snake, camel in pairs(aliases) do
    if session[snake] == nil and session[camel] ~= nil then result[snake] = session[camel] end
  end
  return result
end

local function symbols()
  return config().symbols or {}
end

local function fields()
  return config().fields or {}
end

local function trim(value)
  return vim.trim(tostring(value or ''))
end

local function parse_number(value)
  local text = trim(value)
  local hex = text:match('0[xX]([%da-fA-F]+)')
  if hex then return tonumber(hex, 16) end
  local dec = text:match('^%-?%d+')
  return dec and tonumber(dec, 10) or nil
end

local function pointer(value)
  local number = parse_number(value)
  if not number or number == 0 then return nil end
  return string.format('0x%x', number), number
end

local function unescape_c_string(value)
  return (value:gsub('\\(%d%d%d)', function(octal)
    return string.char(tonumber(octal, 8))
  end):gsub('\\([\\"nrt])', function(code)
    return ({ ['\\'] = '\\', ['"'] = '"', n = '\n', r = '\r', t = '\t' })[code] or code
  end):gsub('\\x(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_name(value)
  local text = trim(value)
  local quoted = text:match('"(.*)"')
  if quoted then
    return unescape_c_string(quoted):match('^[^%z]*') or ''
  end
  return text:gsub('%s*<.*$', ''):gsub('%z.*$', '')
end

P._parse_number = parse_number
P._parse_pointer = pointer
P._parse_name = parse_name

local function active_session()
  if core and core._stopped_session then
    return core._stopped_session()
  end
  if core and core._is_stopped and not core._is_stopped() then
    return nil
  end
  local ok, dap = pcall(require, 'dap')
  if not ok or not dap then return nil end
  local session = dap.session()
  if not session or not session.initialized then return nil end
  if not session.stopped_thread_id or not session.current_frame then return nil end
  return session
end

local function stopped()
  if core and core._is_stopped then return core._is_stopped() end
  return active_session() ~= nil
end

local function valid(generation, session)
  return state.generation == generation and stopped() and active_session() == session
end

local function session_frame(session)
  return session.current_frame and session.current_frame.id or nil
end

--- Evaluate a raw GDB expression through the active stopped DAP session.
---@param session table
---@param expression string
---@param callback fun(err: string|nil, value: string|nil)
---@param guard fun(): boolean|nil
local function evaluate(session, expression, callback, guard)
  if guard and not guard() then
    callback('target resumed', nil)
    return
  end
  local finished = false
  local function finish(err, value)
    if finished then return end
    finished = true
    if guard and not guard() then
      callback('target resumed', nil)
      return
    end
    callback(err and tostring(err) or nil, value == nil and nil or tostring(value))
  end
  if core and core._rtos_evaluate then
    core._rtos_evaluate(expression, finish)
    return
  end
  session:evaluate({
    expression = expression,
    context = 'repl',
    frameId = session_frame(session),
  }, function(err, response)
    if err then
      finish(err.message or tostring(err), nil)
      return
    end
    if not response then
      finish('empty GDB response', nil)
      return
    end
    finish(nil, response.result or response.value or '')
  end)
end

local function type_candidates(setting, fallback)
  local value = setting
  if type(value) == 'string' and value ~= '' then return { value, fallback } end
  if type(value) == 'table' and #value > 0 then return vim.deepcopy(value) end
  return { fallback }
end

local function expression_for_tcb(type_name, handle, field)
  return string.format('((%s*)%s)->%s', type_name, handle, field)
end

local function expression_for_item(type_name, item, field)
  return string.format('((%s*)%s)->%s', type_name, item, field)
end

local function sequence(items, each, done)
  local index = 0
  local function next_item(err)
    if err then done(err); return end
    index = index + 1
    if index > #items then done(nil); return end
    each(items[index], next_item)
  end
  next_item(nil)
end

local function format_error(err)
  return tostring(err or 'GDB expression failed')
end

local function resolve_tcb_type(session, handle, field, callback, guard)
  local cfg = config()
  local candidates = state.tcb_type and { state.tcb_type } or type_candidates(cfg.tcb_type, 'tskTCB')
  local index = 0
  local function try_next(last_err)
    if guard and not guard() then callback('target resumed', nil); return end
    index = index + 1
    local candidate = candidates[index]
    if not candidate then callback(last_err or 'cannot resolve TCB_t', nil); return end
    evaluate(session, expression_for_tcb(candidate, handle, field), function(err, value)
      if not err then
        if not guard or guard() then state.tcb_type = candidate end
        callback(nil, value)
      elseif err == 'target resumed' or (guard and not guard()) then
        callback('target resumed', nil)
      else
        try_next(err)
      end
    end, guard)
  end
  try_next(nil)
end

local function resolve_item_field(session, item, field, callback, guard)
  local cfg = config()
  local selected = state.list_item_type
  local candidates = selected and { selected } or type_candidates(cfg.list_item_type, 'xLIST_ITEM')
  local index = 0
  local function try_next(last_err)
    if guard and not guard() then callback('target resumed', nil); return end
    index = index + 1
    local candidate = candidates[index]
    if not candidate then callback(last_err or 'cannot resolve ListItem_t', nil); return end
    evaluate(session, expression_for_item(candidate, item, field), function(err, value)
      if not err then
        if not guard or guard() then state.list_item_type = candidate end
        callback(nil, value)
      elseif err == 'target resumed' or (guard and not guard()) then
        callback('target resumed', nil)
      else
        try_next(err)
      end
    end, guard)
  end
  try_next(nil)
end

local function list_specs(priority_count)
  local sym = symbols()
  local result = {}
  for priority = 0, priority_count - 1 do
    result[#result + 1] = {
      symbol = string.format('%s[%d]', sym.ready_lists or 'pxReadyTasksLists', priority),
      state = 'Ready',
      priority = priority,
      optional = false,
    }
  end
  local extras = {
    { 'delayed_list1', 'Blocked' },
    { 'delayed_list2', 'Blocked' },
    { 'pending_ready_list', 'Pending' },
    { 'suspended_list', 'Suspended' },
    { 'waiting_termination_list', 'Terminated' },
  }
  for _, item in ipairs(extras) do
    local name = sym[item[1]]
    if name and name ~= '' then
      result[#result + 1] = { symbol = name, state = item[2], optional = true }
    end
  end
  return result
end

local function read_list(session, generation, spec, budget, callback)
  local guard = function() return valid(generation, session) end
  local function fail(err)
    callback(err or ('cannot read ' .. spec.symbol), nil, spec.optional)
  end
  if not guard() then callback('target resumed', nil, false); return end
  evaluate(session, spec.symbol .. '.uxNumberOfItems', function(err, value)
    if err then fail(err); return end
    local count = parse_number(value)
    if count == nil then fail('invalid task-list count for ' .. spec.symbol); return end
    if count <= 0 then callback(nil, {}, spec.optional); return end
    if budget.remaining <= 0 then
      budget.truncated = true
      callback(nil, {}, spec.optional)
      return
    end
    local limit = math.min(count, budget.remaining)
    if count > limit then budget.truncated = true end
    evaluate(session, '&' .. spec.symbol .. '.xListEnd', function(sentinel_err, sentinel_value)
      if sentinel_err then fail(sentinel_err); return end
      local sentinel = pointer(sentinel_value)
      evaluate(session, spec.symbol .. '.xListEnd.pxNext', function(head_err, head_value)
        if head_err then fail(head_err); return end
        local item = pointer(head_value)
        local entries = {}
        local index = 0
        local function next_item(err2)
          if err2 then fail(err2); return end
          if not guard() then
            callback('target resumed', nil, false)
            return
          end
          index = index + 1
          if index > limit or not item or (sentinel and item == sentinel) then
            callback(nil, entries, spec.optional)
            return
          end
          local item_pointer = item
          budget.remaining = budget.remaining - 1
          resolve_item_field(session, item_pointer, 'pvOwner', function(owner_err, owner_value)
            if owner_err then fail(owner_err); return end
            local owner = pointer(owner_value)
            resolve_item_field(session, item_pointer, 'pxNext', function(next_err, next_value)
              if next_err then fail(next_err); return end
              if owner then
                entries[#entries + 1] = {
                  address = owner,
                  number = parse_number(owner),
                  state = spec.state,
                  ready_priority = spec.priority,
                }
              end
              item = pointer(next_value)
              next_item(nil)
            end, guard)
          end, guard)
        end
        next_item(nil)
      end, guard)
    end, guard)
  end, guard)
end

local function read_task(session, generation, raw, callback)
  if not valid(generation, session) then callback('target resumed'); return end
  local task = vim.deepcopy(raw)
  local cfg = config()
  local f = fields()
  local expressions = {
    { key = 'name', field = f.name or 'pcTaskName', string = true, required = false },
    { key = 'priority', field = f.priority or 'uxPriority', required = false },
    { key = 'base_priority', field = f.base_priority or 'uxBasePriority', required = false },
    { key = 'runtime', field = f.runtime or 'ulRunTimeCounter', required = false },
    { key = 'top_of_stack', field = f.top_of_stack or 'pxTopOfStack', pointer = true, required = false },
    { key = 'stack', field = f.stack or 'pxStack', pointer = true, required = false },
    { key = 'end_of_stack', field = f.end_of_stack or 'pxEndOfStack', pointer = true, required = false },
  }
  local guard = function() return valid(generation, session) end
  local index = 0
  local function next_field(last_err)
    if not guard() then callback('target resumed'); return end
    if last_err == 'target resumed' then callback(last_err); return end
    if last_err and expressions[index] and expressions[index].required then
      callback(last_err); return
    end
    index = index + 1
    if index > #expressions then
      task.name = task.name or ('<task ' .. task.address .. '>')
      task.priority = task.priority or task.ready_priority or 0
      local top = task.top_of_stack_number
      local base = task.stack_number
      local ending = task.end_of_stack_number
      if top and base and ending then
        local growth = tonumber(cfg.stack_growth) or -1
        local word_bytes = tonumber(cfg.stack_word_bytes) or 4
        if word_bytes <= 0 then word_bytes = 4 end
        local low, high = math.min(base, ending), math.max(base, ending)
        local total = math.floor(math.abs(ending - base) / word_bytes)
        if top >= low and top <= high then
          local words
          if growth < 0 then
            words = math.floor(math.abs(ending - top) / word_bytes)
          else
            words = math.floor(math.abs(top - base) / word_bytes)
          end
          task.stack = string.format('%d/%d words', math.max(0, words), math.max(0, total))
        else
          task.stack = string.format('?/%d words', math.max(0, total))
        end
      else
        task.stack = '-'
      end
      task.runtime = task.runtime_number and tostring(task.runtime_number) or '-'
      callback(nil, task)
      return
    end
    local field = expressions[index]
    resolve_tcb_type(session, task.address, field.field, function(err, value)
      if err then
        next_field(err)
        return
      end
      if field.string then
        local name = parse_name(value)
        if name ~= '' then task.name = name end
      elseif field.pointer then
        local text, number = pointer(value)
        task[field.key] = text or '-'
        task[field.key .. '_number'] = number
      else
        local number = parse_number(value)
        if number ~= nil then
          task[field.key] = number
          task[field.key .. '_number'] = number
        end
      end
      next_field(nil)
    end, guard)
  end
  next_field(nil)
end

local function sort_tasks(tasks)
  local rank = { Running = 0, Ready = 1, Blocked = 2, Suspended = 3, Pending = 4, Terminated = 5 }
  table.sort(tasks, function(a, b)
    local ar, br = rank[a.state] or 99, rank[b.state] or 99
    if ar ~= br then return ar < br end
    if (a.priority or 0) ~= (b.priority or 0) then return (a.priority or 0) > (b.priority or 0) end
    return tostring(a.name) < tostring(b.name)
  end)
end

-- Collect the task metadata after all list nodes have been bounded and
-- deduplicated.  Keeping this stage separate makes the traversal testable.
local function collect_tasks(session, generation, raw_tasks, current_handle, callback)
  local result = {}
  local index = 0
  local function next_task(err)
    if err then callback(err); return end
    if not valid(generation, session) then callback('target resumed'); return end
    index = index + 1
    if index > #raw_tasks then
      sort_tasks(result)
      callback(nil, result)
      return
    end
    local raw = raw_tasks[index]
    read_task(session, generation, raw, function(task_err, task)
      if task_err == 'target resumed' then
        callback(task_err)
        return
      end
      if task_err then
        next_task(nil)
        return
      end
      if task then
        if current_handle and task.number == parse_number(current_handle) then
          task.state, task.running = 'Running', true
        end
        result[#result + 1] = task
      end
      next_task(nil)
    end)
  end
  next_task(nil)
end

-- Walk the kernel lists and collect a stable snapshot of task metadata.
function P.walk(callback)
  local session = active_session()
  if not session or not stopped() then
    callback('target must be stopped', nil)
    return nil, 'target must be stopped'
  end
  local generation = state.generation
  local cfg, sym = config(), symbols()
  local max_tasks = math.max(1, math.floor(tonumber(cfg.max_tasks) or 128))
  local configured_priorities = tonumber(cfg.max_priorities)
  local priority_count = math.max(1, math.floor(configured_priorities or 32))
  local priority_incomplete = configured_priorities == nil
  local count_expr = string.format('sizeof(%s)/sizeof(%s[0])', sym.ready_lists or 'pxReadyTasksLists', sym.ready_lists or 'pxReadyTasksLists')
  local current_handle
  local task_count
  local guard = function() return valid(generation, session) end
  local function start_walk()
    if not guard() then callback('target resumed', nil); return end
    evaluate(session, sym.current_tcb or 'pxCurrentTCB', function(current_err, current_value)
      if current_err then callback(current_err, nil); return end
      current_handle = pointer(current_value)
      evaluate(session, sym.task_count or 'uxCurrentNumberOfTasks', function(_, count_value)
        task_count = parse_number(count_value)
        -- Keep the configured budget independent of uxCurrentNumberOfTasks:
        -- the termination list may contain deleted TCBs outside that count.
        local budget = { remaining = max_tasks, truncated = false }
        local found, unavailable = {}, 0
        sequence(list_specs(priority_count), function(spec, next_spec)
          read_list(session, generation, spec, budget, function(list_err, entries)
            if list_err == 'target resumed' then
              next_spec(list_err)
              return
            end
            if list_err then
              unavailable = unavailable + 1
            else
              for _, entry in ipairs(entries or {}) do
                local old = found[entry.number]
                if not old or (old.state ~= 'Running' and entry.state == 'Ready') then found[entry.number] = entry end
              end
            end
            next_spec(nil)
          end)
        end, function(sequence_err)
          if sequence_err then callback(sequence_err, nil); return end
          local raw_tasks = {}
          for _, task in pairs(found) do raw_tasks[#raw_tasks + 1] = task end
          if current_handle then
            local n = parse_number(current_handle)
            if n and not found[n] then raw_tasks[#raw_tasks + 1] = { address = current_handle, number = n, state = 'Running' } end
          end
          collect_tasks(session, generation, raw_tasks, current_handle, function(task_err, tasks)
            if task_err then callback(task_err, nil); return end
            if #tasks == 0 and unavailable >= #list_specs(priority_count) then
              callback('cannot read FreeRTOS task lists', nil)
              return
            end
            callback(nil, {
              tasks = tasks,
              task_count = task_count,
              unavailable = unavailable,
              truncated = budget.truncated,
              priority_incomplete = priority_incomplete,
            })
          end)
        end)
      end, guard)
    end, guard)
  end
  evaluate(session, count_expr, function(size_err, size_value)
    if not guard() then callback('target resumed', nil); return end
    local detected = not size_err and parse_number(size_value) or nil
    if detected and detected > 0 and detected <= 256 then
      if configured_priorities then
        priority_count = math.min(detected, math.max(1, math.floor(configured_priorities)))
        priority_incomplete = priority_count < detected
      else
        priority_count, priority_incomplete = detected, false
      end
      start_walk()
      return
    end
    -- GDB normally cannot evaluate preprocessor macros, but try the common
    -- spelling before falling back to the configured bound.
    evaluate(session, 'configMAX_PRIORITIES', function(macro_err, macro_value)
      if not guard() then callback('target resumed', nil); return end
      local macro_count = not macro_err and parse_number(macro_value) or nil
      if macro_count and macro_count > 0 and macro_count <= 256 then
        if configured_priorities then
          priority_count = math.min(macro_count, math.max(1, math.floor(configured_priorities)))
          priority_incomplete = priority_count < macro_count
        else
          priority_count, priority_incomplete = macro_count, false
        end
      end
      start_walk()
    end, guard)
  end, guard)
  return true
end

local function buf_valid()
  return state.bufnr and api.nvim_buf_is_valid(state.bufnr)
end

local function win_valid()
  return state.winid and api.nvim_win_is_valid(state.winid)
end

local function render()
  if not buf_valid() then return end
  local count = state.task_count and ('  ' .. tostring(state.task_count) .. ' tasks') or ''
  local lines = { 'Cortex FreeRTOS Tasks  [' .. state.status .. ']' .. count,
    '  S  State       Prio  Name                       Runtime       Stack       Handle',
    '  ' .. string.rep('─', 88) }
  if state.error then lines[#lines + 1] = 'Error: ' .. state.error end
  if #state.tasks == 0 then
    lines[#lines + 1] = state.refreshing and '  (refreshing...)' or '  (no task data -- press r to refresh while stopped)'
  else
    for _, task in ipairs(state.tasks) do
      local marker = task.running and '*' or ' '
      local name = tostring(task.name or '?'):sub(1, 26)
      lines[#lines + 1] = string.format('  %s  %-10s  %4s  %-26s  %-12s  %-10s  %s',
        marker, tostring(task.state or '?'), tostring(task.priority or '-'), name,
        tostring(task.runtime or '-'), tostring(task.stack or '-'), tostring(task.address or '-'))
    end
  end
  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

local function window_config()
  local cfg = config()
  return cfg.window or (core and core.config and core.config.window) or { position = 'bottom', width = 90, height = 16, border = 'rounded', focus_on_open = false }
end

local function create_buf()
  if buf_valid() then return state.bufnr end
  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype, vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = 'nofile', 'hide', false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'cortex-rtos'
  pcall(api.nvim_buf_set_name, bufnr, 'cortex://freertos')
  local opts = { buffer = bufnr, nowait = true, silent = true }
  local function mouse_focus()
    ui.mouse_line(state.winid)
  end
  vim.keymap.set('n', 'q', P.close, opts)
  vim.keymap.set('n', 'r', function() P.refresh() end, opts)
  vim.keymap.set('n', '<LeftMouse>', mouse_focus, opts)
  vim.keymap.set('n', '<2-LeftMouse>', mouse_focus, opts)
  state.bufnr = bufnr
  return bufnr
end

local function open_window()
  if win_valid() then return state.winid end
  local bufnr, w = create_buf(), window_config()
  local previous = api.nvim_get_current_win()
  local winid
  if w.position == 'float' then
    local width = math.min(w.width or 90, math.max(30, vim.o.columns - 4))
    local height = math.min(w.height or 16, math.max(5, vim.o.lines - 6))
    winid = api.nvim_open_win(bufnr, false, { relative = 'editor', width = width, height = height,
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal', border = w.border or 'rounded', title = ' FreeRTOS Tasks ', title_pos = 'center' })
  else
    local position = w.position or 'bottom'
    local command
    if position == 'left' then command = 'topleft vertical ' .. (w.width or 90) .. 'split'
    elseif position == 'top' then command = 'topleft ' .. (w.height or 16) .. 'split'
    elseif position == 'bottom' then command = 'botright ' .. (w.height or 16) .. 'split'
    else command = 'botright vertical ' .. (w.width or 90) .. 'split' end
    vim.cmd(command)
    winid = api.nvim_get_current_win()
    api.nvim_win_set_buf(winid, bufnr)
  end
  vim.wo[winid].number, vim.wo[winid].relativenumber, vim.wo[winid].wrap, vim.wo[winid].signcolumn = false, false, false, 'no'
  pcall(function() vim.wo[winid].winfixheight = true end)
  pcall(function() vim.wo[winid].winfixwidth = true end)
  state.winid = winid
  if not w.focus_on_open and api.nvim_win_is_valid(previous) then api.nvim_set_current_win(previous) end
  render()
  return winid
end

function P.open()
  open_window()
  return state.winid
end

function P.close()
  if win_valid() then pcall(api.nvim_win_close, state.winid, true) end
  state.winid = nil
end

function P.toggle()
  if win_valid() then P.close() else P.open() end
end

function P.refresh(callback)
  if state.cancel_refresh then state.cancel_refresh('refresh superseded') end
  local session = active_session()
  if not session or not stopped() then
    state.status, state.error = 'target running (refresh skipped)', 'target must be stopped'
    render()
    if callback then callback(state.error) end
    return nil, state.error
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.refreshing, state.error, state.status = true, nil, 'refreshing'
  local finished = false
  local cancel
  local function finish(err, data)
    if finished then return end
    finished = true
    if state.cancel_refresh == cancel then state.cancel_refresh = nil end
    state.refreshing = false
    if err then
      state.error, state.status = format_error(err), 'error'
    else
      state.error = nil
      state.tasks, state.task_count = data.tasks or {}, data.task_count
      state.truncated, state.priority_incomplete = data.truncated, data.priority_incomplete
      local notes = {}
      if data.unavailable and data.unavailable > 0 then notes[#notes + 1] = 'some lists unavailable' end
      if data.truncated then notes[#notes + 1] = 'task limit reached' end
      if data.priority_incomplete then notes[#notes + 1] = 'priority bound unverified' end
      state.status = 'stopped / refreshed' .. (#notes > 0 and (' (' .. table.concat(notes, ', ') .. ')') or '')
    end
    render()
    if callback then callback(err, data) end
  end
  cancel = function(err)
    if finished then return end
    finish(err or 'refresh cancelled')
  end
  state.cancel_refresh = cancel
  P.walk(function(err, data)
    if not err and not valid(generation, session) then finish('target resumed'); return end
    finish(err, data)
  end)
  return true
end

function P.on_session_start(config_value)
  if state.cancel_refresh then state.cancel_refresh('new session') end
  state.generation = state.generation + 1
  state.session_config = config_value or {}
  state.tasks, state.task_count, state.error = {}, nil, nil
  state.truncated, state.priority_incomplete = false, false
  state.tcb_type, state.list_item_type = nil, nil
  local cfg = config()
  state.status = cfg.enabled and 'loaded' or 'not enabled'
  if cfg.enabled and cfg.auto_open then
    P.open()
  end
  render()
end

function P.on_session_continued()
  if state.cancel_refresh then state.cancel_refresh('target resumed') end
  state.generation = state.generation + 1
  state.status = 'running (refresh skipped)'
  render()
end

function P.on_session_stopped()
  state.status = 'stopped (refresh available)'
  render()
  if win_valid() and config().auto_refresh_on_stop then P.refresh() end
end

function P.on_session_end()
  if state.cancel_refresh then state.cancel_refresh('session ended') end
  state.generation = state.generation + 1
  state.session_config, state.tasks, state.task_count = nil, {}, nil
  state.truncated, state.priority_incomplete = false, false
  state.status = 'no active session'
  render()
end

function P.setup(owner)
  core = owner
  return P
end

return P
