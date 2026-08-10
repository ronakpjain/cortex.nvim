-- Persistent nvim-dap launch-target selection.
--
-- The selected target is stored by workspace and resolved again from the
-- current launch.json each time, so changes to the configuration are picked
-- up without storing executable paths or stale DAP state.
local P = {}
local state = {
  store = nil,
  selected = nil,
  root = nil,
}
P._state = state

local function notify(message, level)
  vim.notify('[cortex.nvim] ' .. message, level or vim.log.levels.INFO)
end

local function canonical(path)
  local result = vim.fn.fnamemodify(path, ':p')
  if result ~= '/' then
    result = result:gsub('/+$', '')
  end
  return result
end

local function project()
  local path = canonical(vim.fn.getcwd())
  while path and path ~= '' do
    local launch = path .. '/.vscode/launch.json'
    if vim.fn.filereadable(launch) == 1 then
      return path, launch
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
      break
    end
    path = parent
  end
  return nil, nil
end

local function storage_path()
  local root = vim.fn.stdpath('state')
  if root == '' then
    root = vim.fn.stdpath('data')
  end
  return root .. '/cortex.nvim/targets.json'
end

local function decode(text)
  local decoder = vim.json and vim.json.decode or vim.fn.json_decode
  local ok, value = pcall(decoder, text)
  return ok and type(value) == 'table' and value or {}
end

local function encode(value)
  local encoder = vim.json and vim.json.encode or vim.fn.json_encode
  local ok, text = pcall(encoder, value)
  return ok and text or nil
end

local function load_store()
  if state.store then
    return state.store
  end
  state.store = {}
  local path = storage_path()
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    state.store = decode(table.concat(lines, '\n'))
  end
  return state.store
end

local function save_store()
  local text = encode(load_store())
  if not text then
    notify('could not encode the selected debug target', vim.log.levels.ERROR)
    return false
  end
  local path = storage_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local ok = vim.fn.writefile({ text }, path) == 0
  if not ok then
    notify('could not save the selected debug target', vim.log.levels.ERROR)
  end
  return ok
end

local function dap()
  local ok, value = pcall(require, 'dap')
  if not ok or not value then
    notify('nvim-dap is not available', vim.log.levels.ERROR)
    return nil
  end
  return value
end

local function add_config(configs, seen, config)
  if type(config) ~= 'table' or not config.name then
    return
  end
  local key = tostring(config.type or '') .. '\0' .. tostring(config.name)
  if seen[key] then
    return
  end
  seen[key] = true
  configs[#configs + 1] = config
end

local function configs_for(_, launch_path)
  local d = dap()
  if not d then
    return nil, nil
  end
  local configs, seen = {}, {}
  local ok_vscode, vscode = pcall(require, 'dap.ext.vscode')
  if ok_vscode then
    local ok_configs, launch_configs = pcall(vscode.getconfigs, launch_path)
    if ok_configs and type(launch_configs) == 'table' then
      for _, config in ipairs(launch_configs) do
        add_config(configs, seen, config)
      end
    end
  end
  local filetype_configs = d.configurations[vim.bo.filetype] or {}
  for _, config in ipairs(filetype_configs) do
    add_config(configs, seen, config)
  end
  if #configs == 0 and launch_path then
    return configs, 'no debug configurations found in ' .. launch_path
  end
  return configs, nil
end

local function saved(root)
  local value = load_store()[root]
  if type(value) == 'string' then
    return { name = value }
  end
  return type(value) == 'table' and value or nil
end

local function remember(root, config)
  local value = { name = tostring(config.name), type = config.type and tostring(config.type) or nil }
  load_store()[root] = value
  state.root, state.selected = root, value
  save_store()
end

local function match(configs, selection)
  if not selection then
    return nil
  end
  for _, config in ipairs(configs) do
    if config.name == selection.name and (not selection.type or config.type == selection.type) then
      return config
    end
  end
  return nil
end

local function format_item(config)
  return string.format(
    '%s  [%s / %s]',
    tostring(config.name),
    tostring(config.type or '?'),
    tostring(config.request or 'launch')
  )
end

P._project = project
P._storage_path = storage_path
P._configs_for = configs_for
P._match = match

---Select and persist a launch configuration for the current workspace.
---@param callback fun(config: table|nil)|nil
function P.select(callback)
  local root, launch_path = project()
  if not root then
    notify('no .vscode/launch.json found from the current directory', vim.log.levels.ERROR)
    if callback then
      callback(nil)
    end
    return nil
  end
  local configs, err = configs_for(root, launch_path)
  if not configs or #configs == 0 then
    notify(err or 'no debug targets found', vim.log.levels.ERROR)
    if callback then
      callback(nil)
    end
    return nil
  end
  local current = saved(root)
  local prompt = 'Debug target'
  if current then
    prompt = prompt .. ' (current: ' .. tostring(current.name) .. ')'
  end
  vim.ui.select(configs, { prompt = prompt, format_item = format_item }, function(config)
    if not config then
      if callback then
        callback(nil)
      end
      return
    end
    remember(root, config)
    notify('selected debug target: ' .. tostring(config.name))
    if callback then
      callback(config)
    end
  end)
  return true
end

---Start the saved target, or prompt once when no target has been selected.
function P.start()
  local d = dap()
  if not d then
    return nil
  end
  if d.session() then
    return d.continue()
  end
  local root, launch_path = project()
  if not root then
    notify('no .vscode/launch.json found from the current directory', vim.log.levels.ERROR)
    return nil
  end
  local configs, err = configs_for(root, launch_path)
  if not configs or #configs == 0 then
    notify(err or 'no debug targets found', vim.log.levels.ERROR)
    return nil
  end
  local config = match(configs, saved(root))
  if config then
    state.root = root
    state.selected = saved(root)
    return d.run(config)
  end
  if saved(root) then
    notify('saved debug target is unavailable; choose a new target', vim.log.levels.WARN)
  end
  return P.select(function(selected)
    if selected then
      d.run(selected)
    end
  end)
end

function P.clear()
  local root = project()
  if not root then
    notify('no .vscode/launch.json found from the current directory', vim.log.levels.ERROR)
    return nil
  end
  load_store()[root] = nil
  state.root, state.selected = root, nil
  save_store()
  notify('cleared the saved debug target')
end

function P.status()
  local root = project()
  local selection = root and saved(root) or nil
  if selection then
    notify('saved debug target: ' .. tostring(selection.name))
  else
    notify('no debug target selected')
  end
  return selection
end

function P.setup(_)
  return P
end

return P
