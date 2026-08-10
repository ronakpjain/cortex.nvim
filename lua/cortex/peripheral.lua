-- Stopped-only CMSIS-SVD browser with its own OpenOCD connection.
local api = vim.api
local config_util = require('cortex.config')
local Telnet = require('cortex.telnet')
local svd = require('cortex.svd')
local ui = require('cortex.ui')
local view = require('cortex.view')

local P = {}
local core
local state = {
  model = nil,
  path = nil,
  error = nil,
  session_config = nil,
  telnet = nil,
  generation = 0,
  bufnr = nil,
  winid = nil,
  line_map = {},
  expanded = {},
  status = 'not loaded',
  refreshing = false,
  element_mode = false,
  cancel_refresh = nil,
}
P._state = state

local pane = view.new(state, {
  name = 'cortex://peripherals',
  filetype = 'cortex-peripheral',
  title = 'Cortex SVD Peripherals',
  element = 'cortex_peripherals',
  float_width = 110,
  float_height = 24,
  window = {
    position = 'right',
    width = 60,
    height = 18,
    border = 'rounded',
    focus_on_open = true,
    min_width = 20,
  },
})

local function setting(name)
  local cfg = core and core.config or {}
  local pcfg = cfg.peripheral or {}
  return pcfg[name] or cfg[name]
end

local function new_telnet(config)
  if core and core._new_peripheral_telnet then
    return core._new_peripheral_telnet(config)
  end
  config = config or state.session_config or {}
  local pcfg = (core and core.config and core.config.peripheral) or {}
  local host = config_util.get(config, 'svdTelnetHost')
    or config_util.get(config, 'peripheralTelnetHost')
    or config_util.get(config, 'telnetHost')
    or config_util.get(config, 'openocdTelnetHost')
    or pcfg.host
    or '127.0.0.1'
  local port = config_util.get(config, 'svdTelnetPort')
    or config_util.get(config, 'peripheralTelnetPort')
    or config_util.get(config, 'telnetPort')
    or config_util.get(config, 'openocdTelnetPort')
    or pcfg.port
    or 4444
  local timeout = tonumber(pcfg.timeout_ms or pcfg.timeoutMs) or 1000
  return Telnet.new(tostring(host), tonumber(port) or 4444, timeout)
end

local function any(tbl, keys)
  return config_util.first(tbl, keys)
end

local function placeholder(value)
  return type(value) == 'string' and value:match('^%${[^}]+}$') ~= nil
end

local function workspace_fallback()
  local path = vim.fs.normalize(vim.fn.getcwd())
  while path and path ~= '' do
    if vim.fn.filereadable(path .. '/.vscode/launch.json') == 1 or vim.fn.isdirectory(path .. '/.git') == 1 then
      return path
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
      break
    end
    path = parent
  end
  return vim.fs.normalize(vim.fn.getcwd())
end

local function resolve_dir(value, fallback)
  if type(value) ~= 'string' or vim.trim(value) == '' or placeholder(value) then
    return fallback
  end
  value = vim.fn.expand(value)
  if not value:match('^/') then
    value = fallback .. '/' .. value
  end
  return vim.fs.normalize(value)
end

local function expand_path(path, config)
  if type(path) ~= 'string' or vim.trim(path) == '' then
    return nil
  end
  config = config or state.session_config or {}
  local workspace_value = any(config, {
    'workspaceRoot',
    'workspaceroot',
    'workspace_root',
    'workspaceFolder',
    'workspacefolder',
    'workspace_folder',
    'cwd',
  })
  local workspace = resolve_dir(workspace_value, workspace_fallback())
  local cwd = resolve_dir(config_util.get(config, 'cwd'), workspace)
  local replacements = {
    workspaceFolder = workspace,
    workspaceRoot = workspace,
    workspaceroot = workspace,
    workspacefolder = workspace,
    cwd = cwd,
    userHome = vim.env.HOME or vim.fn.expand('~'),
    pathSeparator = package.config:sub(1, 1),
  }
  path = path:gsub('%${([^}]+)}', function(key)
    return tostring(replacements[key] or replacements[key:lower()] or '${' .. key .. '}')
  end)
  path = vim.fn.expand(path)
  if not path:match('^/') then
    path = cwd .. '/' .. path
  end
  return vim.fs.normalize(path)
end

--- Resolve the SVD path from launch config or setup options.
function P.resolve_path(config)
  config = config or state.session_config or {}
  local path = config_util.get(config, 'svdFile')
    or config_util.get(config, 'svdPath')
    or config_util.get(config, 'svd_file')
    or config_util.get(config, 'svd_path')
    or config_util.get(config_util.get(config, 'peripheral'), 'svdFile')
    or config_util.get(config_util.get(config, 'peripheral'), 'svdPath')
    or setting('svdFile')
    or setting('svdPath')
    or setting('svd_file')
    or setting('svd_path')
  return expand_path(path, config)
end

function P.load(config)
  config = config or state.session_config or {}
  local path = P.resolve_path(config)
  state.session_config = config
  state.path, state.error = path, nil
  state.model = nil
  if not path then
    state.status = 'no SVD configured'
    state.error = state.status
    return nil, state.error
  end
  local model, err = svd.load_file(path)
  if not model then
    state.status = 'load failed'
    state.error = tostring(err or 'cannot load SVD')
    return nil, state.error
  end
  state.model = model
  state.status = 'loaded'
  -- A reload must not retain expansion state for peripherals that disappeared.
  local expanded = {}
  for name, value in pairs(state.expanded) do
    if model.peripherals_by_name[name] then
      expanded[name] = value
    end
  end
  state.expanded = expanded
  return model
end

local function current(generation, tel)
  return state.generation == generation
    and state.telnet == tel
    and core
    and (not core._is_stopped or core._is_stopped())
end

local function bytes_from_response(response)
  local bytes = {}
  for line in tostring(response or ''):gmatch('[^\n]+') do
    local rhs = line:match(':%s*(.*)$')
    if rhs then
      for token in rhs:gmatch('%S+') do
        token = token:gsub('^0[xX]', ''):gsub('[^%x].*$', '')
        if #token > 0 and #token <= 2 and token:match('^%x+$') then
          bytes[#bytes + 1] = tonumber(token, 16)
        elseif #token > 2 and token:match('^%x+$') then
          -- Be liberal for fake telnet servers and mdw-style replies.
          if #token % 2 == 1 then
            token = '0' .. token
          end
          for i = 1, #token, 2 do
            bytes[#bytes + 1] = tonumber(token:sub(i, i + 1), 16)
          end
        end
      end
    end
  end
  return bytes
end

-- Return bytes in least-significant-byte first order for bit extraction.
local function logical_bytes(bytes, endian)
  local result = {}
  for i, byte in ipairs(bytes) do
    result[i] = byte
  end
  if not tostring(endian or 'little'):lower():match('big') then
    return result
  end
  local reversed = {}
  for i = #result, 1, -1 do
    reversed[#reversed + 1] = result[i]
  end
  return reversed
end

local function display_bytes(logical)
  -- `logical` is least-significant byte first for both target endiannesses;
  -- reverse it once to produce the conventional most-significant-first hex.
  local result = {}
  for i = #logical, 1, -1 do
    result[#result + 1] = logical[i]
  end
  return result
end

local function hex_bytes(bytes)
  local out = {}
  for _, byte in ipairs(bytes) do
    out[#out + 1] = string.format('%02x', byte)
  end
  return table.concat(out)
end

local function bits_value(bytes, offset, width)
  local result = 0
  for i = 0, width - 1 do
    local byte = bytes[math.floor((offset + i) / 8) + 1] or 0
    local bit = math.floor(byte / 2 ^ ((offset + i) % 8)) % 2
    result = result + bit * 2 ^ i
  end
  return result
end

local function number_hex(value, width)
  if width <= 32 then
    return string.format('0x%0' .. math.ceil(width / 4) .. 'x', value)
  end
  return nil
end

local function mask_hex(offset, width, register_width)
  local bytes = {}
  for i = 1, math.max(1, math.ceil(register_width / 8)) do
    bytes[i] = 0
  end
  for bit = offset, offset + width - 1 do
    local index = math.floor(bit / 8) + 1
    bytes[index] = bytes[index] + 2 ^ (bit % 8)
  end
  return '0x' .. hex_bytes(display_bytes(bytes))
end

--- Decode an OpenOCD memory response according to register width/endianness.
--- The returned field values are numeric where representable by Lua numbers.
function P.decode_register(register, response, endian)
  local width = tonumber(register.size) or 32
  local byte_count = math.max(1, math.ceil(width / 8))
  local physical = bytes_from_response(response)
  if #physical < byte_count then
    return nil, string.format('incomplete memory response (%d/%d bytes)', #physical, byte_count)
  end
  while #physical > byte_count do
    table.remove(physical)
  end
  local logical = logical_bytes(physical, endian)
  local value = bits_value(logical, 0, math.min(width, 53))
  local result = {
    value = value,
    width = width,
    bytes = physical,
    hex = '0x' .. hex_bytes(display_bytes(logical)),
    fields = {},
  }
  for _, field in ipairs(register.fields or {}) do
    local offset, field_width = tonumber(field.bitOffset), tonumber(field.bitWidth)
    if offset and field_width and field_width > 0 then
      local field_value = bits_value(logical, offset, math.min(field_width, 53))
      local mask
      if field_width + offset <= 32 then
        mask = (2 ^ field_width - 1) * 2 ^ offset
      end
      local enum_name
      for _, enum in ipairs(field.enumeratedValues or {}) do
        if enum.value ~= nil and enum.value == field_value then
          enum_name = enum.name
          break
        end
      end
      result.fields[field.name] = {
        value = field_value,
        hex = number_hex(field_value, field_width),
        mask = mask and number_hex(mask, 32) or mask_hex(offset, field_width, width),
        enum = enum_name,
      }
    end
  end
  return result
end

function P.register_command(register)
  local access = tostring(register.access or ''):lower():gsub('[%s_-]', '')
  if access == 'writeonly' or access == 'writeonce' then
    return nil
  end
  local size = math.max(1, math.ceil((tonumber(register.size) or 32) / 8))
  return string.format('mdb 0x%08x %d', tonumber(register.address) or 0, size)
end

local function close_telnet()
  if state.telnet then
    state.telnet:close()
    state.telnet = nil
  end
end

local function mark_text(highlights, line, source, text, group, start)
  if not text or text == '' then
    return
  end
  local at = source:find(text, start or 1, true)
  if not at then
    return
  end
  highlights[#highlights + 1] = {
    line = line,
    group = group,
    start = at - 1,
    finish = at - 1 + #text,
  }
end

local function render()
  if not pane:buf_valid() then
    return
  end
  local content_width = ui.content_width(state.bufnr, 80)
  local item_width = math.max(10, math.min(26, math.floor((content_width - 16) * 0.55)))
  local value_width = math.max(6, content_width - item_width - 16)
  local icon, status_group = ui.status_icon(state.status)
  local shown_path = state.path and vim.fn.fnamemodify(state.path, ':~') or '(not configured)'
  local status = ui.truncate(state.status, math.max(8, content_width - 6))
  local path = ui.truncate(shown_path, math.max(8, content_width - 6))
  local item_header = ui.truncate('Peripheral / Register', item_width)
  local lines = {
    'Cortex SVD Peripherals',
    string.format('  %s  %s', icon, status),
    '  SVD  ' .. path,
    string.format('  %-' .. item_width .. 's  %-10s  %s', item_header, 'Address', ui.truncate('Value', value_width)),
    '  ' .. string.rep('─', content_width),
  }
  local highlights = {
    { line = 1, group = 'CortexTitle' },
    { line = 2, group = status_group, start = 2, finish = -1 },
    { line = 3, group = 'CortexDim' },
    { line = 4, group = 'CortexHeader' },
    { line = 5, group = 'CortexSeparator' },
  }
  local map = {}
  local function add_line(text, item, group)
    lines[#lines + 1] = text
    if item then
      map[#lines] = item
    end
    if group then
      ui.highlight_line(highlights, #lines, group)
    end
    return #lines
  end
  if state.error then
    add_line('  ✖ ' .. ui.truncate(state.error, content_width - 4), nil, 'CortexError')
  end
  if not state.model then
    add_line('  (no SVD loaded)', nil, 'CortexDim')
  else
    for _, peripheral in ipairs(state.model.peripherals or {}) do
      local open = state.expanded[peripheral.name]
      local address = string.format('0x%08x', peripheral.baseAddress or 0)
      local name = ui.truncate(peripheral.name, item_width - 2)
      local line_text = string.format(
        '  %s %-' .. (item_width - 2) .. 's  %-10s  %s',
        open and '▾' or '▸',
        name,
        address,
        ui.truncate('', value_width)
      )
      local line = add_line(line_text, { kind = 'peripheral', peripheral = peripheral }, 'CortexName')
      mark_text(highlights, line, line_text, address, 'CortexAddress')
      if open then
        for _, register in ipairs(peripheral.registers or {}) do
          local key = peripheral.name .. '.' .. register.name
          local ropen = state.expanded[key]
          local value = register.read_error and ('<' .. register.read_error .. '>')
            or (register.decoded and register.decoded.hex or '<not read>')
          if register.readAction then
            value = value .. ' !' .. register.readAction
          end
          local register_name = ui.truncate(register.name, item_width - 6)
          local register_value = ui.truncate(value, value_width)
          local register_line = string.format(
            '      %s %-' .. (item_width - 6) .. 's  +0x%04x  %s',
            ropen and '▾' or '▸',
            register_name,
            register.addressOffset or 0,
            register_value
          )
          local rline = add_line(
            register_line,
            { kind = 'register', peripheral = peripheral, register = register },
            register.read_error and 'CortexError' or 'CortexName'
          )
          mark_text(
            highlights,
            rline,
            register_line,
            register_value,
            register.read_error and 'CortexError' or 'CortexValue'
          )
          if ropen then
            for _, field in ipairs(register.fields or {}) do
              local decoded = register.decoded and register.decoded.fields[field.name]
              local shown = decoded and (decoded.hex or tostring(decoded.value)) or '<not read>'
              if decoded and decoded.enum then
                shown = shown .. ' (' .. decoded.enum .. ')'
              end
              local bits = decoded and decoded.mask or string.format('[%d:%d]', (field.msb or 0), (field.lsb or 0))
              local field_name = ui.truncate(field.name, math.max(6, item_width - 10))
              local field_value = ui.truncate(shown, value_width)
              local field_line = string.format(
                '          %-' .. math.max(6, item_width - 10) .. 's  %-10s  %s',
                field_name,
                ui.truncate(bits, 10),
                field_value
              )
              local fline = add_line(
                field_line,
                { kind = 'field', peripheral = peripheral, register = register, field = field },
                'CortexDim'
              )
              mark_text(highlights, fline, field_line, field_value, decoded and 'CortexValue' or 'CortexDim')
            end
          end
        end
      end
    end
  end
  state.line_map = map
  ui.render(state.bufnr, lines, highlights)
end

local function toggle_current()
  local item = state.line_map[api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  if item.kind == 'peripheral' then
    state.expanded[item.peripheral.name] = not state.expanded[item.peripheral.name]
  elseif item.kind == 'register' then
    local key = item.peripheral.name .. '.' .. item.register.name
    state.expanded[key] = not state.expanded[key]
  end
  render()
end

local function create_buf()
  local bufnr, created = pane:buffer()
  if not created then
    return bufnr
  end
  local opts = { buffer = bufnr, nowait = true, silent = true }
  local function mouse_toggle()
    local winid = pane:window()
    if winid and ui.mouse_line(winid) then
      toggle_current()
    end
  end
  vim.keymap.set('n', 'q', function()
    pane:close_from_buffer(P.close)
  end, opts)
  vim.keymap.set('n', '<CR>', toggle_current, opts)
  vim.keymap.set('n', 'r', P.refresh, opts)
  vim.keymap.set('n', '<LeftMouse>', mouse_toggle, opts)
  vim.keymap.set('n', '<2-LeftMouse>', mouse_toggle, opts)
  return bufnr
end

local function window_config()
  local peripheral_config = core and core.config and core.config.peripheral
  return (peripheral_config and peripheral_config.window) or (core and core.config and core.config.window)
end

function P.open()
  if not state.model then
    P.load(state.session_config or {})
  end
  create_buf()
  if not state.element_mode then
    pane:open(window_config())
  end
  render()
  return state.bufnr
end

local function before_close()
  if state.cancel_refresh then
    state.cancel_refresh('view closed')
  end
  close_telnet()
end

function P.close()
  before_close()
  pane:close()
end

function P.toggle()
  if pane:win_valid() then
    before_close()
  elseif not state.element_mode and not state.model then
    P.load(state.session_config or {})
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
  if not state.model and state.session_config then
    P.load(state.session_config)
  end
  render()
  return element
end

--- Refresh register values. This is deliberately rejected unless stopped.
function P.refresh(callback)
  if state.cancel_refresh then
    state.cancel_refresh('refresh superseded')
  end
  if core and core._is_stopped and not core._is_stopped() then
    state.status = 'target running (refresh skipped)'
    render()
    if callback then
      callback('target must be stopped')
    end
    return nil, 'target must be stopped'
  end
  if not state.model then
    local _, err = P.load(state.session_config)
    if err then
      if callback then
        callback(err)
      end
      render()
      return nil, err
    end
  end
  local config = state.session_config or {}
  close_telnet()
  local tel = new_telnet(config)
  state.generation = state.generation + 1
  local generation = state.generation
  state.telnet, state.refreshing, state.status = tel, true, 'connecting'
  local registers = {}
  local pcfg = (core and core.config and core.config.peripheral) or {}
  local read_all = pcfg.read_all or pcfg.readAll
  local has_window = pane:buf_valid()
  for _, peripheral in ipairs(state.model.peripherals or {}) do
    -- A real SVD can contain thousands of registers. In the browser, read
    -- only expanded peripherals by default; headless/API callers can request
    -- the complete model with peripheral.read_all = true.
    if read_all or not has_window or state.expanded[peripheral.name] then
      for _, register in ipairs(peripheral.registers or {}) do
        registers[#registers + 1] = register
      end
    end
  end
  local index = 0
  local finished = false
  local function cancel(err)
    if finished then
      return
    end
    finished = true
    if state.cancel_refresh == cancel then
      state.cancel_refresh = nil
    end
    state.refreshing = false
    if callback then
      callback(err)
    end
  end
  state.cancel_refresh = cancel
  local function done(err)
    if not current(generation, tel) then
      state.status = 'target resumed (refresh cancelled)'
      cancel(err or 'target resumed')
      render()
      return
    end
    state.status = err and ('error: ' .. tostring(err)) or 'stopped / refreshed'
    state.error = err and tostring(err) or nil
    cancel(err)
    render()
  end
  local function next_register()
    if not current(generation, tel) then
      done('target resumed')
      return
    end
    if index >= #registers then
      done(nil)
      return
    end
    if not core._is_stopped() then
      close_telnet()
      state.status = 'target running (refresh skipped)'
      cancel('target must be stopped')
      render()
      return
    end
    index = index + 1
    local register = registers[index]
    local command = P.register_command(register)
    if not command then
      register.decoded = nil
      register.read_error = 'not readable (' .. tostring(register.access or 'write-only') .. ')'
      next_register()
      return
    end
    tel:send(command, function(err, response)
      if not current(generation, tel) then
        done('target resumed')
        return
      end
      if err then
        register.decoded = nil
        register.read_error = tostring(err)
      else
        local endian = state.model.cpu and state.model.cpu.endian or 'little'
        local decoded, decode_err = P.decode_register(register, response, endian)
        register.decoded = decoded
        register.read_error = decode_err
      end
      next_register()
    end)
  end
  tel:connect(function(err)
    if not current(generation, tel) then
      done('target resumed')
      return
    end
    if err then
      done(err)
      return
    end
    next_register()
  end)
  return true
end

function P.on_session_start(config)
  if state.cancel_refresh then
    state.cancel_refresh('new session')
  end
  state.generation = state.generation + 1
  close_telnet()
  state.session_config = config or {}
  state.status, state.error = 'loading', nil
  P.load(state.session_config)
  render()
end

function P.on_session_continued()
  if state.cancel_refresh then
    state.cancel_refresh('target resumed')
  end
  state.generation = state.generation + 1
  close_telnet()
  state.refreshing = false
  state.status = 'running (refresh skipped)'
  render()
end

function P.on_session_stopped()
  if state.model then
    state.status = 'stopped (refresh available)'
    state.error = nil
    render()
  end
end

function P.on_session_end()
  if state.cancel_refresh then
    state.cancel_refresh('session ended')
  end
  state.generation = state.generation + 1
  close_telnet()
  state.session_config, state.model, state.path = nil, nil, nil
  state.refreshing, state.status = false, 'no active session'
  render()
end

function P.setup(owner)
  core = owner
  return P
end

return P
