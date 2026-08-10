-- Parser for GDB/MI result, async, stream, and prompt records.
local M = {}

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

---Parse a GDB/MI C-string starting at `text:sub(index, index) == '"'`.
---@param text string
---@param index integer|nil 1-based
---@return string value, integer next_index
function M.parse_c_string(text, index)
  index = index or 1
  if text:sub(index, index) ~= '"' then
    error(string.format("expected '\"' at position %d in %q", index, text))
  end
  index = index + 1
  local out = {}
  local length = #text
  while index <= length do
    local char = text:sub(index, index)
    if char == '"' then
      return table.concat(out), index + 1
    end
    if char ~= '\\' then
      out[#out + 1] = char
      index = index + 1
    else
      index = index + 1
      if index > length then
        break
      end
      local escape = text:sub(index, index)
      if C_ESCAPES[escape] then
        out[#out + 1] = C_ESCAPES[escape]
        index = index + 1
      elseif escape == 'x' then
        index = index + 1
        local digits = text:match('^%x%x?', index) or ''
        index = index + #digits
        out[#out + 1] = #digits > 0 and string.char(tonumber(digits, 16) % 256) or 'x'
      elseif escape:match('%d') then
        local digits = text:match('^[0-7][0-7]?[0-7]?', index) or ''
        index = index + #digits
        out[#out + 1] = string.char(tonumber(digits, 8) % 256)
      else
        out[#out + 1] = escape
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

function parse_mi_value(text, index)
  index = skip_ws(text, index or 1)
  if index > #text then
    error(string.format('unexpected end of MI value in %q', text))
  end
  local char = text:sub(index, index)
  if char == '"' then
    return M.parse_c_string(text, index)
  elseif char == '{' then
    return parse_mi_tuple(text, index)
  elseif char == '[' then
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
    local char = text:sub(index, index)
    if char == ',' then
      index = index + 1
    elseif char == '}' then
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
    local char = text:sub(index, index)
    if char == ',' then
      index = index + 1
    elseif char == ']' then
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
  local char = text:sub(index, index)
  if char == '"' or char == '{' or char == '[' then
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

---Parse a comma-separated GDB/MI result list into a table.
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
---Result and async records contain `token`, `class`, and `results`; stream
---records contain `stream` and `output`.
---@param line string|nil
---@param log fun(...: any)|nil
---@return table
function M.parse_mi_line(line, log)
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
  local index = skip_ws(rest, #class_name + 1)
  if rest:sub(index, index) == ',' then
    index = index + 1
  end
  local ok, results = pcall(M.parse_mi_results, rest, index)
  if not ok then
    if log then
      log('MI parse error:', tostring(results), 'line:', line)
    end
    results = {}
  end

  return {
    type = kind == '^' and 'result' or ASYNC_KINDS[kind],
    token = token,
    class = class_name,
    results = results,
  }
end

return M
