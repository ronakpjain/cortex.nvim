-- Shared normalization for setup and launch configuration.
local M = {}

function M.get(value, key)
  return type(value) == 'table' and value[key] or nil
end

function M.first(value, keys)
  for _, key in ipairs(keys) do
    local found = M.get(value, key)
    if found ~= nil then
      return found
    end
  end
end

---Merge setup and launch configuration, then normalize launch-only aliases.
---@param defaults table
---@param setup table|nil
---@param launch table|nil
---@param aliases table<string, string>|nil snake_case to camelCase
---@return table
function M.merge(defaults, setup, launch, aliases)
  setup = type(setup) == 'table' and setup or {}
  launch = type(launch) == 'table' and launch or {}
  local result = vim.tbl_deep_extend('force', vim.deepcopy(defaults), setup, launch)
  for canonical, alias in pairs(aliases or {}) do
    if launch[canonical] == nil and launch[alias] ~= nil then
      result[canonical] = launch[alias]
    end
  end
  return result
end

return M
