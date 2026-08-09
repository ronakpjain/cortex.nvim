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
---   require('cortex').rtos_toggle() -- :CortexDebugRTOS
---   require('cortex').callstack_toggle() -- :CortexDebugCallStack
---
--- Only Neovim/libuv APIs are used; nvim-dap is required lazily and only for
--- the adapter registration and symbol resolution.

local api = vim.api
local uv = vim.uv or vim.loop
local ui = require('cortex.ui')

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
  -- Auxiliary Cortex windows use mouse clicks for tree/frame actions.
  mouse = true,

  -- CMSIS-SVD peripheral browser. Values are read only while stopped and
  -- use a Telnet connection independent of live_watch.telnet.
  peripheral = {
    svdFile = nil,
    svdPath = nil,
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    read_all = false, -- otherwise refresh only expanded peripherals
  },

  -- FreeRTOS task browser. It uses stopped DAP/GDB evaluations and never
  -- joins the live-watch polling path.
  rtos = {
    enabled = false,
    auto_open = false,
    auto_refresh_on_stop = false,
    max_tasks = 128,
    max_priorities = nil,
    tcb_type = 'TCB_t',
    list_item_type = 'ListItem_t',
    stack_growth = -1,
    stack_word_bytes = 4,
    symbols = {},
    fields = {},
    window = nil,
  },

  -- Separate current stopped-thread DAP stack window. This is not a
  -- per-FreeRTOS-task unwinder; dapui remains available as usual.
  callstack = {
    auto_open = false,
    auto_refresh_on_stop = false,
    levels = 0,
    window = nil,
  },

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
    -- Bounds for recursive C-expression metadata hydration.
    max_depth = 4,
    max_children = 32,
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

---Strip telnet IAC command sequences from a raw chunk. The returned tail is
---an incomplete negotiation sequence that must be prepended to the next TCP
---chunk; libuv is allowed to split any byte boundary.
---@param s string
---@param pending string|nil
---@return string clean, string tail
local function strip_iac(s, pending)
  s = (pending or '') .. (s or '')
  if not s:find(string.char(IAC), 1, true) then
    return s, ''
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == IAC then
      local cmd = s:byte(i + 1)
      if cmd == nil then
        return table.concat(out), s:sub(i)
      elseif cmd == IAC then -- escaped 0xFF
        out[#out + 1] = string.char(IAC)
        i = i + 2
      elseif cmd >= 251 and cmd <= 254 then -- WILL/WONT/DO/DONT <opt>
        if i + 2 > n then return table.concat(out), s:sub(i) end
        i = i + 3
      elseif cmd == 250 then -- SB ... IAC SE
        local j = s:find(string.char(IAC, 240), i + 2, true)
        if not j then return table.concat(out), s:sub(i) end
        i = j + 2
      else
        if i + 1 > n then return table.concat(out), s:sub(i) end
        i = i + 2
      end
    else
      out[#out + 1] = string.char(b)
      i = i + 1
    end
  end
  return table.concat(out), ''
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
    connect_generation = 0,
    iac_pending = '',
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
  self.connect_generation = self.connect_generation + 1
  local generation = self.connect_generation

  local function do_connect(ip)
    if self.closed or self.connect_generation ~= generation then
      return
    end
    local tcp = uv.new_tcp()
    if not tcp then
      self.connecting = false
      cb('could not create tcp handle')
      return
    end
    self.handle = tcp
    uv.tcp_connect(tcp, ip, self.port, function(err)
      if self.closed or self.connect_generation ~= generation then
        pcall(function()
          if not tcp:is_closing() then
            tcp:close()
          end
        end)
        return
      end
      if err then
        self.connecting = false
        self.connected = false
        pcall(function()
          tcp:close()
        end)
        self.handle = nil
        self.last_error = err
        vim.schedule(function()
          if not self.closed and self.connect_generation == generation then
            cb(err)
          end
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
            if not self.closed and self.connect_generation == generation then
              self:_fail(rerr)
              self:close()
            end
          end)
          return
        end
        if not chunk then -- EOF
          vim.schedule(function()
            if not self.closed and self.connect_generation == generation then
              self:_fail('connection closed by OpenOCD')
              self:close()
            end
          end)
          return
        end
        vim.schedule(function()
          if not self.closed and self.connect_generation == generation then
            self:_on_data(chunk)
          end
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
            if not self.closed and self.connect_generation == generation and not self.ready then
              self.ready = true
              self:_pump()
            end
          end)
        end)
      end
      vim.schedule(function()
        if not self.closed and self.connect_generation == generation then
          cb(nil)
        end
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
          if not self.closed and self.connect_generation == generation then
            cb(err or ('cannot resolve host ' .. self.host))
          end
        end)
        return
      end
      local addr = res[1].addr
      vim.schedule(function()
        if not self.closed and self.connect_generation == generation then
          do_connect(addr)
        end
      end)
    end)
  end
end

function Telnet:close()
  self.closed = true
  self.connect_generation = self.connect_generation + 1
  self.connected = false
  self.connecting = false
  self.ready = false
  self.iac_pending = ''
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
  -- Some OpenOCD builds prefix telnet replies with a NUL after negotiation.
  -- It is protocol noise, not part of the memory/register value.
  body = body:gsub('%z', ''):gsub('\r', '')
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
  chunk, self.iac_pending = strip_iac(chunk, self.iac_pending)
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

-- Explicit seams used by the stopped-only peripheral browser.  Keeping these
-- here makes it impossible for that browser to accidentally use watch.telnet.
function M._peripheral_config(config)
  return config or (M._watch and M._watch.session_config)
end

function M._peripheral_endpoint(config)
  config = M._peripheral_config(config)
  local pcfg = tbl_get(M.config, 'peripheral') or {}
  local host = tbl_get(config, 'telnetHost') or tbl_get(config, 'openocdTelnetHost')
    or tbl_get(config, 'peripheralTelnetHost') or tbl_get(pcfg, 'host') or M.config.live_watch.host
  local port = tbl_get(config, 'svdTelnetPort') or tbl_get(config, 'peripheralTelnetPort')
    or tbl_get(config, 'telnetPort') or tbl_get(config, 'openocdTelnetPort')
    or tbl_get(pcfg, 'port') or M.config.live_watch.port
  return tostring(host), tonumber(port) or 4444
end

function M._new_peripheral_telnet(config)
  config = M._peripheral_config(config)
  local host, port = M._peripheral_endpoint(config)
  local pcfg = tbl_get(M.config, 'peripheral') or {}
  return Telnet.new(host, port, tonumber(pcfg.timeout_ms or pcfg.timeoutMs) or M.config.live_watch.timeout_ms)
end

--- One isolated stopped-only monitor request (does not touch watch.telnet).
function M._peripheral_request(command, callback, config)
  callback = callback or function() end
  if not M._is_stopped() then
    callback('target must be stopped', nil)
    return nil, 'target must be stopped'
  end
  local tel = M._new_peripheral_telnet(config)
  tel:connect(function(err)
    if err then callback(err, nil); tel:close(); return end
    tel:send(command, function(send_err, response)
      callback(send_err, response)
      tel:close()
    end)
  end)
  return tel
end

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

--- Whether the active DAP session has a usable stopped frame.
local function stopped_session()
  local session = active_session()
  if not session or not session.stopped_thread_id or not session.current_frame then
    return nil
  end
  return session
end

function M._is_stopped()
  return stopped_session() ~= nil
end

-- Exposed to stopped-only auxiliary views without making them depend on
-- nvim-dap internals or the live-watch implementation.
function M._stopped_session()
  return stopped_session()
end

--- Cancel outstanding stopped-state metadata requests. Keep existing hydrated
--- nodes intact when merely resuming; they remain valid telnet poll plans.
local function invalidate_hydration()
  local state = M._watch
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
  local lw = M.config.live_watch
  local config_lw = tbl_get(M._watch and M._watch.session_config, 'liveWatch')
  local depth = tonumber(tbl_get(config_lw, 'maxDepth') or tbl_get(config_lw, 'max_depth') or lw.max_depth) or 4
  local children = tonumber(tbl_get(config_lw, 'maxChildren') or tbl_get(config_lw, 'max_children') or lw.max_children) or 32
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
  local generation = M._watch and M._watch.generation or 0
  local function valid()
    return entry.hydration_id == hydration_id
      and M._watch
      and M._watch.generation == generation
      and active_session() == session
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
    local signed = not type_name:match('unsigned') and not type_name:match('uint%d')
      and not type_name:match('%*') and not type_name:match('^[uU]')
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
  -- Invalidates in-flight DAP metadata hydration when sessions change or
  -- resume. Running samples must never continue an old DAP request chain.
  generation = 0,
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
  vim.keymap.set('n', '<LeftMouse>', function()
    ui.mouse_line(watch.winid)
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
  width = math.max(1, math.min(width, 32))

  local line_of = {}
  local function add_row(entry, node, indent, root)
    local label = root and entry.raw or (node.name or node.expression)
    local text
    if (root and entry.error) or (not root and node.error) then
      text = '<unresolved: ' .. tostring(root and entry.error or node.error) .. '>'
    elseif root and entry.resolving then
      text = '<resolving...>'
    elseif node.value ~= nil then
      text = node.value
    elseif node.children and #node.children > 0 then
      text = '{' .. tostring(node.type or 'object') .. '}'
      if node.truncated then
        text = text .. ' ...'
      end
    elseif node.type then
      text = '<' .. node.type .. '>'
    else
      text = root and '<pending>' or '<unresolved>'
    end
    local value_lines = vim.split(tostring(text), '\n', { plain = true })
    local prefix = string.rep('  ', indent)
    if root then
      label = label:sub(1, width)
      lines[#lines + 1] = prefix .. string.format('%-' .. width .. 's  %s', label, value_lines[1] or '')
    else
      lines[#lines + 1] = prefix .. label .. '  ' .. (value_lines[1] or '')
    end
    line_of[#lines] = entry
    for i = 2, #value_lines do
      lines[#lines + 1] = string.rep(' ', #prefix + (root and width + 2 or #label + 2)) .. value_lines[i]
      line_of[#lines] = entry
    end
    for _, child in ipairs(node.children or {}) do
      add_row(entry, child, indent + 1, false)
    end
  end

  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' and e.root then
      add_row(e, e.root, 0, true)
    else
      local text
      if e.error then
        text = '<unresolved: ' .. tostring(e.error) .. '>'
      elseif e.resolving then
        text = '<resolving...>'
      elseif e.value == nil then
        text = '<pending>'
      else
        text = e.value
      end
      local value_lines = vim.split(tostring(text), '\n', { plain = true })
      lines[#lines + 1] = string.format('%-' .. width .. 's  %s', e.raw:sub(1, width), value_lines[1] or '')
      line_of[#lines] = e
      for i = 2, #value_lines do
        lines[#lines + 1] = string.rep(' ', width + 2) .. value_lines[i]
        line_of[#lines] = e
      end
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

local peripheral = require('cortex.peripheral')
local rtos = require('cortex.rtos')
local callstack = require('cortex.callstack')
local target = require('cortex.target')
M._peripheral = peripheral -- exposed for tests/statusline integrations
M._rtos = rtos -- exposed for tests/statusline integrations
M._callstack = callstack -- exposed for tests/statusline integrations
M._target = target -- exposed for tests/statusline integrations

local function on_session_start(config)
  invalidate_hydration()
  peripheral.on_session_start(config)
  rtos.on_session_start(config)
  callstack.on_session_start(config)
  -- Never carry addresses or variable handles across debug sessions.
  for _, e in ipairs(watch.entries) do
    -- Do not display a raw command/address value from the previous target
    -- while the new OpenOCD session is still connecting.
    e.value = nil
    e.error = nil
    if e.kind == 'symbol' then
      e.command, e.address, e.size, e.root = nil, nil, nil, nil
      e.variables_reference = nil
      e.resolving = false
    end
  end
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
  invalidate_hydration()
  peripheral.on_session_end()
  rtos.on_session_end()
  callstack.on_session_end()
  M.close_views()
  watch.session_config = nil
  for _, e in ipairs(watch.entries) do
    if e.kind == 'symbol' then
      e.command = nil
      e.address = nil
      e.size = nil
      e.root = nil
      e.variables_reference = nil
      e.resolving = false
    end
    e.value = nil
    e.error = nil
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
  dap.listeners.after.event_continued[key] = function()
    peripheral.on_session_continued()
    rtos.on_session_continued()
    callstack.on_session_continued()
    -- Do not let an in-flight stopped-state hydration chain issue more DAP
    -- requests after resume. Existing address plans remain telnet-only.
    invalidate_hydration()
  end
  dap.listeners.after.event_stopped[key] = function()
    peripheral.on_session_stopped()
    rtos.on_session_stopped()
    callstack.on_session_stopped()
    -- A stopped event is the only point at which C-expression metadata is
    -- hydrated. Running samples below never issue evaluate/variables calls.
    for _, e in ipairs(watch.entries) do
      if e.kind == 'symbol' and not e.resolving then
        hydrate_entry(e, function(err)
          e.error = err
          schedule_render()
        end)
      end
    end
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

function M.peripheral_open()
  return peripheral.open()
end

function M.peripheral_close()
  return peripheral.close()
end

function M.peripheral_toggle()
  return peripheral.toggle()
end

function M.peripheral_refresh(callback)
  return peripheral.refresh(callback)
end

function M.peripheral_element()
  return peripheral.element()
end

function M.peripheral_load(config)
  return peripheral.load(config)
end

function M.rtos_open()
  return rtos.open()
end

function M.rtos_close()
  return rtos.close()
end

function M.rtos_toggle()
  return rtos.toggle()
end

function M.rtos_refresh(callback)
  return rtos.refresh(callback)
end

function M.rtos_element()
  return rtos.element()
end

function M.callstack_open()
  return callstack.open()
end

function M.callstack_close()
  return callstack.close()
end

function M.callstack_toggle()
  return callstack.toggle()
end

function M.callstack_refresh(callback)
  return callstack.refresh(callback)
end

function M.callstack_element()
  return callstack.element()
end

function M.close_views()
  M.close()
  peripheral.close()
  rtos.close()
  callstack.close()
end

function M.debug_select()
  return target.select()
end

function M.debug_start()
  return target.start()
end

function M.debug_clear_target()
  return target.clear()
end

function M.debug_target()
  return target.status()
end

M.select_debug_target = M.debug_select
M.start_debug = M.debug_start

M.open_callstack = M.callstack_open
M.refresh_callstack = M.callstack_refresh

M.open_rtos = M.rtos_open
M.refresh_rtos = M.rtos_refresh

M.open_peripheral = M.peripheral_open
M.refresh_peripheral = M.peripheral_refresh

--- Create the user commands unless they already exist.
function M._create_commands()
  local cmd = api.nvim_create_user_command
  if vim.fn.exists(':CortexDebugWatch') ~= 2 then cmd('CortexDebugWatch', function()
    M.toggle()
  end, { desc = 'Toggle the Cortex live watch window' }) end
  if vim.fn.exists(':CortexDebugWatchAdd') ~= 2 then cmd('CortexDebugWatchAdd', function(o)
    M.add(o.args ~= '' and o.args or nil)
  end, { nargs = '*', desc = 'Add a Cortex live watch expression' }) end
  if vim.fn.exists(':CortexDebugWatchClear') ~= 2 then cmd('CortexDebugWatchClear', function()
    M.clear()
  end, { desc = 'Clear all Cortex live watch expressions' }) end
  if vim.fn.exists(':CortexDebugTelnet') ~= 2 then cmd('CortexDebugTelnet', function(o)
    M.telnet(o.args ~= '' and o.args or nil)
  end, { nargs = '*', desc = 'Send a command to the OpenOCD telnet server' }) end
  if vim.fn.exists(':CortexDebugPeripheral') ~= 2 then cmd('CortexDebugPeripheral', function()
    M.peripheral_toggle()
  end, { desc = 'Toggle the stopped-only Cortex SVD peripheral browser' }) end
  if vim.fn.exists(':CortexDebugPeripheralRefresh') ~= 2 then cmd('CortexDebugPeripheralRefresh', function()
    M.peripheral_refresh()
  end, { desc = 'Refresh SVD peripheral registers (stopped only)' }) end
  if vim.fn.exists(':CortexDebugRTOS') ~= 2 then cmd('CortexDebugRTOS', function()
    M.rtos_toggle()
  end, { desc = 'Toggle the stopped-only FreeRTOS task browser' }) end
  if vim.fn.exists(':CortexDebugRTOSRefresh') ~= 2 then cmd('CortexDebugRTOSRefresh', function()
    M.rtos_refresh()
  end, { desc = 'Refresh FreeRTOS tasks (stopped only)' }) end
  if vim.fn.exists(':CortexFreeRTOS') ~= 2 then cmd('CortexFreeRTOS', function()
    M.rtos_toggle()
  end, { desc = 'Toggle the stopped-only FreeRTOS task browser' }) end
  if vim.fn.exists(':CortexDebugCallStack') ~= 2 then cmd('CortexDebugCallStack', function()
    M.callstack_toggle()
  end, { desc = 'Toggle the stopped-only current call stack' }) end
  if vim.fn.exists(':CortexDebugCallStackRefresh') ~= 2 then cmd('CortexDebugCallStackRefresh', function()
    M.callstack_refresh()
  end, { desc = 'Refresh the current call stack (stopped only)' }) end
  if vim.fn.exists(':CortexDebugStack') ~= 2 then cmd('CortexDebugStack', function()
    M.callstack_toggle()
  end, { desc = 'Toggle the stopped-only current call stack' }) end
  if vim.fn.exists(':CortexDebugSelect') ~= 2 then cmd('CortexDebugSelect', function()
    M.debug_select()
  end, { desc = 'Select and remember a DAP launch target' }) end
  if vim.fn.exists(':CortexDebugStart') ~= 2 then cmd('CortexDebugStart', function()
    M.debug_start()
  end, { desc = 'Start or continue the remembered DAP target' }) end
  if vim.fn.exists(':CortexDebugTarget') ~= 2 then cmd('CortexDebugTarget', function()
    M.debug_target()
  end, { desc = 'Show the remembered DAP launch target' }) end
  if vim.fn.exists(':CortexDebugClearTarget') ~= 2 then cmd('CortexDebugClearTarget', function()
    M.debug_clear_target()
  end, { desc = 'Forget the remembered DAP launch target' }) end
end

----------------------------------------------------------------------------
-- setup
----------------------------------------------------------------------------

---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  if M.config.mouse and not vim.o.mouse:find('a', 1, true) then
    vim.opt.mouse:append('a')
  end
  peripheral.setup(M)
  rtos.setup(M)
  callstack.setup(M)
  target.setup(M)

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
