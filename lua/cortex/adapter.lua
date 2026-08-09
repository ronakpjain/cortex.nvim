--- cortex.nvim -- pure Lua Debug Adapter Protocol adapter for ARM Cortex-M.
---
--- Runs inside a headless Neovim instance (see `adapter_main.lua`):
---
---   nvim --headless --clean -u NONE -l lua/cortex/adapter_main.lua
---
--- It speaks DAP (Content-Length framed JSON) on stdin/stdout, drives
--- `arm-none-eabi-gdb --interpreter=mi2` and, for `servertype == "openocd"`,
--- spawns and supervises an OpenOCD GDB server.
---
--- Only Neovim/libuv APIs are used -- no external Lua dependencies, no Python.
---
--- Deliberately out of scope: pre/postLaunchTask, SVD parsing, peripheral
--- register views, RTOS views, semihosting UIs.

local uv = vim.uv or vim.loop

local M = {}

----------------------------------------------------------------------------
-- Logging (stdout is the DAP channel, so logs go to stderr or a file)
----------------------------------------------------------------------------

local LOG_ENV = 'CORTEX_DAP_LOG'
local log_file = nil
local log_enabled = false

local function log_init()
  local value = os.getenv(LOG_ENV)
  if not value or value == '' or value == '0' then
    return
  end
  log_enabled = true
  if value ~= '1' and value ~= 'stderr' then
    local fh = io.open(value, 'a')
    if fh then
      log_file = fh
    end
  end
end

local function log(...)
  if not log_enabled then
    return
  end
  local parts = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    parts[#parts + 1] = type(v) == 'string' and v or vim.inspect(v)
  end
  local line = '[cortex-dap] ' .. table.concat(parts, ' ') .. '\n'
  if log_file then
    log_file:write(line)
    log_file:flush()
  else
    io.stderr:write(line)
  end
end

M._log = log

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

---@param value any
---@return table
local function as_list(value)
  if value == nil or value == vim.NIL then
    return {}
  end
  if type(value) == 'table' then
    if next(value) == nil then
      return {}
    end
    if value[1] ~= nil then
      return value
    end
    return { value }
  end
  return { value }
end
M.as_list = as_list

---@param value any
---@param default integer|nil
---@return integer
local function as_int(value, default)
  default = default or 0
  if type(value) == 'number' then
    return math.floor(value)
  end
  if type(value) ~= 'string' then
    return default
  end
  local text = vim.trim(value)
  local hex = text:match('^0[xX](%x+)')
  if hex then
    return tonumber(hex, 16) or default
  end
  local dec = text:match('^%-?%d+')
  if dec then
    return tonumber(dec, 10) or default
  end
  return default
end
M.as_int = as_int

---@param text any
---@return string
local function mi_quote(text)
  local s = tostring(text)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
  return '"' .. s .. '"'
end
M.mi_quote = mi_quote

local function is_dict(t)
  return type(t) == 'table' and next(t) ~= nil and t[1] == nil
end

local function basename(path)
  return (tostring(path):gsub('.*/', ''))
end

local function dirname(path)
  local dir = tostring(path):match('^(.*)/[^/]*$')
  return dir or ''
end

local function expanduser(path)
  path = tostring(path)
  if path:sub(1, 1) == '~' then
    local home = os.getenv('HOME') or ''
    if path == '~' then
      return home
    end
    if path:sub(2, 2) == '/' then
      return home .. path:sub(2)
    end
  end
  return path
end

local function is_abs(path)
  return tostring(path):sub(1, 1) == '/'
end

local function normalize(path)
  path = tostring(path):gsub('/+', '/')
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '.' then -- skip
    elseif part == '..' and #parts > 0 and parts[#parts] ~= '..' then
      table.remove(parts)
    else
      parts[#parts + 1] = part
    end
  end
  local out = table.concat(parts, '/')
  if is_abs(path) then
    out = '/' .. out
  end
  return out
end

local function join(a, b)
  if b == nil or b == '' then
    return a
  end
  if is_abs(b) then
    return normalize(b)
  end
  return normalize(a .. '/' .. b)
end

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

----------------------------------------------------------------------------
-- ${...} variable expansion (fallback when the editor did not expand them)
----------------------------------------------------------------------------

---@param config table
---@param cwd string|nil
---@return table
function M.build_variable_table(config, cwd)
  config = config or {}
  local workspace = config.workspaceRoot or config.workspaceFolder or config.cwd or cwd or uv.cwd()
  workspace = tostring(workspace)
  -- nvim-dap expands `${workspaceFolder}` but older versions (and some
  -- launch.json files) still pass `${workspaceRoot}` through.  Treat either
  -- placeholder as the Neovim working directory instead of making a literal
  -- directory named `${workspaceRoot}`.
  if workspace == '${workspaceRoot}' or workspace == '${workspaceFolder}' or workspace == '${cwd}' then
    workspace = cwd or uv.cwd()
  end
  workspace = normalize(expanduser(workspace))
  if not is_abs(workspace) then
    workspace = join(uv.cwd(), workspace)
  end
  local table_ = {
    workspaceRoot = workspace,
    workspaceFolder = workspace,
    cwd = workspace,
    userHome = os.getenv('HOME') or '',
    pathSeparator = '/',
  }
  local current_file = config.file or os.getenv('CORTEX_CURRENT_FILE')
  if current_file and current_file ~= '' then
    current_file = normalize(expanduser(tostring(current_file)))
    table_.file = current_file
    table_.fileDirname = dirname(current_file)
    table_.fileBasename = basename(current_file)
    table_.fileBasenameNoExtension = (basename(current_file):gsub('%.[^.]*$', ''))
  end
  return table_
end

---Recursively expand `${name}` placeholders in strings/lists/dicts.
---@param value any
---@param variables table
---@return any
function M.expand_variables(value, variables)
  if type(value) == 'string' then
    return (value:gsub('%${([A-Za-z_][A-Za-z0-9_]*)}', function(key)
      local replacement = variables[key]
      if replacement == nil then
        return '${' .. key .. '}'
      end
      return tostring(replacement)
    end))
  end
  if type(value) == 'table' then
    local out = {}
    for k, v in pairs(value) do
      out[k] = M.expand_variables(v, variables)
    end
    return out
  end
  return value
end

----------------------------------------------------------------------------
-- DAP wire framing
----------------------------------------------------------------------------

---@param message table
---@return string
function M.encode_message(message)
  local body = vim.json.encode(message)
  return string.format('Content-Length: %d\r\n\r\n%s', #body, body)
end

--- Incremental Content-Length framed message reader.
---@class cortex.dap.Reader
local Reader = {}
Reader.__index = Reader

function Reader.new()
  return setmetatable({ buf = '' }, Reader)
end

---Feed raw bytes; returns a list of decoded messages.
---@param chunk string
---@return table[] messages, string|nil err
function Reader:feed(chunk)
  self.buf = self.buf .. chunk
  local messages = {}
  while true do
    local header_end = self.buf:find('\r\n\r\n', 1, true)
    local sep = 4
    if not header_end then
      header_end = self.buf:find('\n\n', 1, true)
      sep = 2
    end
    if not header_end then
      return messages, nil
    end
    local header = self.buf:sub(1, header_end - 1)
    local length = nil
    for line in header:gmatch('[^\r\n]+') do
      local name, value = line:match('^([^:]+):%s*(.*)$')
      if name and name:lower() == 'content-length' then
        length = tonumber(vim.trim(value))
      end
    end
    if not length then
      return messages, 'missing Content-Length header'
    end
    local body_start = header_end + sep
    if #self.buf < body_start + length - 1 then
      return messages, nil
    end
    local body = self.buf:sub(body_start, body_start + length - 1)
    self.buf = self.buf:sub(body_start + length)
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if ok then
      messages[#messages + 1] = decoded
    else
      log('json decode error:', tostring(decoded))
    end
  end
end

M.Reader = Reader

----------------------------------------------------------------------------
-- GDB/MI parsing
----------------------------------------------------------------------------

local C_ESCAPES = {
  n = '\n',
  t = '\t',
  r = '\r',
  a = '\a',
  b = '\b',
  f = '\f',
  v = '\v',
  ['\\'] = '\\',
  ['"'] = '"',
  ["'"] = "'",
}

local STREAM_KINDS = { ['~'] = 'console', ['@'] = 'target', ['&'] = 'log' }
local ASYNC_KINDS = { ['*'] = 'exec', ['+'] = 'status', ['='] = 'notify' }

---Parse a MI C-string starting at `text:sub(index, index) == '"'`.
---@param text string
---@param index integer 1-based
---@return string value, integer next_index
function M.parse_c_string(text, index)
  index = index or 1
  if text:sub(index, index) ~= '"' then
    error(string.format("expected '\"' at position %d in %q", index, text))
  end
  index = index + 1
  local out = {}
  local n = #text
  while index <= n do
    local ch = text:sub(index, index)
    if ch == '"' then
      return table.concat(out), index + 1
    end
    if ch ~= '\\' then
      out[#out + 1] = ch
      index = index + 1
    else
      index = index + 1
      if index > n then
        break
      end
      local esc = text:sub(index, index)
      if C_ESCAPES[esc] then
        out[#out + 1] = C_ESCAPES[esc]
        index = index + 1
      elseif esc == 'x' then
        index = index + 1
        local digits = text:match('^%x%x?', index) or ''
        index = index + #digits
        out[#out + 1] = #digits > 0 and string.char(tonumber(digits, 16) % 256) or 'x'
      elseif esc:match('%d') then
        local digits = text:match('^[0-7][0-7]?[0-7]?', index) or ''
        index = index + #digits
        out[#out + 1] = string.char(tonumber(digits, 8) % 256)
      else
        out[#out + 1] = esc
        index = index + 1
      end
    end
  end
  error(string.format('unterminated C-string in %q', text))
end

local function skip_ws(text, index)
  local _, stop = text:find('^[ \t]*', index)
  return (stop or index - 1) + 1
end

local function merge_result(store, name, value)
  local existing = store[name]
  if existing == nil then
    store[name] = value
  elseif type(existing) == 'table' and existing.__mi_multi then
    existing[#existing + 1] = value
  else
    store[name] = { existing, value, __mi_multi = true }
  end
end

local parse_mi_value, parse_mi_tuple, parse_mi_list, parse_mi_result

---@param text string
---@param index integer
---@return any value, integer next_index
function parse_mi_value(text, index)
  index = skip_ws(text, index or 1)
  if index > #text then
    error(string.format('unexpected end of MI value in %q', text))
  end
  local ch = text:sub(index, index)
  if ch == '"' then
    return M.parse_c_string(text, index)
  elseif ch == '{' then
    return parse_mi_tuple(text, index)
  elseif ch == '[' then
    return parse_mi_list(text, index)
  end
  local stop = index
  while stop <= #text and not text:sub(stop, stop):match('[,}%]]') do
    stop = stop + 1
  end
  return vim.trim(text:sub(index, stop - 1)), stop
end

function parse_mi_tuple(text, index)
  index = index + 1
  local out = {}
  index = skip_ws(text, index)
  if text:sub(index, index) == '}' then
    return out, index + 1
  end
  while index <= #text do
    local name, value
    name, value, index = parse_mi_result(text, index)
    merge_result(out, name or 'value', value)
    index = skip_ws(text, index)
    local ch = text:sub(index, index)
    if ch == ',' then
      index = index + 1
    elseif ch == '}' then
      return out, index + 1
    else
      break
    end
  end
  error(string.format('unterminated tuple in %q', text))
end

function parse_mi_list(text, index)
  index = index + 1
  local out = {}
  index = skip_ws(text, index)
  if text:sub(index, index) == ']' then
    return out, index + 1
  end
  while index <= #text do
    local _, value
    _, value, index = parse_mi_result(text, index)
    out[#out + 1] = value
    index = skip_ws(text, index)
    local ch = text:sub(index, index)
    if ch == ',' then
      index = index + 1
    elseif ch == ']' then
      return out, index + 1
    else
      break
    end
  end
  error(string.format('unterminated list in %q', text))
end

---@return string|nil name, any value, integer next_index
function parse_mi_result(text, index)
  index = skip_ws(text, index)
  local ch = text:sub(index, index)
  if ch == '"' or ch == '{' or ch == '[' then
    local value
    value, index = parse_mi_value(text, index)
    return nil, value, index
  end
  local name = text:match('^[A-Za-z_][A-Za-z0-9_%-]*', index)
  if not name then
    local value
    value, index = parse_mi_value(text, index)
    return nil, value, index
  end
  index = index + #name
  index = skip_ws(text, index)
  if text:sub(index, index) == '=' then
    local value
    value, index = parse_mi_value(text, index + 1)
    return name, value, index
  end
  return nil, name, index
end

---Parse a comma separated MI result list into a table.
---@param text string
---@param index integer|nil
---@return table
function M.parse_mi_results(text, index)
  local out = {}
  index = skip_ws(text, index or 1)
  while index <= #text do
    if text:sub(index, index) == ',' then
      index = index + 1
    else
      local name, value
      name, value, index = parse_mi_result(text, index)
      merge_result(out, name or 'value', value)
      index = skip_ws(text, index)
      if text:sub(index, index) == ',' then
        index = index + 1
      else
        break
      end
    end
  end
  return out
end

---Parse one GDB/MI output line into a record table.
---
---   { type = 'result',   token = n|nil, class = str, results = {} }
---   { type = 'exec'|'status'|'notify', token = n|nil, class = str, results = {} }
---   { type = 'stream',   stream = 'console'|'target'|'log', output = str }
---   { type = 'prompt' }
---   { type = 'unknown',  raw = str }
---@param line string|nil
---@return table
function M.parse_mi_line(line)
  if line == nil then
    return { type = 'unknown', raw = '' }
  end
  line = line:gsub('[\r\n]+$', '')
  if vim.trim(line) == '' then
    return { type = 'unknown', raw = line }
  end
  if vim.trim(line) == '(gdb)' then
    return { type = 'prompt' }
  end

  local token_text, kind, rest = line:match('^(%d*)([%^%*%+=~@&])(.*)$')
  if not kind then
    return { type = 'unknown', raw = line }
  end
  local token = (token_text ~= '' and tonumber(token_text)) or nil

  if STREAM_KINDS[kind] then
    local ok, output = pcall(M.parse_c_string, rest, 1)
    if not ok then
      output = rest
    end
    return { type = 'stream', stream = STREAM_KINDS[kind], output = output }
  end

  local class_name = rest:match('^[A-Za-z0-9_%-]*') or ''
  local index = #class_name + 1
  index = skip_ws(rest, index)
  if rest:sub(index, index) == ',' then
    index = index + 1
  end
  local ok, results = pcall(M.parse_mi_results, rest, index)
  if not ok then
    log('MI parse error:', tostring(results), 'line:', line)
    results = {}
  end

  return {
    type = kind == '^' and 'result' or ASYNC_KINDS[kind],
    token = token,
    class = class_name,
    results = results,
  }
end

----------------------------------------------------------------------------
-- Coroutine helpers (all blocking work happens inside tasks)
----------------------------------------------------------------------------

local function resume(co, ...)
  if coroutine.status(co) ~= 'suspended' then
    return
  end
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    log('task error:', tostring(err))
  end
end

---Run `fn` in a coroutine; `on_error(err)` is called if it throws.
local function spawn_task(fn, on_error)
  local co = coroutine.create(function()
    local ok, err = pcall(fn)
    if not ok and on_error then
      on_error(err)
    elseif not ok then
      log('task error:', tostring(err))
    end
  end)
  resume(co)
  return co
end

---Yield the current task for `ms` milliseconds.
local function sleep(ms)
  local co = coroutine.running()
  local timer = uv.new_timer()
  timer:start(ms, 0, function()
    timer:stop()
    timer:close()
    resume(co)
  end)
  coroutine.yield()
end

----------------------------------------------------------------------------
-- Environment / process helpers
----------------------------------------------------------------------------

local function build_env(extra)
  local env = {}
  local base = uv.os_environ and uv.os_environ() or {}
  for k, v in pairs(base) do
    env[#env + 1] = string.format('%s=%s', k, v)
  end
  for k, v in pairs(extra or {}) do
    env[#env + 1] = string.format('%s=%s', tostring(k), tostring(v))
  end
  return env
end

----------------------------------------------------------------------------
-- GDB session
----------------------------------------------------------------------------

---@class cortex.dap.GDB
local GDB = {}
GDB.__index = GDB

---@param opts table path, cwd, env, args, on_async, on_stream, on_exit
---@return cortex.dap.GDB|nil, string|nil err
function GDB.new(opts)
  local self = setmetatable({
    path = opts.path,
    cwd = opts.cwd,
    on_async = opts.on_async,
    on_stream = opts.on_stream,
    on_exit = opts.on_exit,
    token = 0,
    pending = {},
    console = {},
    alive = true,
    buf = '',
  }, GDB)

  local args = { '--interpreter=mi2', '-q', '--nx' }
  for _, a in ipairs(as_list(opts.args)) do
    args[#args + 1] = tostring(a)
  end

  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  log('spawning gdb:', opts.path, table.concat(args, ' '))
  local handle, pid = uv.spawn(opts.path, {
    args = args,
    cwd = opts.cwd,
    env = build_env(opts.env),
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    self.alive = false
    self.exit_code = code
    self:_fail_pending(string.format('gdb exited (code %s, signal %s)', tostring(code), tostring(signal)))
    if self.on_exit then
      self.on_exit(code, signal)
    end
  end)

  if not handle then
    pcall(function()
      self.stdin:close()
      self.stdout:close()
      self.stderr:close()
    end)
    return nil, string.format('could not launch gdb: %s (%s)', tostring(opts.path), tostring(pid))
  end
  self.handle = handle
  self.pid = pid

  self.stdout:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    self:_on_stdout(chunk)
  end)
  self.stderr:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    if self.on_stream then
      self.on_stream('stderr', chunk)
    end
  end)
  return self
end

function GDB:is_alive()
  return self.alive and self.handle ~= nil
end

function GDB:_fail_pending(reason)
  local pending = self.pending
  self.pending = {}
  for _, slot in pairs(pending) do
    slot.done = true
    if slot.timer then
      pcall(function()
        slot.timer:stop()
        slot.timer:close()
      end)
    end
    resume(slot.co, { type = 'result', class = 'error', results = { msg = reason } })
  end
end

function GDB:_on_stdout(chunk)
  self.buf = self.buf .. chunk
  while true do
    local nl = self.buf:find('\n', 1, true)
    if not nl then
      break
    end
    local line = self.buf:sub(1, nl - 1)
    self.buf = self.buf:sub(nl + 1)
    local ok, err = pcall(function()
      self:_handle_line(line)
    end)
    if not ok then
      log('error handling MI line:', tostring(err), line)
    end
  end
end

function GDB:_handle_line(line)
  local record = M.parse_mi_line(line)
  local kind = record.type
  if kind == 'stream' then
    local text = record.output or ''
    if record.stream == 'log' then
      log('gdb log:', (text:gsub('\n$', '')))
      if self.on_stream then
        self.on_stream('console', text)
      end
    else
      self.console[#self.console + 1] = text
      if self.on_stream then
        self.on_stream(record.stream == 'target' and 'stdout' or 'console', text)
      end
    end
    return
  end
  if kind == 'result' then
    record.console = table.concat(self.console)
    self.console = {}
    local slot = record.token and self.pending[record.token] or nil
    if slot then
      self.pending[record.token] = nil
      slot.done = true
      if slot.timer then
        pcall(function()
          slot.timer:stop()
          slot.timer:close()
        end)
      end
      resume(slot.co, record)
    elseif self.on_async then
      self.on_async(record)
    end
    return
  end
  if kind == 'exec' or kind == 'notify' or kind == 'status' then
    if self.on_async then
      self.on_async(record)
    end
  end
end

---Send a MI command and wait (inside a task) for its result record.
---@param command string
---@param timeout number|nil seconds
---@return table record
function GDB:send(command, timeout)
  timeout = (timeout or 30) * 1000
  if not self:is_alive() then
    return { type = 'result', class = 'error', results = { msg = 'gdb is not running' } }
  end
  local co = coroutine.running()
  if not co then
    error('GDB:send must be called from inside a task')
  end
  self.token = self.token + 1
  local token = self.token
  local slot = { co = co, done = false }
  self.pending[token] = slot

  local line = string.format('%d%s\n', token, command)
  log('>>', vim.trim(line))
  self.stdin:write(line, function(werr)
    if werr and not slot.done then
      slot.done = true
      self.pending[token] = nil
      resume(co, {
        type = 'result',
        class = 'error',
        results = { msg = 'failed to write to gdb: ' .. tostring(werr) },
      })
    end
  end)

  local timer = uv.new_timer()
  slot.timer = timer
  timer:start(math.floor(timeout), 0, function()
    timer:stop()
    timer:close()
    slot.timer = nil
    if not slot.done then
      slot.done = true
      self.pending[token] = nil
      resume(co, {
        type = 'result',
        class = 'error',
        results = { msg = string.format('timeout waiting for gdb response to %q', command) },
      })
    end
  end)

  local record = coroutine.yield()
  return record or { type = 'result', class = 'error', results = { msg = 'no record' } }
end

---Run a plain gdb console command through MI.
function GDB:console_cmd(command, timeout)
  return self:send('-interpreter-exec console ' .. mi_quote(command), timeout)
end

---@param record table
---@return string
local function record_error(record)
  local results = record and record.results or {}
  local msg = results.msg or results.message
  if type(msg) == 'table' then
    msg = msg[1]
  end
  return tostring(msg or 'gdb error')
end
M.record_error = record_error

local function record_ok(record)
  return record ~= nil and record.class ~= 'error'
end
M.record_ok = record_ok

function GDB:terminate()
  self.alive = false
  if self.stdin and not self.stdin:is_closing() then
    pcall(function()
      self.stdin:write('-gdb-exit\n')
    end)
  end
  -- Do not wait for the DAP client to close this adapter process. nvim-dap
  -- closes an executable adapter as soon as it receives `terminated`, which
  -- can otherwise orphan GDB before its delayed timer fires.
  local handle = self.handle
  if handle and not handle:is_closing() then
    pcall(function()
      handle:kill('sigterm')
    end)
    local timer = uv.new_timer()
    timer:start(500, 0, function()
      timer:stop()
      timer:close()
      if handle and not handle:is_closing() then
        pcall(function()
          handle:kill('sigkill')
        end)
      end
    end)
  end
end

function GDB:close()
  for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr }) do
    if pipe and not pipe:is_closing() then
      pcall(function()
        pipe:read_stop()
      end)
      pcall(function()
        pipe:close()
      end)
    end
  end
  if self.handle and not self.handle:is_closing() then
    pcall(function()
      self.handle:kill('sigkill')
    end)
    pcall(function()
      self.handle:close()
    end)
  end
end

M.GDB = GDB

----------------------------------------------------------------------------
-- GDB server (OpenOCD)
----------------------------------------------------------------------------

---@class cortex.dap.Server
local Server = {}
Server.__index = Server

---@param opts table argv, cwd, env, on_output
---@return cortex.dap.Server|nil, string|nil
function Server.new(opts)
  local argv = opts.argv
  local self = setmetatable({
    argv = argv,
    lines = {},
    alive = true,
    on_output = opts.on_output,
  }, Server)

  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local args = {}
  for i = 2, #argv do
    args[#args + 1] = tostring(argv[i])
  end

  log('spawning gdb server:', table.concat(argv, ' '))
  local handle, pid = uv.spawn(argv[1], {
    args = args,
    cwd = opts.cwd,
    env = build_env(opts.env),
    stdio = { nil, self.stdout, self.stderr },
  }, function(code, signal)
    self.alive = false
    self.exit_code = code
    if opts.on_exit then
      opts.on_exit(code, signal)
    end
  end)

  if not handle then
    pcall(function()
      self.stdout:close()
      self.stderr:close()
    end)
    return nil, string.format('could not launch GDB server: %s (%s)', tostring(argv[1]), tostring(pid))
  end
  self.handle = handle
  self.pid = pid

  local function reader(err, chunk)
    if err or not chunk then
      return
    end
    self.lines[#self.lines + 1] = chunk
    if #self.lines > 200 then
      table.remove(self.lines, 1)
    end
    if self.on_output then
      self.on_output(chunk)
    end
  end
  self.stdout:read_start(reader)
  self.stderr:read_start(reader)
  return self
end

function Server:is_alive()
  return self.alive and self.handle ~= nil
end

function Server:recent_output()
  return table.concat(self.lines)
end

function Server:kill()
  local handle = self.handle
  if not handle or handle:is_closing() then
    return
  end
  log('killing gdb server')
  self.alive = false
  -- OpenOCD can ignore SIGINT while it is inside a target operation. Send a
  -- terminating signal immediately so the adapter cannot be killed first and
  -- leave an orphan listening on ports 3333/4444.
  pcall(function()
    handle:kill('sigterm')
  end)
  local timer = uv.new_timer()
  timer:start(500, 0, function()
    timer:stop()
    timer:close()
    if handle and not handle:is_closing() then
      pcall(function()
        handle:kill('sigkill')
      end)
    end
  end)
end

function Server:close()
  for _, pipe in ipairs({ self.stdout, self.stderr }) do
    if pipe and not pipe:is_closing() then
      pcall(function()
        pipe:read_stop()
      end)
      pcall(function()
        pipe:close()
      end)
    end
  end
  if self.handle and not self.handle:is_closing() then
    pcall(function()
      self.handle:kill('sigkill')
    end)
    pcall(function()
      self.handle:close()
    end)
  end
end

M.Server = Server

---Wait (inside a task) until `host:port` accepts TCP connections.
---@param host string
---@param port integer
---@param timeout_s number
---@param is_alive fun():boolean|nil
---@return boolean
local function wait_for_port(host, port, timeout_s, is_alive)
  local deadline = uv.now() + math.floor((timeout_s or 20) * 1000)
  while uv.now() < deadline do
    if is_alive and not is_alive() then
      return false
    end
    local co = coroutine.running()
    local tcp = uv.new_tcp()
    local settled = false
    local ok_connect = false
    tcp:connect(host, port, function(err)
      if settled then
        return
      end
      settled = true
      ok_connect = err == nil
      pcall(function()
        tcp:close()
      end)
      resume(co)
    end)
    local guard = uv.new_timer()
    guard:start(600, 0, function()
      guard:stop()
      guard:close()
      if not settled then
        settled = true
        pcall(function()
          tcp:close()
        end)
        resume(co)
      end
    end)
    coroutine.yield()
    if ok_connect then
      return true
    end
    sleep(150)
    uv.update_time()
  end
  return false
end
M._wait_for_port = wait_for_port

---Build the OpenOCD command line from a (variable expanded) config.
---@param config table
---@param server_path string|nil
---@return string[]
function M.build_openocd_argv(config, server_path)
  local argv = { server_path or config.serverpath or config.serverPath or 'openocd' }
  local function push(...)
    for i = 1, select('#', ...) do
      argv[#argv + 1] = tostring((select(i, ...)))
    end
  end
  for _, search in ipairs(as_list(config.searchDir)) do
    push('-s', search)
  end
  for _, cfg in ipairs(as_list(config.configFiles)) do
    push('-f', cfg)
  end
  local gdb_port = as_int(config.gdbPort, 3333)
  if gdb_port == 0 then
    gdb_port = 3333
  end
  local telnet_port = as_int(config.telnetPort, 4444)
  if telnet_port == 0 then
    telnet_port = 4444
  end
  push('-c', string.format('gdb_port %d', gdb_port))
  push('-c', string.format('telnet_port %d', telnet_port))
  for _, cmd in ipairs(as_list(config.openOCDLaunchCommands)) do
    push('-c', cmd)
  end
  for _, cmd in ipairs(as_list(config.openocdLaunchCommands)) do
    push('-c', cmd)
  end
  for _, extra in ipairs(as_list(config.serverArgs)) do
    push(extra)
  end
  return argv
end

----------------------------------------------------------------------------
-- Debug adapter
----------------------------------------------------------------------------

local STOP_REASONS = {
  ['breakpoint-hit'] = 'breakpoint',
  ['watchpoint-trigger'] = 'data breakpoint',
  ['read-watchpoint-trigger'] = 'data breakpoint',
  ['access-watchpoint-trigger'] = 'data breakpoint',
  ['end-stepping-range'] = 'step',
  ['function-finished'] = 'step',
  ['location-reached'] = 'step',
  ['signal-received'] = 'exception',
  ['exception-received'] = 'exception',
}

--- Requests that must not wait behind the serialized request queue.
local IMMEDIATE = {
  initialize = true,
  pause = true,
  disconnect = true,
  terminate = true,
  cancel = true,
}

---@class cortex.dap.Adapter
local Adapter = {}
Adapter.__index = Adapter

function Adapter.new()
  return setmetatable({
    seq = 0,
    reader = Reader.new(),
    queue = {},
    busy = false,
    running = true,
    done = false,
    config = {},
    cwd = uv.cwd(),
    is_attach = false,
    no_debug = false,
    shutting_down = false,
    configuration_done = false,
    current_thread = 1,
    stopped = true,
    breakpoints = {},
    handles = {},
    handle_seq = 1000,
    varobjs = {},
    pending_writes = 0,
  }, Adapter)
end

-- -- io ---------------------------------------------------------------------

function Adapter:_write(message)
  self.seq = self.seq + 1
  message.seq = self.seq
  local ok, data = pcall(M.encode_message, message)
  if not ok then
    log('encode error:', tostring(data))
    return
  end
  log('<<', vim.trim(data:gsub('^Content%-Length:[^\r\n]*\r?\n\r?\n', '')))
  self.pending_writes = self.pending_writes + 1
  if self.stdout_pipe then
    self.stdout_pipe:write(data, function()
      self.pending_writes = self.pending_writes - 1
    end)
  else
    io.stdout:write(data)
    io.stdout:flush()
    self.pending_writes = self.pending_writes - 1
  end
end

function Adapter:send_event(event, body)
  local message = { type = 'event', event = event }
  if body ~= nil then
    message.body = body
  end
  self:_write(message)
end

function Adapter:send_response(request, body, success, message)
  local response = {
    type = 'response',
    request_seq = request.seq or 0,
    command = request.command or '',
    success = success ~= false,
  }
  if message then
    response.message = message
  end
  if body ~= nil then
    response.body = body
  end
  self:_write(response)
end

function Adapter:output(text, category)
  if not text or text == '' then
    return
  end
  self:send_event('output', { category = category or 'console', output = tostring(text) })
end

-- -- request dispatch --------------------------------------------------------

function Adapter:handle_message(message)
  if type(message) ~= 'table' or message.type ~= 'request' then
    return
  end
  local command = tostring(message.command or '')
  if IMMEDIATE[command] then
    self:run_request(message)
  else
    self.queue[#self.queue + 1] = message
    self:pump()
  end
end

function Adapter:pump()
  if self.busy or #self.queue == 0 then
    return
  end
  local request = table.remove(self.queue, 1)
  self.busy = true
  self:run_request(request, function()
    self.busy = false
    self:pump()
  end)
end

function Adapter:run_request(request, on_done)
  local command = tostring(request.command or '')
  local handler = self['on_' .. command]
  if not handler then
    log('unsupported request:', command)
    self:send_response(request, nil, false, 'unsupported request: ' .. command)
    if on_done then
      on_done()
    end
    return
  end
  spawn_task(function()
    local ok, err = pcall(handler, self, request)
    if not ok then
      log('error in ' .. command .. ':', tostring(err))
      pcall(function()
        self:send_response(request, nil, false, command .. ': ' .. tostring(err))
      end)
    end
    if on_done then
      on_done()
    end
  end, function(err)
    log('task failure in ' .. command .. ':', tostring(err))
    if on_done then
      on_done()
    end
  end)
end

-- -- lifecycle ---------------------------------------------------------------

function Adapter:on_initialize(request)
  self:send_response(request, {
    supportsConfigurationDoneRequest = true,
    supportsEvaluateForHovers = true,
    supportsSetVariable = true,
    supportsRestartRequest = false,
    supportsTerminateRequest = true,
    supportsConditionalBreakpoints = true,
    supportsHitConditionalBreakpoints = true,
    supportsFunctionBreakpoints = true,
    supportsSteppingGranularity = false,
    supportsDisassembleRequest = false,
    supportsReadMemoryRequest = true,
    supportsValueFormattingOptions = false,
    supportTerminateDebuggee = true,
    exceptionBreakpointFilters = {},
  })
end

function Adapter:_prepare_config(request)
  local raw = request.arguments or {}
  local variables = M.build_variable_table(raw)
  local config = M.expand_variables(raw, variables)
  local cwd = config.cwd or variables.workspaceRoot
  cwd = expanduser(tostring(cwd))
  if not is_abs(cwd) then
    cwd = join(uv.cwd(), cwd)
  end
  self.cwd = normalize(cwd)
  self.config = config
  self.no_debug = config.noDebug == true
  local executable = config.executable or config.program
  if executable and executable ~= '' then
    executable = expanduser(tostring(executable))
    if not is_abs(executable) then
      executable = join(self.cwd, executable)
    end
    self.executable = normalize(executable)
  end
  return config
end

function Adapter:_gdb_path(config)
  local gdb_path = config.gdbPath
  if not gdb_path or gdb_path == '' then
    local prefix = config.toolchainPrefix
    if not prefix or prefix == '' then
      prefix = 'arm-none-eabi'
    end
    gdb_path = prefix .. '-gdb'
  end
  gdb_path = tostring(gdb_path)
  local toolchain_path = config.toolchainPath
  if toolchain_path and toolchain_path ~= '' and dirname(gdb_path) == '' then
    gdb_path = join(normalize(expanduser(tostring(toolchain_path))), gdb_path)
  end
  return expanduser(gdb_path)
end

function Adapter:_start_server(config)
  local servertype = tostring(config.servertype or config.serverType or 'openocd'):lower()
  if servertype == 'external' then
    return
  end
  if servertype ~= 'openocd' then
    error(string.format("unsupported servertype %q (only 'openocd' and 'external' are supported)", servertype))
  end
  local argv = M.build_openocd_argv(config)
  local server, err = Server.new({
    argv = argv,
    cwd = self.cwd,
    env = config.env,
    on_output = function(chunk)
      self:output(chunk, 'stdout')
    end,
  })
  if not server then
    error(err)
  end
  self.server = server

  local host = tostring(config.gdbTarget or 'localhost')
  if host:find(':', 1, true) then
    host = host:match('^([^:]*)')
  end
  if host == '' or host == 'localhost' then
    host = '127.0.0.1'
  end
  local port = as_int(config.gdbPort, 3333)
  if port == 0 then
    port = 3333
  end
  local timeout = tonumber(config.serverStartTimeout) or 20
  if timeout > 1000 then -- milliseconds given
    timeout = timeout / 1000
  end
  local ok = wait_for_port(host, port, timeout, function()
    return server:is_alive()
  end)
  if not ok then
    local output = server:recent_output()
    server:kill()
    server:close()
    self.server = nil
    error(string.format('GDB server did not open port %d in time.\n%s', port, output))
  end
end

function Adapter:_start_gdb(config)
  local gdb_path = self:_gdb_path(config)
  local gdb, err = GDB.new({
    path = gdb_path,
    cwd = self.cwd,
    env = config.env,
    -- Cortex/launch.json files commonly call these `debuggerArgs`.
    -- Accept `gdbArgs` as a native alias without dropping the standard key.
    args = config.gdbArgs or config.debuggerArgs,
    on_async = function(record)
      self:_on_gdb_async(record)
    end,
    on_stream = function(category, text)
      self:output(text, category)
    end,
    on_exit = function()
      self:_on_gdb_exit()
    end,
  })
  if not gdb then
    error(err)
  end
  self.gdb = gdb
  gdb:send('-gdb-set mi-async on', 10)
  gdb:send('-gdb-set confirm off', 10)
  gdb:send('-gdb-set pagination off', 10)
  gdb:send('-gdb-set print pretty on', 10)
  gdb:send('-gdb-set breakpoint pending on', 10)
end

function Adapter:_target_spec(config)
  local port = as_int(config.gdbPort, 3333)
  if port == 0 then
    port = 3333
  end
  local target = config.gdbTarget
  if target and target ~= '' then
    target = tostring(target)
    if target:find(':', 1, true) then
      return target
    end
    return string.format('%s:%d', target, port)
  end
  return string.format('localhost:%d', port)
end

function Adapter:_run_commands(commands)
  for _, command in ipairs(as_list(commands)) do
    command = tostring(command)
    if command:sub(1, 1) == '-' then
      self.gdb:send(command, 60)
    else
      self.gdb:console_cmd(command, 60)
    end
  end
end

function Adapter:on_launch(request)
  self:_launch_or_attach(request, false)
end

function Adapter:on_attach(request)
  self:_launch_or_attach(request, true)
end

function Adapter:_launch_or_attach(request, attach)
  local config = self:_prepare_config(request)
  self.is_attach = attach

  self:_start_server(config)
  self:_start_gdb(config)

  if self.executable then
    if not file_exists(self.executable) then
      self:output(string.format('warning: executable not found: %s\n', self.executable), 'stderr')
    end
    local record = self.gdb:send('-file-exec-and-symbols ' .. mi_quote(self.executable), 60)
    if not record_ok(record) then
      error('could not load executable: ' .. record_error(record))
    end
  elseif not attach then
    self:output('warning: no `executable` configured; nothing will be flashed\n', 'stderr')
  end

  self:_run_commands(attach and config.preAttachCommands or config.preLaunchCommands)

  local target = self:_target_spec(config)
  local record = self.gdb:send('-target-select extended-remote ' .. target, 30)
  if not record_ok(record) then
    error(string.format('could not connect to %s: %s', target, record_error(record)))
  end

  if not attach then
    local overrides = as_list(config.overrideLaunchCommands)
    if #overrides > 0 then
      self:_run_commands(overrides)
    else
      self.gdb:console_cmd('monitor reset halt', 30)
      if self.executable and config.loadFiles ~= false then
        local dl = self.gdb:send('-target-download', 300)
        if not record_ok(dl) then
          error('flash download failed: ' .. record_error(dl))
        end
      end
      self.gdb:console_cmd('monitor reset halt', 30)
    end
  else
    self:_run_commands(config.overrideAttachCommands)
  end

  self:_run_commands(attach and config.postAttachCommands or config.postLaunchCommands)

  self.stopped = true
  self:send_event('initialized')
  self:send_response(request)
end

function Adapter:on_configurationDone(request)
  self:send_response(request)
  self.configuration_done = true
  local ok, err = pcall(function()
    self:_post_configuration()
  end)
  if not ok then
    self:output('error: ' .. tostring(err) .. '\n', 'stderr')
  end
end

function Adapter:_post_configuration()
  if not self.gdb or not self.gdb:is_alive() then
    return
  end
  local config = self.config
  local entry = config.runToEntryPoint
  if (entry == nil or entry == vim.NIL) and not self.is_attach and config.runToMain then
    entry = 'main'
  end
  local stop_at_entry = config.stopAtEntry ~= false

  if self.no_debug then
    self:_continue_all()
    return
  end

  if entry and entry ~= vim.NIL and entry ~= '' and not self.is_attach then
    self.awaiting_entry = true
    self.gdb:send('-break-insert -t ' .. mi_quote(tostring(entry)), 30)
    self:_continue_all()
    -- The *stopped async record emits the DAP `stopped` event.
    return
  end
  if not stop_at_entry then
    self:_continue_all()
    return
  end
  self.stopped = true
  self:send_event('stopped', {
    reason = 'entry',
    threadId = self.current_thread,
    allThreadsStopped = true,
  })
end

function Adapter:_continue_all()
  local record = self.gdb:send('-exec-continue --all', 30)
  if not record_ok(record) then
    record = self.gdb:send('-exec-continue', 30)
  end
  return record
end

function Adapter:on_disconnect(request)
  local args = request.arguments or {}
  local terminate = args.terminateDebuggee
  if terminate == nil or terminate == vim.NIL then
    terminate = not self.is_attach
  end
  self:_teardown(terminate == true)
  self:send_response(request)
  self:shutdown()
end

function Adapter:on_terminate(request)
  self:_teardown(true)
  self:send_response(request)
  self:send_event('terminated')
  -- nvim-dap usually follows `terminate` with `disconnect`; give it a chance
  -- to be answered before the process goes away.
  self:shutdown(3000)
end

function Adapter:_teardown(terminate)
  if self.shutting_down then
    return
  end
  self.shutting_down = true
  local gdb, server = self.gdb, self.server
  self.gdb, self.server = nil, nil
  if gdb and gdb:is_alive() then
    if not self.stopped then
      gdb:send('-exec-interrupt --all', 2)
    end
    if self.is_attach and not terminate then
      gdb:send('-target-detach', 3)
    else
      gdb:send('-target-disconnect', 3)
    end
    gdb:terminate()
  end
  if server then
    server:kill()
  end
  self._dead_gdb = gdb
  self._dead_server = server
end

---Stop the adapter after `delay_ms` (lets pending writes flush and the child
---processes die). Calling it again with a shorter delay wins.
---@param delay_ms integer|nil
function Adapter:shutdown(delay_ms)
  delay_ms = delay_ms or 300
  self.running = false
  if self.exit_timer then
    if (self.exit_at or math.huge) <= uv.now() + delay_ms then
      return -- an earlier (or equal) exit is already scheduled
    end
    pcall(function()
      self.exit_timer:stop()
      self.exit_timer:close()
    end)
    self.exit_timer = nil
  end
  uv.update_time()
  self.exit_at = uv.now() + delay_ms
  local timer = uv.new_timer()
  self.exit_timer = timer
  timer:start(delay_ms, 0, function()
    timer:stop()
    timer:close()
    self.exit_timer = nil
    if self._dead_gdb then
      self._dead_gdb:close()
    end
    if self._dead_server then
      self._dead_server:close()
    end
    self.done = true
  end)
end

function Adapter:_on_gdb_exit()
  if self.shutting_down then
    return
  end
  self:send_event('terminated')
  self:send_event('exited', { exitCode = 0 })
  if self.server then
    self.server:kill()
  end
end

-- -- async gdb records --------------------------------------------------------

function Adapter:_on_gdb_async(record)
  local class = record.class
  local results = record.results or {}
  if class == 'stopped' then
    self:_handle_stopped(results)
  elseif class == 'running' then
    self.stopped = false
    self.handles = {}
    local thread_id = results['thread-id']
    self:send_event('continued', {
      threadId = thread_id ~= 'all' and as_int(thread_id, self.current_thread) or self.current_thread,
      allThreadsContinued = thread_id == 'all',
    })
  elseif class == 'thread-created' then
    self:send_event('thread', { reason = 'started', threadId = as_int(results.id, 1) })
  elseif class == 'thread-exited' then
    self:send_event('thread', { reason = 'exited', threadId = as_int(results.id, 1) })
  elseif class == 'breakpoint-modified' then
    local bkpt = results.bkpt
    if is_dict(bkpt) then
      self:send_event('breakpoint', {
        reason = 'changed',
        breakpoint = {
          id = as_int(bkpt.number, 0),
          verified = true,
          line = as_int(bkpt.line, 0),
        },
      })
    end
  end
end

function Adapter:_handle_stopped(results)
  self.stopped = true
  self.handles = {}
  local reason = results.reason or ''
  if type(reason) == 'table' then
    reason = reason[1] or ''
  end
  reason = tostring(reason)
  local thread_id = as_int(results['thread-id'], self.current_thread)
  self.current_thread = thread_id ~= 0 and thread_id or 1

  if reason:match('^exited') then
    self:send_event('exited', { exitCode = as_int(results['exit-code'], 0) })
    self:send_event('terminated')
    return
  end

  local body = {
    reason = STOP_REASONS[reason] or (reason ~= '' and reason or 'pause'),
    threadId = self.current_thread,
    allThreadsStopped = true,
  }
  local bkptno = results.bkptno
  if bkptno ~= nil then
    body.hitBreakpointIds = { as_int(bkptno, 0) }
  end
  -- The first stop caused by `runToEntryPoint` (or a stop that happens before
  -- the client finished configuring) is an `entry` stop for DAP clients.
  if self.awaiting_entry or not self.configuration_done then
    self.awaiting_entry = false
    body.reason = 'entry'
    body.hitBreakpointIds = nil
  end
  local signal_name = results['signal-name']
  if signal_name and signal_name ~= '' then
    body.description = tostring(signal_name)
    body.text = tostring(results['signal-meaning'] or signal_name)
    if signal_name == 'SIGINT' then
      body.reason = 'pause'
    end
  end
  self:send_event('stopped', body)
end

-- -- breakpoints ---------------------------------------------------------------

function Adapter:on_setBreakpoints(request)
  local args = request.arguments or {}
  local source = args.source or {}
  local path = tostring(source.path or source.name or '')
  path = M.expand_variables(path, M.build_variable_table(self.config, self.cwd))
  local requested = args.breakpoints
  if requested == nil then
    requested = {}
    for _, line in ipairs(as_list(args.lines)) do
      requested[#requested + 1] = { line = line }
    end
  end

  if not self.gdb or not self.gdb:is_alive() then
    local out = {}
    for _, bp in ipairs(requested) do
      out[#out + 1] = { verified = false, line = as_int(bp.line, 0) }
    end
    self:send_response(request, { breakpoints = out })
    return
  end

  for _, number in ipairs(self.breakpoints[path] or {}) do
    self.gdb:send(string.format('-break-delete %d', number), 10)
  end
  self.breakpoints[path] = nil

  local created, numbers = {}, {}
  for _, bp in ipairs(requested) do
    local line = as_int(bp.line, 0)
    local parts = { '-break-insert', '-f' }
    if bp.condition and bp.condition ~= '' and bp.condition ~= vim.NIL then
      parts[#parts + 1] = '-c'
      parts[#parts + 1] = mi_quote(bp.condition)
    end
    if bp.hitCondition and bp.hitCondition ~= vim.NIL then
      parts[#parts + 1] = '-i'
      parts[#parts + 1] = tostring(as_int(bp.hitCondition, 0))
    end
    parts[#parts + 1] = mi_quote(string.format('%s:%d', path, line))
    local record = self.gdb:send(table.concat(parts, ' '), 30)
    if not record_ok(record) then
      created[#created + 1] = { verified = false, line = line, message = record_error(record) }
    else
      local info = (record.results or {}).bkpt or {}
      if not is_dict(info) then
        info = info[1] or {}
      end
      local number = as_int(info.number, 0)
      if number ~= 0 then
        numbers[#numbers + 1] = number
      end
      created[#created + 1] = {
        id = number,
        verified = info.pending == nil,
        line = as_int(info.line, line),
        source = { path = path, name = basename(path) },
      }
    end
  end
  self.breakpoints[path] = numbers
  self:send_response(request, { breakpoints = created })
end

function Adapter:on_setFunctionBreakpoints(request)
  local args = request.arguments or {}
  local key = '\0functions'
  local results = {}
  for _, number in ipairs(self.breakpoints[key] or {}) do
    if self.gdb then
      self.gdb:send(string.format('-break-delete %d', number), 10)
    end
  end
  self.breakpoints[key] = nil
  local numbers = {}
  for _, bp in ipairs(as_list(args.breakpoints)) do
    local name = tostring(bp.name or '')
    if not self.gdb or not self.gdb:is_alive() then
      results[#results + 1] = { verified = false }
    else
      local record = self.gdb:send('-break-insert -f ' .. mi_quote(name), 30)
      if record_ok(record) then
        local info = (record.results or {}).bkpt or {}
        if not is_dict(info) then
          info = info[1] or {}
        end
        local number = as_int(info.number, 0)
        if number ~= 0 then
          numbers[#numbers + 1] = number
        end
        results[#results + 1] = { id = number, verified = true, line = as_int(info.line, 0) }
      else
        results[#results + 1] = { verified = false, message = record_error(record) }
      end
    end
  end
  self.breakpoints[key] = numbers
  self:send_response(request, { breakpoints = results })
end

function Adapter:on_setExceptionBreakpoints(request)
  self:send_response(request, { breakpoints = {} })
end

-- -- execution ------------------------------------------------------------------

function Adapter:_require_gdb()
  if not self.gdb or not self.gdb:is_alive() then
    error('no active gdb session')
  end
  return self.gdb
end

function Adapter:_thread_arg(request)
  local args = request.arguments or {}
  local tid = as_int(args.threadId, self.current_thread)
  return tid ~= 0 and tid or 1
end

function Adapter:on_continue(request)
  self:_require_gdb()
  local record = self:_continue_all()
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  self:send_response(request, { allThreadsContinued = true })
end

function Adapter:on_pause(request)
  local gdb = self:_require_gdb()
  local record = gdb:send('-exec-interrupt --all', 5)
  if not record_ok(record) then
    record = gdb:send('-exec-interrupt', 5)
  end
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  self:send_response(request)
end

function Adapter:_step(request, command)
  local gdb = self:_require_gdb()
  local record = gdb:send(string.format('%s --thread %d', command, self:_thread_arg(request)), 30)
  if not record_ok(record) then
    record = gdb:send(command, 30)
  end
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  self:send_response(request)
end

function Adapter:on_next(request)
  self:_step(request, '-exec-next')
end

function Adapter:on_stepIn(request)
  self:_step(request, '-exec-step')
end

function Adapter:on_stepOut(request)
  self:_step(request, '-exec-finish')
end

-- -- inspection ------------------------------------------------------------------

function Adapter:on_threads(request)
  if not self.gdb or not self.gdb:is_alive() then
    self:send_response(request, { threads = {} })
    return
  end
  local record = self.gdb:send('-thread-info', 15)
  if not record_ok(record) then
    self:send_response(request, { threads = { { id = self.current_thread, name = 'core' } } })
    return
  end
  local results = record.results or {}
  local threads = {}
  for _, entry in ipairs(as_list(results.threads)) do
    if is_dict(entry) then
      local tid = as_int(entry.id, 1)
      local name = entry.name or entry['target-id'] or ('thread ' .. tid)
      threads[#threads + 1] = { id = tid, name = tostring(name) }
    end
  end
  if #threads == 0 then
    threads = { { id = self.current_thread, name = 'core' } }
  end
  local current = results['current-thread-id']
  if current ~= nil then
    self.current_thread = as_int(current, self.current_thread)
  end
  table.sort(threads, function(a, b)
    return a.id < b.id
  end)
  self:send_response(request, { threads = threads })
end

function Adapter:_new_handle(descriptor)
  self.handle_seq = self.handle_seq + 1
  self.handles[self.handle_seq] = descriptor
  return self.handle_seq
end

function Adapter:on_stackTrace(request)
  local gdb = self:_require_gdb()
  local args = request.arguments or {}
  local thread_id = as_int(args.threadId, self.current_thread)
  if thread_id == 0 then
    thread_id = 1
  end
  local start = as_int(args.startFrame, 0)
  local levels = as_int(args.levels, 0)
  local command = string.format('-stack-list-frames --thread %d', thread_id)
  if levels > 0 then
    command = command .. string.format(' %d %d', start, start + levels - 1)
  end
  local record = gdb:send(command, 20)
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  local frames = {}
  for _, frame in ipairs(as_list((record.results or {}).stack)) do
    if is_dict(frame) then
      local level = as_int(frame.level, 0)
      local frame_id = self:_new_handle({ kind = 'frame', thread = thread_id, level = level })
      local entry = {
        id = frame_id,
        name = tostring(frame.func or frame.addr or '??'),
        line = as_int(frame.line, 0),
        column = 0,
        instructionPointerReference = tostring(frame.addr or ''),
      }
      local fullname = frame.fullname or frame.file
      if fullname and fullname ~= '' then
        entry.source = { name = basename(fullname), path = tostring(fullname) }
      end
      frames[#frames + 1] = entry
    end
  end
  self:send_response(request, { stackFrames = frames, totalFrames = #frames + start })
end

function Adapter:on_scopes(request)
  local args = request.arguments or {}
  local frame_id = as_int(args.frameId, 0)
  local frame = self.handles[frame_id]
  if not frame or frame.kind ~= 'frame' then
    self:send_response(request, { scopes = {} })
    return
  end
  local locals_ref = self:_new_handle({ kind = 'locals', thread = frame.thread, level = frame.level })
  local registers_ref = self:_new_handle({ kind = 'registers', thread = frame.thread, level = frame.level })
  self:send_response(request, {
    scopes = {
      {
        name = 'Locals',
        variablesReference = locals_ref,
        expensive = false,
        presentationHint = 'locals',
      },
      {
        name = 'Registers',
        variablesReference = registers_ref,
        expensive = true,
        presentationHint = 'registers',
      },
    },
  })
end

---@return table|nil { varobj, numchild, value, type }
function Adapter:_create_varobj(thread, level, expression)
  local record = self.gdb:send(
    string.format('-var-create --thread %d --frame %d - * %s', thread, level, mi_quote(expression)),
    20
  )
  if not record_ok(record) then
    return nil
  end
  local results = record.results or {}
  local name = results.name
  if not name or name == '' then
    return nil
  end
  self.varobjs[tostring(name)] = expression
  return {
    varobj = tostring(name),
    numchild = as_int(results.numchild, 0),
    value = tostring(results.value or ''),
    type = tostring(results.type or ''),
  }
end

function Adapter:_variable_entry(opts)
  local entry = {
    name = tostring(opts.name),
    value = tostring(opts.value == nil and '' or opts.value),
    variablesReference = 0,
    evaluateName = tostring(opts.expression or opts.name),
  }
  if opts.type and opts.type ~= '' then
    entry.type = tostring(opts.type)
  end
  if opts.numchild and opts.numchild > 0 and opts.varobj then
    entry.variablesReference = self:_new_handle({
      kind = 'varobj',
      varobj = opts.varobj,
      thread = opts.thread,
      level = opts.level,
      expression = opts.expression or opts.name,
    })
  end
  return entry
end

function Adapter:on_variables(request)
  self:_require_gdb()
  local args = request.arguments or {}
  local ref = as_int(args.variablesReference, 0)
  local handle = self.handles[ref]
  if not handle then
    self:send_response(request, { variables = {} })
    return
  end
  local variables
  if handle.kind == 'locals' then
    variables = self:_locals_variables(handle)
  elseif handle.kind == 'registers' then
    variables = self:_register_variables(handle)
  elseif handle.kind == 'varobj' then
    variables = self:_varobj_children(handle)
  else
    variables = {}
  end
  self:send_response(request, { variables = variables })
end

function Adapter:_locals_variables(handle)
  local record = self.gdb:send(
    string.format('-stack-list-variables --thread %d --frame %d --simple-values', handle.thread, handle.level),
    20
  )
  if not record_ok(record) then
    return {}
  end
  local variables = {}
  for _, item in ipairs(as_list((record.results or {}).variables)) do
    if is_dict(item) then
      local name = tostring(item.name or '')
      if name ~= '' then
        local value = item.value
        local type_name = item.type or ''
        if value == nil then
          local created = self:_create_varobj(handle.thread, handle.level, name)
          if created then
            variables[#variables + 1] = self:_variable_entry({
              name = name,
              value = created.value,
              thread = handle.thread,
              level = handle.level,
              expression = name,
              numchild = created.numchild,
              type = type_name ~= '' and type_name or created.type,
              varobj = created.varobj,
            })
            goto continue
          end
          value = '<unavailable>'
        end
        variables[#variables + 1] = self:_variable_entry({
          name = name,
          value = value,
          thread = handle.thread,
          level = handle.level,
          expression = name,
          type = type_name,
        })
      end
    end
    ::continue::
  end
  return variables
end

function Adapter:_register_variables(handle)
  local names_record = self.gdb:send(string.format('-data-list-register-names --thread %d', handle.thread), 20)
  if not record_ok(names_record) then
    return {}
  end
  local names = as_list((names_record.results or {})['register-names'])
  local values_record = self.gdb:send(
    string.format('-data-list-register-values --thread %d --frame %d x', handle.thread, handle.level),
    20
  )
  if not record_ok(values_record) then
    return {}
  end
  local variables = {}
  for _, item in ipairs(as_list((values_record.results or {})['register-values'])) do
    if is_dict(item) then
      local index = as_int(item.number, -1)
      local name = names[index + 1]
      if name and name ~= '' then
        variables[#variables + 1] = {
          name = tostring(name),
          value = tostring(item.value or ''),
          variablesReference = 0,
          evaluateName = '$' .. tostring(name),
        }
      end
    end
  end
  return variables
end

function Adapter:_varobj_children(handle)
  local record = self.gdb:send('-var-list-children --all-values ' .. mi_quote(handle.varobj), 20)
  if not record_ok(record) then
    return {}
  end
  local children = (record.results or {}).children
  local variables = {}
  for _, child in ipairs(as_list(children)) do
    if is_dict(child) then
      local varobj = tostring(child.name or '')
      local display = tostring(child.exp or varobj)
      local numchild = as_int(child.numchild, 0)
      local parent_expression = handle.expression or ''
      local expression
      if display:sub(1, 1) == '[' then
        expression = parent_expression .. display
      elseif display:match('^%d+$') then
        expression = parent_expression .. '[' .. display .. ']'
      elseif display:sub(1, 1) == '*' then
        expression = display
      else
        local base = parent_expression
        if base:sub(1, 1) == '*' and base:sub(-1) ~= ')' then
          base = '(' .. base .. ')'
        end
        expression = string.format('%s.%s', base, display)
      end
      local entry = {
        name = display,
        value = tostring(child.value or ''),
        type = tostring(child.type or ''),
        variablesReference = 0,
        evaluateName = expression,
      }
      if numchild > 0 and varobj ~= '' then
        entry.variablesReference = self:_new_handle({
          kind = 'varobj',
          varobj = varobj,
          thread = handle.thread,
          level = handle.level,
          expression = expression,
        })
      end
      variables[#variables + 1] = entry
    end
  end
  return variables
end

function Adapter:on_evaluate(request)
  local gdb = self:_require_gdb()
  local args = request.arguments or {}
  local expression = vim.trim(tostring(args.expression or ''))
  local context = args.context or 'repl'
  local frame = self.handles[as_int(args.frameId, 0)] or {}
  local thread = frame.thread or self.current_thread
  local level = frame.level or 0

  if expression == '' then
    self:send_response(request, { result = '', variablesReference = 0 })
    return
  end

  if expression:sub(1, 6) == '-exec ' or expression:sub(1, 1) == '>' then
    local command = expression:sub(1, 6) == '-exec ' and expression:sub(7) or expression:sub(2)
    command = vim.trim(command)
    local record
    if command:sub(1, 1) == '-' then
      record = gdb:send(command, 60)
    else
      record = gdb:console_cmd(command, 60)
    end
    if not record_ok(record) then
      self:send_response(request, nil, false, record_error(record))
      return
    end
    self:send_response(request, { result = vim.trim(record.console or ''), variablesReference = 0 })
    return
  end

  if context == 'watch' or context == 'hover' or context == 'variables' then
    local created = self:_create_varobj(thread, level, expression)
    if created then
      local body = { result = created.value, variablesReference = 0 }
      if created.type ~= '' then
        body.type = created.type
      end
      if created.numchild > 0 then
        body.variablesReference = self:_new_handle({
          kind = 'varobj',
          varobj = created.varobj,
          thread = thread,
          level = level,
          expression = expression,
        })
      end
      -- `&expr` results carry the address; expose it for memory readers and
      -- the live-watch symbol resolver in the plugin.
      local addr = created.value:match('0[xX]%x+')
      if addr then
        body.memoryReference = addr
      end
      self:send_response(request, body)
      return
    end
  end

  local record = gdb:send(
    string.format('-data-evaluate-expression --thread %d --frame %d %s', thread, level, mi_quote(expression)),
    30
  )
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  local value = tostring((record.results or {}).value or '')
  local body = { result = value, variablesReference = 0 }
  local addr = value:match('0[xX]%x+')
  if addr then
    body.memoryReference = addr
  end
  self:send_response(request, body)
end

function Adapter:on_setVariable(request)
  local gdb = self:_require_gdb()
  local args = request.arguments or {}
  local handle = self.handles[as_int(args.variablesReference, 0)] or {}
  local thread = handle.thread or self.current_thread
  local level = handle.level or 0
  local name = tostring(args.name or '')
  if handle.kind == 'varobj' then
    name = string.format('%s.%s', handle.expression or '', name)
  end
  local value = tostring(args.value or '')
  local record = gdb:send(
    string.format(
      '-data-evaluate-expression --thread %d --frame %d %s',
      thread,
      level,
      mi_quote(string.format('%s = %s', name, value))
    ),
    30
  )
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  self:send_response(request, {
    value = tostring((record.results or {}).value or value),
    variablesReference = 0,
  })
end

function Adapter:on_readMemory(request)
  local gdb = self:_require_gdb()
  local args = request.arguments or {}
  local ref = tostring(args.memoryReference or '')
  local offset = as_int(args.offset, 0)
  local count = as_int(args.count, 0)
  if ref == '' or count <= 0 then
    self:send_response(request, { address = ref, data = '' })
    return
  end
  local record = gdb:send(
    string.format('-data-read-memory-bytes %s %d', mi_quote(string.format('(%s)+%d', ref, offset)), count),
    20
  )
  if not record_ok(record) then
    self:send_response(request, nil, false, record_error(record))
    return
  end
  local memory = as_list((record.results or {}).memory)
  local chunk = memory[1]
  local contents = is_dict(chunk) and tostring(chunk.contents or '') or ''
  local bytes = {}
  for pair in contents:gmatch('%x%x') do
    bytes[#bytes + 1] = string.char(tonumber(pair, 16))
  end
  self:send_response(request, {
    address = is_dict(chunk) and tostring(chunk.begin or ref) or ref,
    data = vim.base64 and vim.base64.encode(table.concat(bytes)) or '',
  })
end

M.Adapter = Adapter

----------------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------------

---Run the adapter until stdin closes or the client disconnects.
---@param opts table|nil
---@return integer exit code
function M.main(opts)
  opts = opts or {}
  log_init()
  log('cortex-debug lua adapter starting; nvim', tostring(vim.version()))

  local adapter = Adapter.new()

  local stdin_pipe = uv.new_pipe(false)
  stdin_pipe:open(0)
  local stdout_pipe = uv.new_pipe(false)
  stdout_pipe:open(1)
  adapter.stdout_pipe = stdout_pipe

  stdin_pipe:read_start(function(err, chunk)
    if err then
      log('stdin error:', tostring(err))
      chunk = nil
    end
    if not chunk then
      log('stdin EOF')
      pcall(function()
        stdin_pipe:read_stop()
      end)
      spawn_task(function()
        adapter:_teardown(not adapter.is_attach)
        adapter:shutdown()
      end)
      return
    end
    local messages, ferr = adapter.reader:feed(chunk)
    if ferr then
      log('framing error:', ferr)
    end
    for _, message in ipairs(messages) do
      local ok, herr = pcall(function()
        adapter:handle_message(message)
      end)
      if not ok then
        log('dispatch error:', tostring(herr))
      end
    end
  end)

  -- Keep the libuv loop running until the session is over.
  local limit = tonumber(opts.timeout) or (24 * 60 * 60 * 1000)
  vim.wait(limit, function()
    return adapter.done
  end, 20)

  log('cortex-debug lua adapter exiting')
  if log_file then
    log_file:close()
  end
  return 0
end

return M
