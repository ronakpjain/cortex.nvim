--- cortex.nvim
---
--- Neovim glue for the pure Lua `cortex-debug` DAP adapter shipped in this
--- repository (`lua/cortex/adapter.lua`, launched through
--- `lua/cortex/adapter_main.lua` by a headless Neovim) plus a native
--- "Live Watch" implementation that talks to the OpenOCD telnet server over
--- TCP (libuv, no dependencies).
---
--- Usage:
---   require('cortex').setup({})
---
--- Public API:
---   require('cortex').setup(opts)
---   require('cortex').toggle()      -- :CortexDebugWatch
---   require('cortex').add(expr)     -- :CortexDebugWatchAdd
---   require('cortex').clear()       -- :CortexDebugWatchClear
---   require('cortex').telnet(cmd)   -- :CortexDebugTelnet
---
--- Only Neovim/libuv APIs are used; nvim-dap is required lazily and only for
--- the adapter registration and symbol resolution.

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

----------------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------------

---@class cortex.Config
local defaults = {
  -- Neovim executable used to host the bundled Lua DAP adapter.
  -- Defaults to the current Neovim binary (`vim.v.progpath`).
  nvim = nil, ---@type string?
  -- Absolute path to `adapter_main.lua`. Defaults to the sibling
  -- `lua/cortex/adapter_main.lua` of this file.
  adapter_path = nil, ---@type string?
  -- Extra arguments appended after the adapter script.
  adapter_args = {}, ---@type string[]
  -- Adapter type name registered in `dap.adapters`.
  adapter_name = 'cortex-debug',
  -- Filetypes the launch.json `cortex-debug` configurations apply to
  -- (only used by nvim-dap's legacy `load_launchjs`).
  filetypes = { 'c', 'cpp', 'rust', 'asm' },

  live_watch = {
    -- Open the watch window automatically when a session that has
    -- `liveWatch.enabled == true` in its configuration starts.
    auto_open = true,
    -- Fallback sample rate when the launch configuration does not set
    -- `liveWatch.samplesPerSecond`.
    samples_per_second = 4,
    -- Fallback OpenOCD telnet endpoint. Overridden per-session by the launch
    -- configuration keys `telnetPort` / `openocdTelnetPort` / `telnetHost`.
    host = '127.0.0.1',
    port = 4444,
    -- Per request timeout (ms) for the telnet round trip.
    timeout_ms = 1000,
    -- Watch expressions that are always present.
    expressions = {}, ---@type string[]
  },

  window = {
    -- 'right' | 'left' | 'bottom' | 'top' | 'float'
    position = 'right',
    width = 60,
    height = 12,
    -- Only used for `position = 'float'`.
    border = 'rounded',
    -- Set to false to keep the cursor in the current window when opening.
    focus_on_open = false,
  },
}

---@type cortex.Config
M.config = vim.deepcopy(defaults)

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify('[cortex.nvim] ' .. msg, level or vim.log.levels.INFO)
end

--- Root directory of this plugin (the parent of `lua/`).
---@return string
local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(src, ':p:h:h:h'))
end

--- Default location of the bundled Lua adapter entry script.
---@return string
function M.adapter_script()
  if M.config.adapter_path and M.config.adapter_path ~= '' then
    return vim.fs.normalize(vim.fn.expand(M.config.adapter_path))
  end
  return plugin_root() .. '/lua/cortex/adapter_main.lua'
end

--- Neovim executable used to host the adapter.
---@return string
function M.adapter_nvim()
  local exe = M.config.nvim
  if exe and exe ~= '' then
    return vim.fs.normalize(vim.fn.expand(exe))
  end
  local progpath = vim.v.progpath
  if progpath and progpath ~= '' then
    return progpath
  end
  return vim.fn.exepath('nvim') ~= '' and vim.fn.exepath('nvim') or 'nvim'
end

---@return table|nil dap
local function get_dap()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil
  end
  return dap
end

local function tbl_get(tbl, key)
  if type(tbl) ~= 'table' then
    return nil
  end
  return tbl[key]
end

----------------------------------------------------------------------------
-- Telnet (OpenOCD monitor) client -- raw TCP via libuv
----------------------------------------------------------------------------

--- OpenOCD's telnet server is a line oriented protocol which echoes the input
--- and terminates every answer with the `> ` prompt. It may (depending on the
--- version) send a few IAC option bytes on connect, which we strip.
---@class cortex.Telnet
local Telnet = {}
Telnet.__index = Telnet

local IAC = 255

---Strip telnet IAC command sequences from a raw chunk.
---@param s string
---@return string
local function strip_iac(s)
  if not s:find(string.char(IAC), 1, true) then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == IAC then
      local cmd = s:byte(i + 1)
      if cmd == nil then
        break
      elseif cmd == IAC then -- escaped 0xFF
        out[#out + 1] = string.char(IAC)
        i = i + 2
      elseif cmd >= 251 and cmd <= 254 then -- WILL/WONT/DO/DONT <opt>
        i = i + 3
      elseif cmd == 250 then -- SB ... IAC SE
        local j = s:find(string.char(IAC, 240), i + 2, true)
        i = j and (j + 2) or (n + 1)
      else
        i = i + 2
      end
    else
      out[#out + 1] = string.char(b)
      i = i + 1
    end
  end
  return table.concat(out)
end

---@param host string
---@param port integer
---@param timeout_ms integer
---@return cortex.Telnet
function Telnet.new(host, port, timeout_ms)
  return setmetatable({
    host = host,
    port = port,
    timeout_ms = timeout_ms or 1000,
    queue = {},
    pending = nil,
    rx = '',
    ready = false,
    connected = false,
    connecting = false,
    closed = false,
    last_error = nil,
  }, Telnet)
end

function Telnet:is_connected()
  return self.connected and not self.closed
end

function Telnet:_fail(err)
  self.last_error = err
  local queue = self.queue
  self.queue = {}
  local pending = self.pending
  self.pending = nil
  if pending and pending.cb then
    pending.cb(err, nil)
  end
  for _, req in ipairs(queue) do
    if req.cb then
      req.cb(err, nil)
    end
  end
end

---@param cb fun(err: string|nil)
function Telnet:connect(cb)
  if self.connected or self.connecting then
    cb(nil)
    return
  end
  self.connecting = true
  self.closed = false
  self.last_error = nil

  local function do_connect(ip)
    local tcp = uv.new_tcp()
    if not tcp then
      self.connecting = false
      cb('could not create tcp handle')
      return
    end
    self.handle = tcp
    uv.tcp_connect(tcp, ip, self.port, function(err)
      if err then
        self.connecting = false
        self.connected = false
        pcall(function()
          tcp:close()
        end)
        self.handle = nil
        self.last_error = err
        vim.schedule(function()
          cb(err)
        end)
        return
      end
      self.connecting = false
      self.connected = true
      self.ready = false
      self.rx = ''
      tcp:read_start(function(rerr, chunk)
        if rerr then
          vim.schedule(function()
            self:_fail(rerr)
            self:close()
          end)
          return
        end
        if not chunk then -- EOF
          vim.schedule(function()
            self:_fail('connection closed by OpenOCD')
            self:close()
          end)
          return
        end
        vim.schedule(function()
          self:_on_data(chunk)
        end)
      end)
      -- If the banner never shows up, unblock the queue anyway.
      local t = uv.new_timer()
      self.banner_timer = t
      if t then
        t:start(400, 0, function()
          t:stop()
          t:close()
          self.banner_timer = nil
          vim.schedule(function()
            if not self.ready then
              self.ready = true
              self:_pump()
            end
          end)
        end)
      end
      vim.schedule(function()
        cb(nil)
      end)
    end)
  end

  if self.host:match('^%d+%.%d+%.%d+%.%d+$') then
    do_connect(self.host)
  else
    uv.getaddrinfo(self.host, nil, { family = 'inet', socktype = 'stream' }, function(err, res)
      if err or not res or not res[1] then
        self.connecting = false
        vim.schedule(function()
          cb(err or ('cannot resolve host ' .. self.host))
        end)
        return
      end
      local addr = res[1].addr
      vim.schedule(function()
        do_connect(addr)
      end)
    end)
  end
end

function Telnet:close()
  self.closed = true
  self.connected = false
  self.connecting = false
  self.ready = false
  self:_cancel_timeout()
  if self.banner_timer then
    pcall(function()
      self.banner_timer:stop()
      self.banner_timer:close()
    end)
    self.banner_timer = nil
  end
  local h = self.handle
  self.handle = nil
  if h then
    pcall(function()
      h:read_stop()
    end)
    pcall(function()
      if not h:is_closing() then
        h:close()
      end
    end)
  end
  self.queue = {}
  self.pending = nil
  self.rx = ''
end

function Telnet:_cancel_timeout()
  if self.timeout_timer then
    pcall(function()
      self.timeout_timer:stop()
      self.timeout_timer:close()
    end)
    self.timeout_timer = nil
  end
end

--- Strip echoed command / prompt noise from a raw response body.
---@param body string
---@param cmd string
---@return string
local function clean_response(body, cmd)
  body = body:gsub('\r', '')
  body = body:gsub('^[%s]*> ?', '')
  local lines = vim.split(body, '\n', { plain = true })
  -- OpenOCD echoes back what we typed; drop the first line if it is the echo.
  if lines[1] and vim.trim(lines[1]) == vim.trim(cmd) then
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == '' do
    table.remove(lines)
  end
  while #lines > 0 and vim.trim(lines[1]) == '' do
    table.remove(lines, 1)
  end
  return table.concat(lines, '\n')
end

function Telnet:_on_data(chunk)
  chunk = strip_iac(chunk)
  if not self.pending then
    -- Connection banner (or unsolicited output): swallow it, but use it as the
    -- "server is ready" signal.
    self.rx = ''
    if chunk:find('> %s*$') or chunk:find('>%s*$') then
      self.ready = true
      self:_pump()
    end
    return
  end
  self.rx = self.rx .. chunk
  local body = self.rx:gsub('\r', '')
  -- The prompt marks the end of the answer.
  local stripped = body:match('^(.-)\n?> ?$')
  if stripped == nil and body:sub(-2) == '> ' then
    stripped = body:sub(1, -3)
  end
  if stripped ~= nil then
    local req = self.pending
    self.pending = nil
    self.rx = ''
    self.ready = true
    self:_cancel_timeout()
    if req.cb then
      req.cb(nil, clean_response(stripped, req.cmd))
    end
    self:_pump()
  end
end

function Telnet:_pump()
  if self.closed or not self.connected or not self.ready then
    return
  end
  if self.pending or #self.queue == 0 then
    return
  end
  local req = table.remove(self.queue, 1)
  self.pending = req
  self.rx = ''
  local h = self.handle
  if not h then
    self.pending = nil
    if req.cb then
      req.cb('not connected', nil)
    end
    return
  end
  h:write(req.cmd .. '\n', function(werr)
    if werr then
      vim.schedule(function()
        if self.pending == req then
          self.pending = nil
          self:_cancel_timeout()
          if req.cb then
            req.cb(werr, nil)
          end
          self:_pump()
        end
      end)
    end
  end)
  local t = uv.new_timer()
  self.timeout_timer = t
  if t then
    t:start(self.timeout_ms, 0, function()
      t:stop()
      vim.schedule(function()
        if self.pending == req then
          self.pending = nil
          self.rx = ''
          self:_cancel_timeout()
          if req.cb then
            req.cb('timeout', nil)
          end
          self:_pump()
        end
      end)
    end)
  end
end

---@param cmd string
---@param cb fun(err: string|nil, response: string|nil)
function Telnet:send(cmd, cb)
  if self.closed then
    cb('not connected', nil)
    return
  end
  table.insert(self.queue, { cmd = cmd, cb = cb })
  self:_pump()
end

function Telnet:queue_size()
  return #self.queue + (self.pending and 1 or 0)
end

M._Telnet = Telnet -- exported for tests/debugging

----------------------------------------------------------------------------
-- Watch entries
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Symbol resolution through the active nvim-dap session
----------------------------------------------------------------------------

---@return table|nil session
local function active_session()
  local dap = get_dap()
  if not dap then
    return nil
  end
  local session = dap.session()
  if not session or not session.initialized then
    return nil
  end
  return session
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

--- Resolve `&(expr)` / `sizeof(expr)` through the (stopped) DAP session.
---@param entry cortex.Entry
---@param cb fun(err: string|nil)
local function resolve_entry(entry, cb)
  local session = active_session()
  if not session then
    cb('no active debug session')
    return
  end
  if not session.stopped_thread_id or not session.current_frame then
    cb('target must be stopped to resolve `' .. entry.raw .. '`')
    return
  end
  local frame_id = session.current_frame.id
  entry.resolving = true

  local function finish(err)
    entry.resolving = false
    cb(err)
  end

  session:evaluate({
    expression = '&(' .. entry.raw .. ')',
    context = 'watch',
    frameId = frame_id,
  }, function(err, resp)
    if err or not resp then
      finish((err and (err.message or tostring(err))) or 'cannot take address of ' .. entry.raw)
      return
    end
    local addr = first_hex(resp.memoryReference) or first_hex(resp.result)
    if not addr then
      finish('cannot parse address from `' .. tostring(resp.result) .. '`')
      return
    end
    entry.address = addr
    session:evaluate({
      expression = 'sizeof(' .. entry.raw .. ')',
      context = 'watch',
      frameId = frame_id,
    }, function(serr, sresp)
      local size = 4
      if not serr and sresp then
        size = first_hex(sresp.result) or 4
      end
      if size < 1 then
        size = 4
      end
      entry.size = size
      local cmd, count = md_for_size(size)
      entry.command = string.format('%s 0x%08x %d', cmd, addr, count)
      finish(nil)
    end)
  end)
end

----------------------------------------------------------------------------
-- Value formatting
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Live watch state
----------------------------------------------------------------------------

local watch = {
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
  last_connect_attempt = 0,
  render_scheduled = false,
  session_config = nil, ---@type table|nil
}

M._watch = watch -- exposed for debugging

---Resolve host/port/rate from a launch configuration (falls back to defaults).
---@param config table|nil
---@return string host, integer port, number rate
local function endpoint_from_config(config)
  local lw = M.config.live_watch
  local host = tbl_get(config, 'telnetHost') or tbl_get(config, 'openocdTelnetHost') or lw.host
  local port = tbl_get(config, 'telnetPort')
    or tbl_get(config, 'openocdTelnetPort')
    or tbl_get(tbl_get(config, 'liveWatch'), 'telnetPort')
    or lw.port
  local rate = tbl_get(tbl_get(config, 'liveWatch'), 'samplesPerSecond') or lw.samples_per_second
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

----------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------

local function buf_valid()
  return watch.bufnr and api.nvim_buf_is_valid(watch.bufnr)
end

local function win_valid()
  return watch.winid and api.nvim_win_is_valid(watch.winid)
end

local function set_buf_keymaps(bufnr)
  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set('n', 'q', function()
    M.close()
  end, opts)
  vim.keymap.set('n', 'a', function()
    M.add()
  end, opts)
  vim.keymap.set('n', 'c', function()
    M.clear()
  end, opts)
  vim.keymap.set('n', 'r', function()
    M.refresh()
  end, opts)
  vim.keymap.set('n', 'd', function()
    local line = api.nvim_win_get_cursor(0)[1]
    M.remove_at_line(line)
  end, opts)
end

local function create_buf()
  if buf_valid() then
    return watch.bufnr
  end
  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'cortex-live-watch'
  pcall(api.nvim_buf_set_name, bufnr, 'cortex://live-watch')
  set_buf_keymaps(bufnr)
  watch.bufnr = bufnr
  return bufnr
end

local function open_window()
  if win_valid() then
    return watch.winid
  end
  local bufnr = create_buf()
  local w = M.config.window
  local prev = api.nvim_get_current_win()
  local winid
  if w.position == 'float' then
    local width = math.min(w.width, math.max(20, vim.o.columns - 4))
    local height = math.min(w.height, math.max(5, vim.o.lines - 6))
    winid = api.nvim_open_win(bufnr, false, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal',
      border = w.border,
      title = ' Cortex Live Watch ',
      title_pos = 'center',
    })
  else
    local cmd
    if w.position == 'left' then
      cmd = 'topleft vertical ' .. w.width .. 'split'
    elseif w.position == 'bottom' then
      cmd = 'botright ' .. w.height .. 'split'
    elseif w.position == 'top' then
      cmd = 'topleft ' .. w.height .. 'split'
    else
      cmd = 'botright vertical ' .. w.width .. 'split'
    end
    vim.cmd(cmd)
    winid = api.nvim_get_current_win()
    api.nvim_win_set_buf(winid, bufnr)
  end
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].wrap = false
  vim.wo[winid].signcolumn = 'no'
  pcall(function()
    vim.wo[winid].winfixwidth = true
  end)
  watch.winid = winid
  if not w.focus_on_open and api.nvim_win_is_valid(prev) then
    api.nvim_set_current_win(prev)
  elseif w.focus_on_open then
    api.nvim_set_current_win(winid)
  end
  return winid
end

local function close_window()
  if win_valid() then
    pcall(api.nvim_win_close, watch.winid, true)
  end
  watch.winid = nil
end

---Line index (1 based, in the rendered buffer) of the first entry.
local HEADER_LINES = 2

local function render()
  if not buf_valid() then
    return
  end
  local lines = {}
  local rate = watch.rate or M.config.live_watch.samples_per_second
  local ep = string.format('%s:%d', watch.host or M.config.live_watch.host, watch.port or M.config.live_watch.port)
  lines[1] = string.format('Cortex Live Watch  [%s]  %s  %.3g Hz', watch.status, ep, rate)
  lines[2] = string.rep('─', math.max(#lines[1], 30))

  if #watch.entries == 0 then
    lines[#lines + 1] = '(no watch expressions -- :CortexDebugWatchAdd <expr>)'
  end

  local width = 0
  for _, e in ipairs(watch.entries) do
    width = math.max(width, #e.raw)
  end
  width = math.min(width, 32)

  local line_of = {}
  for _, e in ipairs(watch.entries) do
    local label = e.raw
    if #label > width then
      label = label:sub(1, width)
    end
    local text
    if e.error then
      text = '<' .. e.error .. '>'
    elseif e.resolving then
      text = '<resolving...>'
    elseif e.value == nil then
      text = '<pending>'
    else
      text = e.value
    end
    local value_lines = vim.split(text, '\n', { plain = true })
    lines[#lines + 1] = string.format('%-' .. width .. 's  %s', label, value_lines[1] or '')
    line_of[#lines] = e
    for i = 2, #value_lines do
      lines[#lines + 1] = string.rep(' ', width + 2) .. value_lines[i]
      line_of[#lines] = e
    end
  end
  watch.line_map = line_of

  vim.bo[watch.bufnr].modifiable = true
  api.nvim_buf_set_lines(watch.bufnr, 0, -1, false, lines)
  vim.bo[watch.bufnr].modifiable = false
end

local function schedule_render()
  if watch.render_scheduled then
    return
  end
  watch.render_scheduled = true
  vim.schedule(function()
    watch.render_scheduled = false
    render()
  end)
end

----------------------------------------------------------------------------
-- Polling
----------------------------------------------------------------------------

local function poll_once()
  local tel = watch.telnet
  if not tel or not tel:is_connected() then
    return
  end
  -- Do not pile up requests if the target/telnet link is slower than the
  -- requested sample rate.
  if tel:queue_size() > math.max(2, #watch.entries) then
    return
  end
  for _, entry in ipairs(watch.entries) do
    if entry.kind == 'symbol' and not entry.command and not entry.resolving then
      local e = entry
      resolve_entry(e, function(err)
        e.error = err
        schedule_render()
      end)
    elseif entry.command then
      local e = entry
      tel:send(e.command, function(err, response)
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
  local rate = watch.rate or M.config.live_watch.samples_per_second
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
          M._connect()
        end
        return
      end
      poll_once()
    end)
  end)
end

function M._connect()
  if watch.telnet then
    watch.telnet:close()
    watch.telnet = nil
  end
  local host = watch.host or M.config.live_watch.host
  local port = watch.port or M.config.live_watch.port
  local tel = Telnet.new(host, port, M.config.live_watch.timeout_ms)
  watch.telnet = tel
  watch.status = 'connecting'
  schedule_render()
  tel:connect(function(err)
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

----------------------------------------------------------------------------
-- Public watch API
----------------------------------------------------------------------------

---Start live watch (idempotent).
---@param opts table|nil { host, port, rate, config }
function M.start(opts)
  opts = opts or {}
  local config = opts.config or watch.session_config
  local host, port, rate = endpoint_from_config(config)
  watch.host = opts.host or host
  watch.port = opts.port or port
  watch.rate = opts.rate or rate

  if #watch.entries == 0 then
    for _, expr in ipairs(M.config.live_watch.expressions or {}) do
      table.insert(watch.entries, make_entry(expr))
    end
  end

  watch.active = true
  create_buf()
  open_window()
  watch.last_connect_attempt = uv.now()
  M._connect()
  start_timer()
  schedule_render()
end

---Stop live watch: kill timer + socket, optionally keep the window open.
---@param opts table|nil { keep_window: boolean }
function M.stop(opts)
  opts = opts or {}
  watch.active = false
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
function M.close()
  M.stop()
end

---Open the watch window / start polling.
function M.open()
  M.start()
end

---Toggle the live watch window. `:CortexDebugWatch`
function M.toggle()
  if watch.active or win_valid() then
    M.stop()
  else
    M.start()
  end
end

M.toggle_watch = M.toggle

---Add a watch expression. `:CortexDebugWatchAdd`
---@param expr string|nil when nil the user is prompted
function M.add(expr)
  if expr == nil or vim.trim(expr) == '' then
    local default = vim.fn.expand('<cword>')
    vim.ui.input({ prompt = 'Cortex live watch: ', default = default }, function(input)
      if input and vim.trim(input) ~= '' then
        M.add(input)
      end
    end)
    return
  end
  local entry = make_entry(expr)
  table.insert(watch.entries, entry)
  if not watch.active then
    M.start()
  else
    create_buf()
    open_window()
  end
  if entry.kind == 'symbol' then
    resolve_entry(entry, function(err)
      entry.error = err
      schedule_render()
    end)
  end
  schedule_render()
end

M.watch_add = M.add

---Remove all watch expressions. `:CortexDebugWatchClear`
function M.clear()
  watch.entries = {}
  schedule_render()
end

M.watch_clear = M.clear

---Remove the entry rendered at `line` (1 based buffer line).
---@param line integer
function M.remove_at_line(line)
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
function M.refresh()
  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' then
      e.command = nil
    end
  end
  poll_once()
  schedule_render()
end

---Send a raw command to the OpenOCD telnet server. `:CortexDebugTelnet`
---@param cmd string|nil when nil the user is prompted
---@param cb fun(err: string|nil, response: string|nil)|nil
function M.telnet(cmd, cb)
  if cmd == nil or vim.trim(cmd) == '' then
    vim.ui.input({ prompt = 'OpenOCD> ' }, function(input)
      if input and vim.trim(input) ~= '' then
        M.telnet(input, cb)
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
  local tel = Telnet.new(host, port, M.config.live_watch.timeout_ms)
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
function M.status()
  return {
    active = watch.active,
    status = watch.status,
    host = watch.host,
    port = watch.port,
    rate = watch.rate,
    entries = #watch.entries,
  }
end

----------------------------------------------------------------------------
-- nvim-dap wiring
----------------------------------------------------------------------------

local function on_session_start(config)
  watch.session_config = config
  local host, port, rate = endpoint_from_config(config)
  watch.host, watch.port, watch.rate = host, port, rate
  local lw = tbl_get(config, 'liveWatch')
  local enabled = tbl_get(lw, 'enabled')
  if M.config.live_watch.auto_open and enabled then
    -- Give OpenOCD/the adapter a moment before hammering the telnet port.
    vim.defer_fn(function()
      if not watch.active then
        M.start({ config = config })
      end
    end, 500)
  elseif watch.active then
    -- Re-target an already open watch window at the new session.
    watch.last_connect_attempt = 0
    M._connect()
    start_timer()
  end
end

local function on_session_end()
  watch.session_config = nil
  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' then
      e.command = nil
      e.address = nil
    end
    e.value = nil
  end
  if watch.active then
    M.stop({ keep_window = true })
  end
end

local function register_listeners(dap)
  local key = 'cortex.nvim'
  dap.listeners.after.event_initialized[key] = function(session)
    on_session_start(session and session.config)
  end
  dap.listeners.after.event_terminated[key] = function()
    on_session_end()
  end
  dap.listeners.after.event_exited[key] = function()
    on_session_end()
  end
  dap.listeners.after.disconnect[key] = function()
    on_session_end()
  end
  dap.listeners.after.event_stopped[key] = function()
    -- Symbols may only be resolved while the target is stopped.
    for _, e in ipairs(watch.entries) do
      if e.kind == 'symbol' and not e.command and not e.resolving then
        resolve_entry(e, function(err)
          e.error = err
          schedule_render()
        end)
      end
    end
  end
end

local function register_autocmds()
  local group = api.nvim_create_augroup('CortexNvim', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      M._shutdown()
    end,
  })
end

function M._shutdown()
  watch.active = false
  stop_timer()
  if watch.telnet then
    watch.telnet:close()
    watch.telnet = nil
  end
end

--- Register the `cortex-debug` executable adapter with nvim-dap.
---
--- The adapter is a pure Lua DAP implementation hosted by a second, headless
--- Neovim process: `nvim --headless --clean -u NONE -l adapter_main.lua`.
---@param dap table
local function register_adapter(dap)
  local script = M.adapter_script()
  local args = { '--headless', '--clean', '-u', 'NONE', '-l', script }
  vim.list_extend(args, M.config.adapter_args or {})

  ---@type table
  dap.adapters[M.config.adapter_name] = {
    type = 'executable',
    command = M.adapter_nvim(),
    args = args,
    options = {
      -- Keep the adapter tied to the DAP session so disconnect tears down
      -- its headless Neovim process as well.
      detached = false,
      initialize_timeout_sec = 8,
    },
    -- Keep every key from `.vscode/launch.json` (including `liveWatch`) and
    -- only fill in the pieces the adapter/live watch need.
    enrich_config = function(config, on_config)
      local final = vim.deepcopy(config)
      if final.cwd == nil then
        final.cwd = vim.fn.getcwd()
      end
      if final.request == nil then
        final.request = 'launch'
      end
      if final.servertype == nil and final.serverType ~= nil then
        final.servertype = final.serverType
      end
      -- `liveWatch` is passed through verbatim; we only use it locally.
      watch.session_config = final
      local host, port, rate = endpoint_from_config(final)
      watch.host, watch.port, watch.rate = host, port, rate
      on_config(final)
    end,
  }

  -- Make `.vscode/launch.json` entries with `"type": "cortex-debug"` show up
  -- for C/C++ buffers. Recent nvim-dap reads launch.json automatically
  -- (`dap.providers.configs["dap.launch.json"]`); this mapping is only used by
  -- the legacy `dap.ext.vscode.load_launchjs()` helper.
  local ok, vscode = pcall(require, 'dap.ext.vscode')
  if ok and vscode.type_to_filetypes then
    vscode.type_to_filetypes[M.config.adapter_name] = M.config.filetypes
  end
end

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

--- Create the user commands unless they already exist.
function M._create_commands()
  if vim.fn.exists(':CortexDebugWatch') == 2 then
    return
  end
  local cmd = api.nvim_create_user_command
  cmd('CortexDebugWatch', function()
    M.toggle()
  end, { desc = 'Toggle the Cortex live watch window' })
  cmd('CortexDebugWatchAdd', function(o)
    M.add(o.args ~= '' and o.args or nil)
  end, { nargs = '*', desc = 'Add a Cortex live watch expression' })
  cmd('CortexDebugWatchClear', function()
    M.clear()
  end, { desc = 'Clear all Cortex live watch expressions' })
  cmd('CortexDebugTelnet', function(o)
    M.telnet(o.args ~= '' and o.args or nil)
  end, { nargs = '*', desc = 'Send a command to the OpenOCD telnet server' })
end

----------------------------------------------------------------------------
-- setup
----------------------------------------------------------------------------

---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

  local dap = get_dap()
  if not dap then
    notify('nvim-dap not found; adapter not registered', vim.log.levels.WARN)
  else
    register_adapter(dap)
    register_listeners(dap)
  end

  register_autocmds()
  M._create_commands()
  return M
end

return M
