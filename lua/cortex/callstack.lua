-- Stopped-only current-thread call-stack window.
--
-- This is intentionally separate from both the FreeRTOS task list and dapui:
-- it requests the ordinary DAP stackTrace for the currently stopped CPU
-- thread, and never polls while the target is running.
local api = vim.api

local P = {}
local core
local state = {
  session_config = nil,
  frames = {},
  line_map = {},
  error = nil,
  status = 'not loaded',
  generation = 0,
  refreshing = false,
  cancel_refresh = nil,
  bufnr = nil,
  winid = nil,
}
P._state = state

local DEFAULTS = {
  auto_open = false,
  auto_refresh_on_stop = false,
  levels = 0,
  window = nil,
}

local function get(tbl, key)
  return type(tbl) == 'table' and tbl[key] or nil
end

local function config()
  local base = (core and core.config and core.config.callstack) or {}
  local session = get(state.session_config, 'callstack') or {}
  local result = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), base, session)
  if session.auto_open == nil and session.autoOpen ~= nil then result.auto_open = session.autoOpen end
  if session.auto_refresh_on_stop == nil and session.autoRefreshOnStop ~= nil then
    result.auto_refresh_on_stop = session.autoRefreshOnStop
  end
  if session.levels == nil and session.stackLevels ~= nil then result.levels = session.stackLevels end
  return result
end

local function active_session()
  if core and core._stopped_session then return core._stopped_session() end
  if core and core._is_stopped and not core._is_stopped() then return nil end
  local ok, dap = pcall(require, 'dap')
  if not ok or not dap then return nil end
  local session = dap.session()
  if not session or not session.initialized or not session.stopped_thread_id or not session.current_frame then return nil end
  return session
end

local function stopped()
  if core and core._is_stopped then return core._is_stopped() end
  return active_session() ~= nil
end

local function valid(generation, session)
  return state.generation == generation and stopped() and active_session() == session
end

local function buf_valid()
  return state.bufnr and api.nvim_buf_is_valid(state.bufnr)
end

local function win_valid()
  return state.winid and api.nvim_win_is_valid(state.winid)
end

local function frame_location(frame)
  local source = frame.source or {}
  local path = source.path or source.name or ''
  local line = tonumber(frame.line) or 0
  if path ~= '' and line > 0 then return string.format('%s:%d', path, line) end
  if path ~= '' then return path end
  return tostring(frame.instructionPointerReference or '??')
end

local function render()
  if not buf_valid() then return end
  local session = active_session()
  local thread = session and session.stopped_thread_id or '-'
  local lines = { string.format('Cortex Call Stack  [%s]  thread %s', state.status, tostring(thread)),
    '  #  Function                                      Location',
    '  ' .. string.rep('─', 92) }
  local map = {}
  if state.error then lines[#lines + 1] = 'Error: ' .. state.error end
  if #state.frames == 0 then
    lines[#lines + 1] = state.refreshing and '  (refreshing...)' or '  (no stack data -- press r to refresh while stopped)'
  else
    for index, frame in ipairs(state.frames) do
      local current = session and session.current_frame and session.current_frame.id == frame.id
      local marker = current and '>' or ' '
      local name = tostring(frame.name or '??'):sub(1, 44)
      lines[#lines + 1] = string.format('%s %2d  %-44s  %s', marker, index - 1, name, frame_location(frame))
      map[#lines] = frame
    end
  end
  state.line_map = map
  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

local function window_config()
  local cfg = config()
  return cfg.window or (core and core.config and core.config.window)
    or { position = 'bottom', width = 100, height = 12, border = 'rounded', focus_on_open = false }
end

function P.select()
  if not (win_valid() and state.line_map) then return end
  local line = api.nvim_win_get_cursor(state.winid)[1]
  local frame = state.line_map[line]
  if not frame then return end
  local session = active_session()
  if not session then return end
  if session._frame_set then
    session:_frame_set(frame)
  else
    session.current_frame = frame
  end
  render()
end

local function create_buf()
  if buf_valid() then return state.bufnr end
  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype, vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = 'nofile', 'hide', false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'cortex-callstack'
  pcall(api.nvim_buf_set_name, bufnr, 'cortex://call-stack')
  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set('n', 'q', P.close, opts)
  vim.keymap.set('n', 'r', function() P.refresh() end, opts)
  vim.keymap.set('n', '<CR>', P.select, opts)
  state.bufnr = bufnr
  return bufnr
end

local function open_window()
  if win_valid() then return state.winid end
  local bufnr, w = create_buf(), window_config()
  local previous = api.nvim_get_current_win()
  local winid
  if w.position == 'float' then
    local width = math.min(w.width or 100, math.max(30, vim.o.columns - 4))
    local height = math.min(w.height or 12, math.max(5, vim.o.lines - 6))
    winid = api.nvim_open_win(bufnr, false, { relative = 'editor', width = width, height = height,
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal', border = w.border or 'rounded', title = ' Call Stack ', title_pos = 'center' })
  else
    local position = w.position or 'bottom'
    local command
    if position == 'left' then command = 'topleft vertical ' .. (w.width or 100) .. 'split'
    elseif position == 'top' then command = 'topleft ' .. (w.height or 12) .. 'split'
    elseif position == 'right' then command = 'botright vertical ' .. (w.width or 100) .. 'split'
    else command = 'botright ' .. (w.height or 12) .. 'split' end
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
  local finished = false
  local cancel
  state.refreshing, state.error, state.status = true, nil, 'refreshing'
  local function finish(err, data)
    if finished then return end
    finished = true
    if state.cancel_refresh == cancel then state.cancel_refresh = nil end
    state.refreshing = false
    if err then
      state.error, state.status = tostring(err), 'error'
    else
      state.error, state.frames = nil, (data and data.stackFrames) or {}
      state.status = 'stopped / refreshed'
    end
    render()
    if callback then callback(err, data) end
  end
  cancel = function(err)
    if finished then return end
    finish(err or 'refresh cancelled')
  end
  state.cancel_refresh = cancel
  if not valid(generation, session) then
    finish('target resumed')
    return true
  end
  session:request('stackTrace', {
    threadId = session.stopped_thread_id,
    startFrame = 0,
    levels = tonumber(config().levels) or 0,
  }, function(err, response)
    if not valid(generation, session) then
      finish('target resumed')
      return
    end
    if err then finish(err.message or tostring(err)); return end
    finish(nil, response or {})
  end)
  return true
end

function P.on_session_start(config_value)
  if state.cancel_refresh then state.cancel_refresh('new session') end
  state.generation = state.generation + 1
  state.session_config = config_value or {}
  state.frames, state.line_map, state.error = {}, {}, nil
  local cfg = config()
  state.status = 'loaded'
  if cfg.auto_open then P.open() end
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
  state.session_config, state.frames, state.line_map = nil, {}, {}
  state.status = 'no active session'
  render()
end

function P.setup(owner)
  core = owner
  return P
end

return P
