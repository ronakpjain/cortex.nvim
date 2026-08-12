-- Stopped-only DAP call-stack view.
local api = vim.api
local config_util = require('cortex.config')
local session_util = require('cortex.session')
local ui = require('cortex.ui')
local view = require('cortex.view')

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
  element_mode = false,
}
P._state = state

local pane = view.new(state, {
  name = 'cortex://call-stack',
  filetype = 'cortex-callstack',
  title = 'Call Stack',
  element_title = 'Cortex Call Stack',
  element = 'cortex_callstack',
  float_width = 110,
  float_height = 20,
  window = {
    position = 'bottom',
    width = 100,
    height = 12,
    border = 'rounded',
    focus_on_open = false,
    min_width = 30,
  },
})

local DEFAULTS = {
  auto_open = false,
  auto_refresh_on_stop = true,
  levels = 0,
  window = nil,
}

local function config()
  local base = (core and core.config and core.config.callstack) or {}
  local launch = config_util.get(state.session_config, 'callstack')
  return config_util.merge(DEFAULTS, base, launch, {
    auto_open = 'autoOpen',
    auto_refresh_on_stop = 'autoRefreshOnStop',
    levels = 'stackLevels',
  })
end

local function active_session()
  return session_util.stopped(core)
end

local function stopped()
  return session_util.is_stopped(core)
end

local function valid(generation, session)
  return session_util.is_current(core, state, generation, session)
end

local function frame_location(frame)
  local source = frame.source or {}
  local path = source.path or source.name or ''
  local line = tonumber(frame.line) or 0
  if path ~= '' and line > 0 then
    return string.format('%s:%d', path, line)
  end
  if path ~= '' then
    return path
  end
  return tostring(frame.instructionPointerReference or '??')
end

local function render()
  if not pane:buf_valid() then
    return
  end
  local content_width = ui.content_width(state.bufnr, 100)
  local name_width = math.max(12, math.min(44, math.floor((content_width - 15) * 0.55)))
  local location_width = math.max(8, content_width - name_width - 10)
  local session = active_session()
  local thread = session and session.stopped_thread_id or '-'
  local icon, status_group = ui.status_icon(state.status)
  local lines = {
    'Cortex Call Stack',
    ui.truncate(string.format('  %s  %s  Thread: %s', icon, tostring(state.status), tostring(thread)), content_width),
    string.format('  #   %-' .. name_width .. 's  %s', 'Function', ui.truncate('Location', location_width)),
    '  ' .. string.rep('─', content_width),
  }
  local highlights = {
    { line = 1, group = 'CortexTitle' },
    { line = 2, group = status_group, start = 2, finish = -1 },
    { line = 3, group = 'CortexHeader' },
    { line = 4, group = 'CortexSeparator' },
  }
  local map = {}
  local function add_line(text, group)
    lines[#lines + 1] = ui.truncate(text, content_width)
    if group then
      ui.highlight_line(highlights, #lines, group)
    end
    return #lines
  end
  if state.error then
    add_line('  ✖ ' .. tostring(state.error), 'CortexError')
  end
  if #state.frames == 0 then
    add_line(
      state.refreshing and '  ◌ refreshing stack...' or '  (no stack data -- press r to refresh while stopped)',
      'CortexDim'
    )
  else
    for index, frame in ipairs(state.frames) do
      local current = session and session.current_frame and session.current_frame.id == frame.id
      local marker = current and '▶' or '·'
      local name = ui.truncate(frame.name or '??', name_width)
      local location = ui.truncate(frame_location(frame), location_width)
      local line = add_line(
        string.format('  %s %2d  %-' .. name_width .. 's  %s', marker, index - 1, name, location),
        current and 'CortexCurrent' or nil
      )
      local at = lines[line]:find(name, 1, true)
      if at then
        highlights[#highlights + 1] = {
          line = line,
          group = current and 'CortexName' or 'CortexValue',
          start = at - 1,
          finish = at - 1 + #name,
        }
      end
      local location_at = lines[line]:find(location, 1, true)
      if location_at then
        highlights[#highlights + 1] =
          { line = line, group = 'CortexDim', start = location_at - 1, finish = location_at - 1 + #location }
      end
      map[line] = frame
    end
  end
  state.line_map = map
  ui.render(state.bufnr, lines, highlights)
end

local function window_config()
  return config().window or (core and core.config and core.config.window)
end

function P.select()
  local winid = pane:window()
  if not (winid and state.line_map) then
    return
  end
  local line = api.nvim_win_get_cursor(winid)[1]
  local frame = state.line_map[line]
  if not frame then
    return
  end
  local session = active_session()
  if not session then
    return
  end
  if session._frame_set then
    session:_frame_set(frame)
  else
    session.current_frame = frame
  end
  render()
end

local function create_buf()
  local bufnr, created = pane:buffer()
  if not created then
    return bufnr
  end
  local opts = { buffer = bufnr, nowait = true, silent = true }
  local function mouse_select()
    local winid = pane:window()
    if winid and ui.mouse_line(winid) then
      P.select()
    end
  end
  vim.keymap.set('n', 'q', function()
    pane:close_from_buffer(P.close)
  end, opts)
  vim.keymap.set('n', 'r', function()
    P.refresh()
  end, opts)
  vim.keymap.set('n', '<CR>', P.select, opts)
  vim.keymap.set('n', '<LeftMouse>', mouse_select, opts)
  vim.keymap.set('n', '<2-LeftMouse>', mouse_select, opts)
  return bufnr
end

function P.open()
  create_buf()
  if state.element_mode then
    render()
    return nil
  end
  pane:open(window_config())
  render()
  return state.winid
end

function P.close()
  if state.cancel_refresh then
    state.cancel_refresh('view closed')
  end
  pane:close()
end

function P.toggle()
  if pane:win_valid() and state.cancel_refresh then
    state.cancel_refresh('view closed')
  end
  create_buf()
  local action = pane:toggle(window_config())
  if action == 'opened' then
    render()
  end
end

function P.element()
  create_buf()
  local element = pane:element(render, create_buf)
  render()
  return element
end

function P.refresh(callback)
  if state.cancel_refresh then
    state.cancel_refresh('refresh superseded')
  end
  local session = active_session()
  if not session or not stopped() then
    state.status, state.error = 'target running (refresh skipped)', 'target must be stopped'
    render()
    if callback then
      callback(state.error)
    end
    return nil, state.error
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local finished = false
  local cancel
  state.refreshing, state.error, state.status = true, nil, 'refreshing'
  local function finish(err, data)
    if finished then
      return
    end
    finished = true
    if state.cancel_refresh == cancel then
      state.cancel_refresh = nil
    end
    state.refreshing = false
    if err then
      state.error, state.status = tostring(err), 'error'
    else
      state.error, state.frames = nil, (data and data.stackFrames) or {}
      state.status = 'stopped / refreshed'
    end
    render()
    if callback then
      callback(err, data)
    end
  end
  cancel = function(err)
    if finished then
      return
    end
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
    if err then
      finish(err.message or tostring(err))
      return
    end
    finish(nil, response or {})
  end)
  return true
end

function P.on_session_start(config_value)
  if state.cancel_refresh then
    state.cancel_refresh('new session')
  end
  state.generation = state.generation + 1
  state.session_config = config_value or {}
  state.frames, state.line_map, state.error = {}, {}, nil
  local cfg = config()
  state.status = 'loaded'
  if cfg.auto_open then
    P.open()
  end
end

function P.on_session_continued()
  if state.cancel_refresh then
    state.cancel_refresh('target resumed')
  end
  state.generation = state.generation + 1
  state.status = 'running (refresh skipped)'
  render()
end

function P.on_session_stopped()
  state.status = 'stopped (refresh available)'
  render()
  if (pane:win_valid() or state.element_mode) and config().auto_refresh_on_stop then
    P.refresh()
  end
end

function P.on_session_end()
  if state.cancel_refresh then
    state.cancel_refresh('session ended')
  end
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
