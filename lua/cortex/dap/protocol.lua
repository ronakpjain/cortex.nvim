-- DAP message encoding and incremental Content-Length framing.
local M = {}

---@param message table
---@return string
function M.encode_message(message)
  local body = vim.json.encode(message)
  return string.format('Content-Length: %d\r\n\r\n%s', #body, body)
end

---Incremental Content-Length framed DAP message reader.
---@class cortex.dap.Reader
local Reader = {}
Reader.__index = Reader

---@param log fun(...: any)|nil
function Reader.new(log)
  return setmetatable({ buf = '', log = log }, Reader)
end

---Feed raw bytes and return all complete decoded messages.
---@param chunk string
---@return table[] messages, string|nil err
function Reader:feed(chunk)
  self.buf = self.buf .. chunk
  local messages = {}
  while true do
    local header_end = self.buf:find('\r\n\r\n', 1, true)
    local separator_length = 4
    if not header_end then
      header_end = self.buf:find('\n\n', 1, true)
      separator_length = 2
    end
    if not header_end then
      return messages, nil
    end

    local header = self.buf:sub(1, header_end - 1)
    local length
    for line in header:gmatch('[^\r\n]+') do
      local name, value = line:match('^([^:]+):%s*(.*)$')
      if name and name:lower() == 'content-length' then
        length = tonumber(vim.trim(value))
      end
    end
    if not length or length < 0 or length ~= math.floor(length) then
      -- A missing body boundary cannot be recovered from the current buffer.
      self.buf = ''
      local err = length == nil and 'missing Content-Length header' or 'invalid Content-Length header'
      return messages, err
    end

    local body_start = header_end + separator_length
    if #self.buf < body_start + length - 1 then
      return messages, nil
    end
    local body = self.buf:sub(body_start, body_start + length - 1)
    self.buf = self.buf:sub(body_start + length)
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if ok then
      messages[#messages + 1] = decoded
    elseif self.log then
      self.log('json decode error:', tostring(decoded))
    end
  end
end

M.Reader = Reader

return M
