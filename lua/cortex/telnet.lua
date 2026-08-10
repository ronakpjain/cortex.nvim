---OpenOCD telnet transport used by Live Watch and the peripheral browser.
---
---The server is line-oriented, echoes commands, and terminates responses with
---a prompt. This client serializes requests over one libuv TCP connection and
---handles the small subset of Telnet negotiation emitted by OpenOCD.

local uv = vim.uv or vim.loop

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
        if i + 2 > n then
          return table.concat(out), s:sub(i)
        end
        i = i + 3
      elseif cmd == 250 then -- SB ... IAC SE
        local j = s:find(string.char(IAC, 240), i + 2, true)
        if not j then
          return table.concat(out), s:sub(i)
        end
        i = j + 2
      else
        if i + 1 > n then
          return table.concat(out), s:sub(i)
        end
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

return Telnet
