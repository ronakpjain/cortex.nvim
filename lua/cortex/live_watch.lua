-- DAP hydrates watch metadata while stopped; OpenOCD samples it while running.
local api = vim.api
local uv = vim.uv or vim.loop
local config_util = require('cortex.config')
local Telnet = require('cortex.telnet')
local ui = require('cortex.ui')
local view = require('cortex.view')

local L = {}
local core
local watch

local function notify(msg, level)
  vim.notify('[cortex.nvim] ' .. msg, level or vim.log.levels.INFO)
end

--- OpenOCD commands we accept verbatim as watch entries.
local OPENOCD_COMMANDS = {
  mdw = true,
  mdh = true,
  mdb = true,
  mdd = true,
  reg = true,
  targets = true,
  ['mem2array'] = true,
  ['adapter'] = true,
  ['rtt'] = true,
}

---@param raw string
---@return 'command'|'address'|'symbol'
local function classify(raw)
  local trimmed = vim.trim(raw)
  local head = trimmed:match('^([%a_][%w_]*)')
  if head and OPENOCD_COMMANDS[head:lower()] then
    return 'command'
  end
  if trimmed:match('^0[xX]%x+$') or trimmed:match('^%d+$') then
    return 'address'
  end
  return 'symbol'
end

---@param raw string
---@return integer|nil
local function parse_number(raw)
  local trimmed = vim.trim(raw)
  local hex = trimmed:match('^0[xX](%x+)$')
  if hex then
    return tonumber(hex, 16)
  end
  return tonumber(trimmed, 10)
end

---@param size integer|nil
---@return string cmd, integer count
local function md_for_size(size)
  size = size or 4
  if size == 1 then
    return 'mdb', 1
  elseif size == 2 then
    return 'mdh', 1
  elseif size <= 4 then
    return 'mdw', 1
  end
  local words = math.ceil(size / 4)
  if words > 8 then
    words = 8
  end
  return 'mdw', words
end

---@class cortex.Entry
---@field raw string
---@field kind 'command'|'address'|'symbol'
---@field address integer|nil
---@field size integer|nil
---@field command string|nil
---@field value string|nil
---@field error string|nil
---@field resolving boolean|nil

---@param raw string
---@return cortex.Entry
local function make_entry(raw)
  local entry = {
    raw = vim.trim(raw),
    kind = classify(raw),
    value = nil,
    error = nil,
  }
  if entry.kind == 'command' then
    entry.command = entry.raw
  elseif entry.kind == 'address' then
    entry.address = parse_number(entry.raw)
    entry.size = 4
    entry.command = string.format('mdw 0x%08x 1', entry.address or 0)
  end
  return entry
end
---@param s string|nil
---@return integer|nil
local function first_hex(s)
  if not s then
    return nil
  end
  local hex = s:match('0[xX](%x+)')
  if hex then
    return tonumber(hex, 16)
  end
  local dec = s:match('^%s*(%-?%d+)%s*$')
  if dec then
    return tonumber(dec, 10)
  end
  return nil
end

local function stopped_session()
  return core and core._stopped_session and core._stopped_session() or nil
end

--- Cancel outstanding stopped-state metadata requests. Keep existing hydrated
--- nodes intact when merely resuming; they remain valid telnet poll plans.
local function invalidate_hydration()
  local state = watch
  if not state then
    return
  end
  state.generation = (state.generation or 0) + 1
  for _, entry in ipairs(state.entries or {}) do
    if entry.kind == 'symbol' then
      entry.hydration_id = (entry.hydration_id or 0) + 1
      entry.resolving = false
    end
  end
end

local function dap_error(err, fallback)
  if err then
    return err.message or tostring(err)
  end
  return fallback
end

local function response_value(resp, key)
  return resp and resp[key]
end

--- Build a child C expression from the name supplied by a DAP variables reply.
local function child_expression(parent, variable)
  local name = vim.trim(tostring(variable.name or ''))
  local evaluate_name = vim.trim(tostring(variable.evaluateName or ''))
  if evaluate_name ~= '' then
    -- Older adapter versions emitted `array.[0]`; normalize that spelling
    -- before asking GDB to evaluate the child again. Also parenthesize fields
    -- below a dereference (`(*ptr).field`, not `*ptr.field`).
    local normalized = evaluate_name:gsub('%.%[', '['):gsub('%.(%d+)', '[%1]')
    if parent:sub(1, 1) == '*' and normalized:sub(1, #parent) == parent then
      normalized = '(' .. parent .. ')' .. normalized:sub(#parent + 1)
    end
    return normalized
  end
  if name:sub(1, 1) == '[' or name:sub(1, 1) == '.' then
    return parent .. name
  end
  if name:sub(1, 1) == '*' then
    return name
  end
  local base = parent
  if base:sub(1, 1) == '*' and base:sub(-1) ~= ')' then
    base = '(' .. base .. ')'
  end
  return base .. '.' .. name
end

local function configured_limits()
  local lw = core.config.live_watch
  local config_lw = config_util.get(watch and watch.session_config, 'liveWatch')
  local depth = tonumber(
    config_util.get(config_lw, 'maxDepth') or config_util.get(config_lw, 'max_depth') or lw.max_depth
  ) or 4
  local children = tonumber(
    config_util.get(config_lw, 'maxChildren') or config_util.get(config_lw, 'max_children') or lw.max_children
  ) or 32
  return math.max(1, math.min(8, math.floor(depth))), math.max(1, math.min(256, math.floor(children)))
end

--- Resolve one node's value, address, size and type while stopped. The value
--- itself is deliberately not retained for running samples: OpenOCD supplies
--- those from memory after this metadata pass.
local function hydrate_node(session, frame_id, node, max_depth, max_children, done, valid)
  if not valid() then
    done('hydration cancelled')
    return
  end
  session:evaluate({
    expression = node.expression,
    context = 'watch',
    frameId = frame_id,
  }, function(err, resp)
    if not valid() then
      done('hydration cancelled')
      return
    end
    if err or not resp then
      done(dap_error(err, 'cannot evaluate `' .. node.expression .. '`'))
      return
    end
    node.type = response_value(resp, 'type') or node.type
    -- Re-evaluation is authoritative. A positive variablesReference from a
    -- parent variables reply must not make a primitive child look composite.
    node.variables_reference = tonumber(response_value(resp, 'variablesReference')) or 0
    session:evaluate({
      expression = '&(' .. node.expression .. ')',
      context = 'watch',
      frameId = frame_id,
    }, function(aerr, aresp)
      if not valid() then
        done('hydration cancelled')
        return
      end
      local address = not aerr and aresp and (first_hex(aresp.memoryReference) or first_hex(aresp.result))
      if not address then
        done(dap_error(aerr, 'cannot resolve address of `' .. node.expression .. '`'))
        return
      end
      node.address = address
      session:evaluate({
        expression = 'sizeof(' .. node.expression .. ')',
        context = 'watch',
        frameId = frame_id,
      }, function(serr, sresp)
        if not valid() then
          done('hydration cancelled')
          return
        end
        local size = not serr and sresp and first_hex(sresp.result)
        if not size or size < 1 then
          done(dap_error(serr, 'cannot resolve size of `' .. node.expression .. '`'))
          return
        end
        node.size = size
        node.command = nil
        node.children = {}
        local pointer = tostring(node.type or ''):match('%*') ~= nil
        -- A pointer has a scalar value in its own storage and may also expose
        -- a dereferenced child through GDB's varobj. Poll the pointer itself
        -- over telnet, then hydrate the optional pointee below it.
        if node.variables_reference <= 0 or pointer then
          local command, count = md_for_size(size)
          node.command = string.format('%s 0x%08x %d', command, address, count)
        end
        if node.variables_reference <= 0 then
          done(nil)
          return
        end
        if node.depth >= max_depth then
          node.truncated = true
          done(nil)
          return
        end
        session:request('variables', {
          variablesReference = node.variables_reference,
        }, function(verr, vresp)
          if not valid() then
            done('hydration cancelled')
            return
          end
          if verr or not vresp then
            done(dap_error(verr, 'cannot fetch children of `' .. node.expression .. '`'))
            return
          end
          local variables = vresp.variables or (vim.islist(vresp) and vresp) or {}
          local count = math.min(#variables, max_children)
          node.truncated = #variables > count
          local index = 0
          local function next_child(child_err)
            if child_err then
              done(child_err)
              return
            end
            index = index + 1
            if index > count then
              done(nil)
              return
            end
            local variable = variables[index]
            local child = {
              name = tostring(variable.name or ('[' .. (index - 1) .. ']')),
              expression = child_expression(node.expression, variable),
              depth = node.depth + 1,
              type = variable.type,
              value = nil,
              error = nil,
              variables_reference = tonumber(variable.variablesReference) or 0,
              children = {},
            }
            node.children[#node.children + 1] = child
            hydrate_node(session, frame_id, child, max_depth, max_children, next_child, valid)
          end
          next_child(nil)
        end)
      end)
    end)
  end)
end

--- Hydrate a complete root expression. This is only called from stopped
--- events/manual refreshes, never from the running telnet sample loop.
local function hydrate_entry(entry, cb)
  local session = stopped_session()
  if not session then
    cb('target must be stopped to resolve `' .. entry.raw .. '`')
    return
  end
  local frame_id = session.current_frame.id
  entry.resolving = true
  entry.hydration_id = (entry.hydration_id or 0) + 1
  local hydration_id = entry.hydration_id
  local generation = watch and watch.generation or 0
  local function valid()
    return entry.hydration_id == hydration_id
      and watch
      and watch.generation == generation
      and stopped_session() == session
  end
  entry.error = nil
  local max_depth, max_children = configured_limits()
  local root = {
    name = entry.raw,
    expression = entry.raw,
    depth = 0,
    value = nil,
    error = nil,
    children = {},
  }
  hydrate_node(session, frame_id, root, max_depth, max_children, function(err)
    if entry.hydration_id ~= hydration_id or not valid() then
      return
    end
    entry.resolving = false
    if err then
      entry.error = err
      return cb(err)
    end
    -- Commit only a complete tree from the current stopped session. Existing
    -- metadata remains available for telnet polling if the target resumes.
    entry.root = root
    entry.address, entry.size, entry.type = root.address, root.size, root.type
    entry.variables_reference = root.variables_reference
    entry.command = root.command
    entry.error = nil
    cb(nil)
  end, valid)
end
---Format an `mdX` response into something compact.
---@param entry cortex.Entry
---@param response string
---@return string
local function format_value(entry, response)
  response = vim.trim(response or '')
  if response == '' then
    return ''
  end
  if entry.kind == 'command' and not entry.raw:match('^md[bhwd]%f[%A]') then
    -- Arbitrary command (reg / targets / ...): keep the first line, the full
    -- text is shown on the following (indented) lines by the renderer.
    return response
  end
  local words = {}
  for _, line in ipairs(vim.split(response, '\n', { plain = true })) do
    local _, rhs = line:match('^%s*(0[xX]%x+):%s*(.+)$')
    if rhs then
      for tok in rhs:gmatch('%x+') do
        words[#words + 1] = tok
      end
    end
  end
  if #words == 0 then
    return response
  end
  if #words == 1 then
    local hex = words[1]
    local num = tonumber(hex, 16) or 0
    local width = #hex * 4
    local out = string.format('0x%s  %d', hex, num)
    if width <= 32 and num >= 2 ^ (width - 1) then
      out = out .. string.format(' (%d)', num - 2 ^ width)
    end
    return out
  end
  local parts = {}
  for i, w in ipairs(words) do
    parts[i] = '0x' .. w
  end
  return table.concat(parts, ' ')
end

--- Decode an OpenOCD mdX response using the metadata captured while stopped.
local function decode_scalar(node, response)
  local words = {}
  for _, line in ipairs(vim.split(response or '', '\n', { plain = true })) do
    local _, rhs = line:match('^%s*(0[xX]%x+):%s*(.+)$')
    if rhs then
      for token in rhs:gmatch('%S+') do
        token = token:gsub('^0[xX]', ''):gsub('[^%x].*$', '')
        if token ~= '' and token:match('^%x+$') then
          words[#words + 1] = token
        end
      end
    end
  end
  if #words == 0 then
    return vim.trim(response or '')
  end
  local size = math.max(1, tonumber(node.size) or 4)
  local type_name = tostring(node.type or '')
  if size <= 4 then
    local number = tonumber(words[1], 16) or 0
    local bits = size * 8
    local modulus = 2 ^ bits
    number = number % modulus
    local bool = type_name:match('[Bb]ool')
    if bool then
      return number ~= 0 and 'true' or 'false'
    end
    local signed = not type_name:match('unsigned')
      and not type_name:match('uint%d')
      and not type_name:match('%*')
      and not type_name:match('^[uU]')
    local shown = number
    if signed and number >= 2 ^ (bits - 1) then
      shown = number - modulus
    end
    return string.format('0x%0' .. (size * 2) .. 'x  %d', number, shown)
  end
  local parts = {}
  for i = 1, math.min(#words, math.ceil(size / 4)) do
    parts[i] = '0x' .. words[i]
  end
  return table.concat(parts, ' ')
end
watch = {
  entries = {}, ---@type cortex.Entry[]
  bufnr = nil, ---@type integer|nil
  winid = nil, ---@type integer|nil
  timer = nil,
  telnet = nil, ---@type cortex.Telnet|nil
  active = false,
  host = nil, ---@type string|nil
  port = nil, ---@type integer|nil
  rate = nil, ---@type number|nil
  status = 'stopped',
  -- DAP execution state is separate from the Telnet connection state. Live
  -- Watch keeps its buffer while stopped, but only samples target memory
  -- while the target is running.
  target_state = nil, ---@type 'running'|'stopped'|nil
  last_connect_attempt = 0,
  render_scheduled = false,
  session_config = nil, ---@type table|nil
  -- Invalidates in-flight DAP metadata hydration when sessions change or
  -- resume. Running samples must never continue an old DAP request chain.
  generation = 0,
}

local pane = view.new(watch, {
  name = 'cortex://live-watch',
  filetype = 'cortex-live-watch',
  title = 'Cortex Live Watch',
  float_width = 80,
  float_height = 16,
  window = {
    position = 'right',
    width = 60,
    height = 12,
    border = 'rounded',
    focus_on_open = false,
    min_width = 20,
  },
})

L.state = watch

---Resolve host/port/rate from a launch configuration (falls back to defaults).
---@param config table|nil
---@return string host, integer port, number rate
local function endpoint_from_config(config)
  local lw = core.config.live_watch
  local host = config_util.get(config, 'telnetHost') or config_util.get(config, 'openocdTelnetHost') or lw.host
  local port = config_util.get(config, 'telnetPort')
    or config_util.get(config, 'openocdTelnetPort')
    or config_util.get(config_util.get(config, 'liveWatch'), 'telnetPort')
    or lw.port
  local rate = config_util.get(config_util.get(config, 'liveWatch'), 'samplesPerSecond') or lw.samples_per_second
  port = tonumber(port) or lw.port
  rate = tonumber(rate) or lw.samples_per_second
  if rate <= 0 then
    rate = lw.samples_per_second
  end
  if rate > 20 then
    rate = 20
  end
  return tostring(host), math.floor(port), rate
end
local function buf_valid()
  return pane:buf_valid()
end

local function set_buf_keymaps(bufnr)
  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set('n', 'q', function()
    L.close()
  end, opts)
  vim.keymap.set('n', 'a', function()
    L.add()
  end, opts)
  vim.keymap.set('n', 'c', function()
    L.clear()
  end, opts)
  vim.keymap.set('n', 'r', function()
    L.refresh()
  end, opts)
  vim.keymap.set('n', 'd', function()
    local line = api.nvim_win_get_cursor(0)[1]
    L.remove_at_line(line)
  end, opts)
  vim.keymap.set('n', '<LeftMouse>', function()
    local winid = pane:window()
    if winid then
      ui.mouse_line(winid)
    end
  end, opts)
end

local function create_buf()
  local bufnr, created = pane:buffer()
  if created then
    set_buf_keymaps(bufnr)
  end
  return bufnr
end

local function open_window()
  create_buf()
  return pane:open(core.config.window)
end

local function close_window()
  pane:close()
end

local function render()
  if not buf_valid() then
    return
  end
  local content_width = ui.content_width(watch.bufnr, 80)
  local rate = watch.rate or core.config.live_watch.samples_per_second
  local ep =
    string.format('%s:%d', watch.host or core.config.live_watch.host, watch.port or core.config.live_watch.port)
  local display_status = watch.target_state and (watch.target_state .. ' / ' .. tostring(watch.status)) or watch.status
  local icon, status_group = ui.status_icon(watch.target_state == 'stopped' and 'stopped' or watch.status, 'live_watch')
  local label_width = math.max(12, math.min(32, math.floor((content_width - 6) * 0.45)))
  local value_width = math.max(8, content_width - label_width - 6)
  local status_line = ui.truncate(string.format('  %s  %s  %s  %.3g Hz', icon, display_status, ep, rate), content_width)
  local lines = {
    'Cortex Live Watch',
    status_line,
    string.format('  %-' .. label_width .. 's  %s', 'Expression', ui.truncate('Value', value_width)),
    '  ' .. string.rep('─', content_width),
  }
  local highlights = {
    { line = 1, group = 'CortexTitle' },
    { line = 2, group = status_group, start = 2, finish = -1 },
    { line = 3, group = 'CortexHeader' },
    { line = 4, group = 'CortexSeparator' },
  }

  if #watch.entries == 0 then
    lines[#lines + 1] = ui.truncate('  (no watch expressions -- :CortexDebugWatchAdd <expr>)', content_width)
    ui.highlight_line(highlights, #lines, 'CortexDim')
  end

  local line_of = {}
  local function add_row(entry, node, indent, root)
    local label = tostring(root and entry.raw or (node.name or node.expression))
    local text
    local value_group
    if (root and entry.error) or (not root and node.error) then
      text = '<unresolved: ' .. tostring(root and entry.error or node.error) .. '>'
      value_group = 'CortexError'
    elseif root and entry.resolving then
      text = '<resolving...>'
      value_group = 'CortexWarn'
    elseif node.value ~= nil then
      text = node.value
      value_group = 'CortexValue'
    elseif node.children and #node.children > 0 then
      text = '{' .. tostring(node.type or 'object') .. '}'
      if node.truncated then
        text = text .. ' ...'
      end
      value_group = 'CortexDim'
    elseif node.type then
      text = '<' .. node.type .. '>'
      value_group = 'CortexDim'
    else
      text = root and '<pending>' or '<unresolved>'
      value_group = 'CortexDim'
    end
    local value_lines = vim.split(tostring(text), '\n', { plain = true })
    local prefix = string.rep('  ', indent)
    local row_label_width = math.max(6, label_width - #prefix)
    local shown_label = ui.truncate(label, row_label_width)
    local row_value_width = math.max(4, content_width - #prefix - row_label_width - 4)
    local shown_value = ui.truncate(value_lines[1] or '', row_value_width)
    local first = prefix .. string.format('%-' .. row_label_width .. 's  %s', shown_label, shown_value)
    lines[#lines + 1] = first
    local row = #lines
    line_of[row] = entry
    highlights[#highlights + 1] = {
      line = row,
      group = root and 'CortexName' or 'CortexDim',
      start = #prefix,
      finish = #prefix + #shown_label,
    }
    local value_at = first:find(shown_value, #prefix + row_label_width + 3, true)
    if value_at and shown_value ~= '' then
      highlights[#highlights + 1] =
        { line = row, group = value_group, start = value_at - 1, finish = value_at - 1 + #shown_value }
    end
    for i = 2, #value_lines do
      local continuation = string.rep(' ', #prefix + row_label_width + 2)
        .. ui.truncate(value_lines[i], row_value_width)
      lines[#lines + 1] = continuation
      line_of[#lines] = entry
      ui.highlight_line(highlights, #lines, value_group)
    end
    for _, child in ipairs(node.children or {}) do
      add_row(entry, child, indent + 1, false)
    end
  end

  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' and e.root then
      add_row(e, e.root, 0, true)
    else
      local text, value_group
      if e.error then
        text, value_group = '<unresolved: ' .. tostring(e.error) .. '>', 'CortexError'
      elseif e.resolving then
        text, value_group = '<resolving...>', 'CortexWarn'
      elseif e.value == nil then
        text, value_group = '<pending>', 'CortexDim'
      else
        text, value_group = e.value, 'CortexValue'
      end
      local value_lines = vim.split(tostring(text), '\n', { plain = true })
      local label = ui.truncate(e.raw, label_width)
      local shown_value = ui.truncate(value_lines[1] or '', value_width)
      local first = '  ' .. string.format('%-' .. label_width .. 's  %s', label, shown_value)
      lines[#lines + 1] = first
      local row = #lines
      line_of[row] = e
      highlights[#highlights + 1] = { line = row, group = 'CortexName', start = 2, finish = 2 + #label }
      local value_at = first:find(shown_value, label_width + 5, true)
      if value_at and shown_value ~= '' then
        highlights[#highlights + 1] =
          { line = row, group = value_group, start = value_at - 1, finish = value_at - 1 + #shown_value }
      end
      for i = 2, #value_lines do
        lines[#lines + 1] = '  ' .. string.rep(' ', label_width + 2) .. ui.truncate(value_lines[i], value_width)
        line_of[#lines] = e
        ui.highlight_line(highlights, #lines, value_group)
      end
    end
  end
  watch.line_map = line_of
  ui.render(watch.bufnr, lines, highlights)
end

local function schedule_render()
  if watch.render_scheduled then
    return
  end
  watch.render_scheduled = true
  vim.schedule(function()
    watch.render_scheduled = false
    -- A late hydration/connect callback may arrive after the user closed the
    -- standalone window. Do not repaint a hidden buffer in that case.
    if watch.active or pane:win_valid() then
      render()
    end
  end)
end
local function poll_once()
  -- Live Watch is a running-state view. While stopped, DAP owns the target
  -- and the other Cortex views are refreshed instead; keeping the old values
  -- here avoids racing a pause with an in-flight Telnet read.
  if watch.target_state == 'stopped' then
    return
  end
  local tel = watch.telnet
  if not tel or not tel:is_connected() then
    return
  end
  local generation = watch.generation
  local function current()
    return watch.active and watch.telnet == tel and watch.generation == generation
  end
  -- Do not pile up requests if the target/telnet link is slower than the
  -- requested sample rate. This loop intentionally never calls DAP: all
  -- symbol metadata must have been hydrated by a stopped event first.
  if tel:queue_size() > math.max(2, #watch.entries) then
    return
  end

  local function poll_node(entry, node)
    if node.command then
      tel:send(node.command, function(err, response)
        if not current() then
          return
        end
        if err then
          node.error = tostring(err)
          if entry.root == node then
            entry.error = node.error
          end
        else
          node.error = nil
          node.value = decode_scalar(node, response or '')
          if entry.root == node then
            entry.value = node.value
            entry.error = nil
          end
        end
        schedule_render()
      end)
    end
    for _, child in ipairs(node.children or {}) do
      poll_node(entry, child)
    end
  end

  for _, entry in ipairs(watch.entries) do
    if entry.kind == 'symbol' and entry.root and not entry.resolving then
      poll_node(entry, entry.root)
    elseif entry.command then
      local e = entry
      tel:send(e.command, function(err, response)
        if not current() then
          return
        end
        if err then
          e.error = tostring(err)
        else
          e.error = nil
          e.value = format_value(e, response or '')
        end
        schedule_render()
      end)
    end
  end
end

local function stop_timer()
  if watch.timer then
    pcall(function()
      watch.timer:stop()
      watch.timer:close()
    end)
    watch.timer = nil
  end
end

local function start_timer()
  stop_timer()
  local rate = watch.rate or core.config.live_watch.samples_per_second
  local interval = math.max(20, math.floor(1000 / rate))
  local t = uv.new_timer()
  watch.timer = t
  if not t then
    return
  end
  t:start(interval, interval, function()
    vim.schedule(function()
      if not watch.active then
        return
      end
      local tel = watch.telnet
      if not tel or (not tel:is_connected() and not tel.connecting) then
        -- (re)connect with a small backoff
        local now = uv.now()
        if now - watch.last_connect_attempt > 2000 then
          watch.last_connect_attempt = now
          L._connect()
        end
        return
      end
      poll_once()
    end)
  end)
end

function L._connect()
  if watch.telnet then
    watch.telnet:close()
    watch.telnet = nil
  end
  local host = watch.host or core.config.live_watch.host
  local port = watch.port or core.config.live_watch.port
  local tel = Telnet.new(host, port, core.config.live_watch.timeout_ms)
  watch.telnet = tel
  watch.status = 'connecting'
  schedule_render()
  tel:connect(function(err)
    -- A reconnect/stop can replace this socket before its async callback
    -- arrives. Obsolete callbacks must not revive the old watch state.
    if watch.telnet ~= tel or not watch.active then
      return
    end
    if err then
      watch.status = 'error: ' .. tostring(err)
      for _, e in ipairs(watch.entries) do
        e.error = 'no telnet connection'
      end
    else
      watch.status = 'connected'
      for _, e in ipairs(watch.entries) do
        if e.error == 'no telnet connection' then
          e.error = nil
        end
      end
    end
    schedule_render()
  end)
end
---Start live watch (idempotent).
---@param opts table|nil { host, port, rate, config }
function L.start(opts)
  opts = opts or {}
  local config = opts.config or watch.session_config
  local host, port, rate = endpoint_from_config(config)
  watch.host = opts.host or host
  watch.port = opts.port or port
  watch.rate = opts.rate or rate

  if #watch.entries == 0 then
    for _, expr in ipairs(core.config.live_watch.expressions or {}) do
      table.insert(watch.entries, make_entry(expr))
    end
  end

  watch.active = true
  create_buf()
  open_window()
  watch.last_connect_attempt = uv.now()
  L._connect()
  start_timer()
  schedule_render()
end

---Stop live watch: kill timer + socket, optionally keep the window open.
---@param opts table|nil { keep_window: boolean }
function L.stop(opts)
  opts = opts or {}
  watch.active = false
  -- Cancel both pending metadata chains and late Telnet callbacks before
  -- tearing down the socket/window.
  invalidate_hydration()
  stop_timer()
  if watch.telnet then
    watch.telnet:close()
    watch.telnet = nil
  end
  watch.status = 'stopped'
  if not opts.keep_window then
    close_window()
  else
    schedule_render()
  end
end

---Close the watch window (keeps the entries around).
function L.close()
  L.stop()
end

---Open the watch window / start polling.
function L.open()
  L.start()
end

---Toggle the live watch window. `:CortexDebugWatch`
function L.toggle()
  if watch.active or pane:win_valid() then
    L.stop()
  else
    L.start()
  end
end

---Add a watch expression. `:CortexDebugWatchAdd`
---@param expr string|nil when nil the user is prompted
function L.add(expr)
  if expr == nil or vim.trim(expr) == '' then
    local default = vim.fn.expand('<cword>')
    vim.ui.input({ prompt = 'Cortex live watch: ', default = default }, function(input)
      if input and vim.trim(input) ~= '' then
        L.add(input)
      end
    end)
    return
  end
  local entry = make_entry(expr)
  table.insert(watch.entries, entry)
  if not watch.active then
    L.start()
  else
    create_buf()
    open_window()
  end
  if entry.kind == 'symbol' then
    if stopped_session() then
      hydrate_entry(entry, function(err)
        entry.error = err
        schedule_render()
      end)
    else
      entry.error = 'target must be stopped to resolve `' .. entry.raw .. '`'
    end
  end
  schedule_render()
end

---Remove all watch expressions. `:CortexDebugWatchClear`
function L.clear()
  watch.entries = {}
  schedule_render()
end

---Remove the entry rendered at `line` (1 based buffer line).
---@param line integer
function L.remove_at_line(line)
  local entry = watch.line_map and watch.line_map[line]
  if not entry then
    return
  end
  for i, e in ipairs(watch.entries) do
    if e == entry then
      table.remove(watch.entries, i)
      break
    end
  end
  schedule_render()
end

---Force resolve + poll right now.
function L.refresh()
  local stopped = stopped_session() ~= nil
  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' then
      if stopped then
        hydrate_entry(e, function(err)
          e.error = err
          schedule_render()
        end)
      elseif not e.root then
        -- A new symbol has no address plan yet. Existing hydrated symbols
        -- must keep their telnet commands when refresh is pressed while the
        -- target is running.
        e.error = 'target must be stopped to refresh metadata'
      end
    end
  end
  -- Raw commands and already-hydrated symbols can still be sampled while
  -- running; metadata requests above are strictly stopped-only.
  poll_once()
  schedule_render()
end

---Send a raw command to the OpenOCD telnet server. `:CortexDebugTelnet`
---@param cmd string|nil when nil the user is prompted
---@param cb fun(err: string|nil, response: string|nil)|nil
function L.telnet(cmd, cb)
  if cmd == nil or vim.trim(cmd) == '' then
    vim.ui.input({ prompt = 'OpenOCD> ' }, function(input)
      if input and vim.trim(input) ~= '' then
        L.telnet(input, cb)
      end
    end)
    return
  end

  local function run(tel)
    tel:send(cmd, function(err, response)
      if cb then
        cb(err, response)
        return
      end
      if err then
        notify('telnet error: ' .. tostring(err), vim.log.levels.ERROR)
      else
        local text = vim.trim(response or '')
        notify(text ~= '' and text or '(no output)')
      end
    end)
  end

  if watch.telnet and watch.telnet:is_connected() then
    run(watch.telnet)
    return
  end

  local host, port = endpoint_from_config(watch.session_config)
  host = watch.host or host
  port = watch.port or port
  local tel = Telnet.new(host, port, core.config.live_watch.timeout_ms)
  tel:connect(function(err)
    if err then
      if cb then
        cb(err, nil)
      else
        notify(string.format('cannot connect to %s:%d (%s)', host, port, tostring(err)), vim.log.levels.ERROR)
      end
      tel:close()
      return
    end
    tel:send(cmd, function(serr, response)
      if cb then
        cb(serr, response)
      elseif serr then
        notify('telnet error: ' .. tostring(serr), vim.log.levels.ERROR)
      else
        local text = vim.trim(response or '')
        notify(text ~= '' and text or '(no output)')
      end
      tel:close()
    end)
  end)
end

---@return table status snapshot (useful for statuslines / debugging)
function L.status()
  return {
    active = watch.active,
    status = watch.status,
    host = watch.host,
    port = watch.port,
    rate = watch.rate,
    entries = #watch.entries,
    target_state = watch.target_state,
  }
end

function L.configure(config)
  watch.session_config = config
  local host, port, rate = endpoint_from_config(config)
  watch.host, watch.port, watch.rate = host, port, rate
  return host, port, rate
end

function L.on_session_start(config)
  invalidate_hydration()
  for _, entry in ipairs(watch.entries) do
    entry.value, entry.error = nil, nil
    if entry.kind == 'symbol' then
      entry.command, entry.address, entry.size, entry.root = nil, nil, nil, nil
      entry.variables_reference = nil
      entry.resolving = false
    end
  end
  L.configure(config)
  watch.target_state = 'running'
  local enabled = config_util.get(config_util.get(config, 'liveWatch'), 'enabled')
  if core.config.live_watch.auto_open and enabled then
    vim.defer_fn(function()
      if not watch.active and watch.session_config == config then
        L.start({ config = config })
      end
    end, 500)
  elseif watch.active then
    watch.last_connect_attempt = 0
    L._connect()
    start_timer()
  end
end

function L.on_session_continued()
  -- DAP metadata is stopped-state-only, while Telnet sampling is
  -- running-state-only. Invalidate both callback chains at the transition.
  invalidate_hydration()
  watch.target_state = 'running'
  schedule_render()
end

function L.on_session_stopped()
  -- Invalidate an in-flight Telnet sample before hydrating through DAP. This
  -- prevents a pause race from applying running data to the stopped view.
  invalidate_hydration()
  watch.target_state = 'stopped'
  schedule_render()
  for _, entry in ipairs(watch.entries) do
    if entry.kind == 'symbol' and not entry.resolving then
      hydrate_entry(entry, function(err)
        entry.error = err
        schedule_render()
      end)
    end
  end
end

function L.on_session_end()
  invalidate_hydration()
  watch.target_state = nil
  watch.session_config = nil
  for _, entry in ipairs(watch.entries) do
    if entry.kind == 'symbol' then
      entry.command, entry.address, entry.size, entry.root = nil, nil, nil, nil
      entry.variables_reference = nil
      entry.resolving = false
    end
    entry.value, entry.error = nil, nil
  end
  L.stop()
end

function L.on_window_closed(closed)
  if tonumber(closed) ~= watch.winid then
    return false
  end
  watch.winid = nil
  if watch.active then
    L.stop()
  end
  return true
end

function L.shutdown()
  watch.active = false
  watch.target_state = nil
  invalidate_hydration()
  stop_timer()
  if watch.telnet then
    watch.telnet:close()
    watch.telnet = nil
  end
end

function L.setup(owner)
  core = assert(owner, 'cortex.live_watch.setup requires core')
  return L
end

return L
