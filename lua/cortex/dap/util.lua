-- Adapter value, path, and launch-variable helpers.
local uv = vim.uv or vim.loop

local M = {}

---@param value any
---@return table
function M.as_list(value)
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

---@param value any
---@param default integer|nil
---@return integer
function M.as_int(value, default)
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

---@param text any
---@return string
function M.mi_quote(text)
  local s = tostring(text)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
  return '"' .. s .. '"'
end

function M.is_dict(value)
  return type(value) == 'table' and next(value) ~= nil and value[1] == nil
end

function M.basename(path)
  return (tostring(path):gsub('.*/', ''))
end

function M.dirname(path)
  local dir = tostring(path):match('^(.*)/[^/]*$')
  return dir or ''
end

function M.expanduser(path)
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

function M.is_abs(path)
  return tostring(path):sub(1, 1) == '/'
end

function M.normalize(path)
  path = tostring(path):gsub('/+', '/')
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' and #parts > 0 and parts[#parts] ~= '..' then
      table.remove(parts)
    elseif part ~= '.' then
      parts[#parts + 1] = part
    end
  end
  local out = table.concat(parts, '/')
  if M.is_abs(path) then
    out = '/' .. out
  end
  return out
end

function M.join(a, b)
  if b == nil or b == '' then
    return a
  end
  if M.is_abs(b) then
    return M.normalize(b)
  end
  return M.normalize(a .. '/' .. b)
end

function M.file_exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param config table
---@param cwd string|nil
---@return table
function M.build_variable_table(config, cwd)
  config = config or {}
  local workspace = config.workspaceRoot
    or config.workspaceroot
    or config.workspaceFolder
    or config.workspacefolder
    or config.cwd
    or cwd
    or uv.cwd()
  workspace = tostring(workspace)
  -- Older nvim-dap versions can pass workspace placeholders through.
  local workspace_placeholder = workspace:lower()
  if
    workspace_placeholder == '${workspaceroot}'
    or workspace_placeholder == '${workspacefolder}'
    or workspace_placeholder == '${cwd}'
  then
    workspace = cwd or uv.cwd()
  end
  workspace = M.normalize(M.expanduser(workspace))
  if not M.is_abs(workspace) then
    workspace = M.join(uv.cwd(), workspace)
  end
  local variables = {
    workspaceRoot = workspace,
    workspaceFolder = workspace,
    workspaceroot = workspace,
    workspacefolder = workspace,
    cwd = workspace,
    userHome = os.getenv('HOME') or '',
    pathSeparator = '/',
  }
  local current_file = config.file or os.getenv('CORTEX_CURRENT_FILE')
  if current_file and current_file ~= '' then
    current_file = M.normalize(M.expanduser(tostring(current_file)))
    variables.file = current_file
    variables.fileDirname = M.dirname(current_file)
    variables.fileBasename = M.basename(current_file)
    variables.fileBasenameNoExtension = (M.basename(current_file):gsub('%.[^.]*$', ''))
  end
  return variables
end

---Recursively expand `${name}` placeholders in strings, lists, and dictionaries.
---@param value any
---@param variables table
---@return any
function M.expand_variables(value, variables)
  if type(value) == 'string' then
    return (
      value:gsub('%${([A-Za-z_][A-Za-z0-9_]*)}', function(key)
        local replacement = variables[key]
        if replacement == nil then
          return '${' .. key .. '}'
        end
        return tostring(replacement)
      end)
    )
  end
  if type(value) == 'table' then
    local out = {}
    for key, child in pairs(value) do
      out[key] = M.expand_variables(child, variables)
    end
    return out
  end
  return value
end

return M
