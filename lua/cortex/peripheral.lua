-- Stopped-only CMSIS-SVD peripheral browser.
--
-- This module intentionally owns a Telnet connection separate from the live
-- watch connection.  It never asks DAP for values and never reads while the
-- target is running.
local api = vim.api
local svd = require('cortex.svd')
local ui = require('cortex.ui')

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
  cancel_refresh = nil,
}
P._state = state

local function get(tbl, key)
  return type(tbl) == 'table' and tbl[key] or nil
end

local function setting(name)
  local cfg = core and core.config or {}
  local pcfg = cfg.peripheral or {}
  return pcfg[name] or cfg[name]
end

local function expand_path(path, config)
  if type(path) ~= 'string' or vim.trim(path) == '' then return nil end
  config = config or state.session_config or {}
  local cwd = get(config, 'cwd') or vim.fn.getcwd()
  local workspace = get(config, 'workspaceFolder') or cwd
  local replacements = {
    workspaceFolder = workspace,
    workspaceRoot = get(config, 'workspaceRoot') or workspace,
    cwd = cwd,
    userHome = vim.env.HOME or vim.fn.expand('~'),
    pathSeparator = package.config:sub(1, 1),
  }
  path = path:gsub('%${([^}]+)}', function(key)
    return tostring(replacements[key] or '${' .. key .. '}')
  end)
  path = vim.fn.expand(path)
  if not path:match('^/') then path = cwd .. '/' .. path end
  return vim.fs.normalize(path)
end

--- Resolve the SVD path from launch config or setup options.
function P.resolve_path(config)
  config = config or state.session_config or {}
  local path = get(config, 'svdFile') or get(config, 'svdPath')
    or get(config, 'svd_file') or get(config, 'svd_path')
    or get(get(config, 'peripheral'), 'svdFile')
    or get(get(config, 'peripheral'), 'svdPath')
    or setting('svdFile') or setting('svdPath')
    or setting('svd_file') or setting('svd_path')
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
    if model.peripherals_by_name[name] then expanded[name] = value end
  end
  state.expanded = expanded
  return model
end

local function current(generation, tel)
  return state.generation == generation and state.telnet == tel and core
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
          if #token % 2 == 1 then token = '0' .. token end
          for i = 1, #token, 2 do bytes[#bytes + 1] = tonumber(token:sub(i, i + 1), 16) end
        end
      end
    end
  end
  return bytes
end

-- Return bytes in least-significant-byte first order for bit extraction.
local function logical_bytes(bytes, endian)
  local result = {}
  for i, byte in ipairs(bytes) do result[i] = byte end
  if not tostring(endian or 'little'):lower():match('big') then return result end
  local reversed = {}
  for i = #result, 1, -1 do reversed[#reversed + 1] = result[i] end
  return reversed
end

local function display_bytes(logical, endian)
  if tostring(endian or 'little'):lower():match('big') then
    local result = {}
    for i = #logical, 1, -1 do result[#result + 1] = logical[i] end
    return result
  end
  local result = {}
  for i = #logical, 1, -1 do result[#result + 1] = logical[i] end
  return result
end

local function hex_bytes(bytes)
  local out = {}
  for _, byte in ipairs(bytes) do out[#out + 1] = string.format('%02x', byte) end
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
  if width <= 32 then return string.format('0x%0' .. math.ceil(width / 4) .. 'x', value) end
  return nil
end

local function mask_hex(offset, width, register_width, endian)
  local bytes = {}
  for i = 1, math.max(1, math.ceil(register_width / 8)) do bytes[i] = 0 end
  for bit = offset, offset + width - 1 do
    local index = math.floor(bit / 8) + 1
    bytes[index] = bytes[index] + 2 ^ (bit % 8)
  end
  return '0x' .. hex_bytes(display_bytes(bytes, endian))
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
  while #physical > byte_count do table.remove(physical) end
  local logical = logical_bytes(physical, endian)
  local value = bits_value(logical, 0, math.min(width, 53))
  local result = {
    value = value,
    width = width,
    bytes = physical,
    hex = '0x' .. hex_bytes(display_bytes(logical, endian)),
    fields = {},
  }
  for _, field in ipairs(register.fields or {}) do
    local offset, field_width = tonumber(field.bitOffset), tonumber(field.bitWidth)
    if offset and field_width and field_width > 0 then
      local field_value = bits_value(logical, offset, math.min(field_width, 53))
      local mask
      if field_width + offset <= 32 then mask = (2 ^ field_width - 1) * 2 ^ offset end
      local enum_name
      for _, enum in ipairs(field.enumeratedValues or {}) do
        if enum.value ~= nil and enum.value == field_value then enum_name = enum.name; break end
      end
      result.fields[field.name] = {
        value = field_value,
        hex = number_hex(field_value, field_width),
        mask = mask and number_hex(mask, 32) or mask_hex(offset, field_width, width, endian),
        enum = enum_name,
      }
    end
  end
  return result
end

P._bytes_from_response = bytes_from_response
P._bits_value = bits_value

function P.register_command(register)
  local access = tostring(register.access or ''):lower():gsub('[%s_-]', '')
  if access == 'writeonly' or access == 'writeonce' then
    return nil
  end
  local size = math.max(1, math.ceil((tonumber(register.size) or 32) / 8))
  return string.format('mdb 0x%08x %d', tonumber(register.address) or 0, size)
end

local function close_telnet()
  if state.telnet then state.telnet:close(); state.telnet = nil end
end

local function render()
  if not (state.bufnr and api.nvim_buf_is_valid(state.bufnr)) then return end
  local lines = { string.format('Cortex SVD Peripherals  [%s]%s', state.status,
    state.path and ('  ' .. state.path) or ''), string.rep('─', 40) }
  local map = {}
  if state.error then lines[#lines + 1] = 'Error: ' .. state.error end
  if not state.model then
    lines[#lines + 1] = '(no SVD loaded)'
  else
    for _, peripheral in ipairs(state.model.peripherals or {}) do
      local open = state.expanded[peripheral.name]
      lines[#lines + 1] = (open and '▾ ' or '▸ ') .. peripheral.name .. string.format('  0x%08x', peripheral.baseAddress or 0)
      map[#lines] = { kind = 'peripheral', peripheral = peripheral }
      if open then
        for _, register in ipairs(peripheral.registers or {}) do
          local key = peripheral.name .. '.' .. register.name
          local ropen = state.expanded[key]
          local value = register.read_error and ('<' .. register.read_error .. '>')
            or (register.decoded and register.decoded.hex or '<not read>')
          if register.readAction then value = value .. ' !' .. register.readAction end
          lines[#lines + 1] = '  ' .. (ropen and '▾ ' or '▸ ') .. register.name
            .. string.format('  +0x%x  %s', register.addressOffset or 0, value)
          map[#lines] = { kind = 'register', peripheral = peripheral, register = register }
          if ropen then
            for _, field in ipairs(register.fields or {}) do
              local decoded = register.decoded and register.decoded.fields[field.name]
              local shown = decoded and (decoded.hex or tostring(decoded.value)) or '<not read>'
              if decoded and decoded.enum then shown = shown .. ' (' .. decoded.enum .. ')' end
              lines[#lines + 1] = string.format('      %s [%s] = %s', field.name,
                decoded and decoded.mask or string.format('[%d:%d]', (field.msb or 0), (field.lsb or 0)), shown)
              map[#lines] = { kind = 'field', peripheral = peripheral, register = register, field = field }
            end
          end
        end
      end
    end
  end
  state.line_map = map
  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

local function toggle_current()
  local item = state.line_map[api.nvim_win_get_cursor(0)[1]]
  if not item then return end
  if item.kind == 'peripheral' then
    state.expanded[item.peripheral.name] = not state.expanded[item.peripheral.name]
  elseif item.kind == 'register' then
    local key = item.peripheral.name .. '.' .. item.register.name
    state.expanded[key] = not state.expanded[key]
  end
  render()
end

local function create_buf()
  if state.bufnr and api.nvim_buf_is_valid(state.bufnr) then return state.bufnr end
  state.bufnr = api.nvim_create_buf(false, true)
  vim.bo[state.bufnr].buftype, vim.bo[state.bufnr].bufhidden = 'nofile', 'hide'
  vim.bo[state.bufnr].swapfile, vim.bo[state.bufnr].filetype = false, 'cortex-peripheral'
  pcall(api.nvim_buf_set_name, state.bufnr, 'cortex://peripherals')
  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  local function mouse_toggle()
    if ui.mouse_line(state.winid) then toggle_current() end
  end
  vim.keymap.set('n', 'q', P.close, opts)
  vim.keymap.set('n', '<CR>', toggle_current, opts)
  vim.keymap.set('n', 'r', P.refresh, opts)
  vim.keymap.set('n', '<LeftMouse>', mouse_toggle, opts)
  vim.keymap.set('n', '<2-LeftMouse>', mouse_toggle, opts)
  return state.bufnr
end

local function open_window()
  if state.winid and api.nvim_win_is_valid(state.winid) then return state.winid end
  local bufnr = create_buf()
  local cfg = (core and core.config and (core.config.peripheral_window or core.config.window)) or {}
  local position, width, height = cfg.position or 'right', cfg.width or 60, cfg.height or 18
  if position == 'float' then
    local w = math.min(width, math.max(20, vim.o.columns - 4))
    local h = math.min(height, math.max(5, vim.o.lines - 6))
    state.winid = api.nvim_open_win(bufnr, true, { relative = 'editor', width = w, height = h,
      row = math.max(1, math.floor((vim.o.lines - h) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - w) / 2)),
      style = 'minimal', border = cfg.border or 'rounded', title = ' Cortex SVD Peripherals ', title_pos = 'center' })
  else
    local command = position == 'left' and ('topleft vertical ' .. width .. 'split')
      or position == 'bottom' and ('botright ' .. height .. 'split')
      or position == 'top' and ('topleft ' .. height .. 'split')
      or ('botright vertical ' .. width .. 'split')
    vim.cmd(command)
    state.winid = api.nvim_get_current_win(); api.nvim_win_set_buf(state.winid, bufnr)
  end
  vim.wo[state.winid].number = false; vim.wo[state.winid].relativenumber = false; vim.wo[state.winid].wrap = false
  vim.wo[state.winid].signcolumn = 'no'
  return state.winid
end

function P.open()
  if not state.model then P.load(state.session_config or {}) end
  create_buf(); open_window(); render()
  return state.bufnr
end

function P.close()
  if state.winid and api.nvim_win_is_valid(state.winid) then pcall(api.nvim_win_close, state.winid, true) end
  state.winid = nil
end

function P.toggle()
  if state.winid and api.nvim_win_is_valid(state.winid) then P.close() else P.open() end
end

--- Refresh register values. This is deliberately rejected unless stopped.
function P.refresh(callback)
  if state.cancel_refresh then state.cancel_refresh('refresh superseded') end
  if core and core._is_stopped and not core._is_stopped() then
    state.status = 'target running (refresh skipped)'; render()
    if callback then callback('target must be stopped') end
    return nil, 'target must be stopped'
  end
  if not state.model then
    local _, err = P.load(state.session_config)
    if err then if callback then callback(err) end; render(); return nil, err end
  end
  local config = state.session_config or {}
  close_telnet()
  local tel = core and core._new_peripheral_telnet and core._new_peripheral_telnet(config)
  if not tel then
    state.status, state.error = 'error', 'peripheral Telnet client unavailable'
    render(); return nil, state.error
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.telnet, state.refreshing, state.status = tel, true, 'connecting'
  local registers = {}
  local pcfg = (core and core.config and core.config.peripheral) or {}
  local read_all = pcfg.read_all or pcfg.readAll
  local has_window = state.bufnr and api.nvim_buf_is_valid(state.bufnr)
  for _, peripheral in ipairs(state.model.peripherals or {}) do
    -- A real SVD can contain thousands of registers. In the browser, read
    -- only expanded peripherals by default; headless/API callers can request
    -- the complete model with peripheral.read_all = true.
    if read_all or not has_window or state.expanded[peripheral.name] then
      for _, register in ipairs(peripheral.registers or {}) do registers[#registers + 1] = register end
    end
  end
  local index = 0
  local finished = false
  local function cancel(err)
    if finished then return end
    finished = true
    if state.cancel_refresh == cancel then state.cancel_refresh = nil end
    state.refreshing = false
    if callback then callback(err) end
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
    if index >= #registers then done(nil); return end
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
    if err then done(err); return end
    next_register()
  end)
  return true
end

function P.on_session_start(config)
  if state.cancel_refresh then state.cancel_refresh('new session') end
  state.generation = state.generation + 1
  close_telnet()
  state.session_config = config or {}
  state.status, state.error = 'loading', nil
  P.load(state.session_config)
  render()
end

function P.on_session_continued()
  if state.cancel_refresh then state.cancel_refresh('target resumed') end
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
  if state.cancel_refresh then state.cancel_refresh('session ended') end
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
