local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local target = require('cortex.target')
local checks, failures = 0, 0
local function check(name, condition)
  checks = checks + 1
  if condition then
    io.write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.write('not ok ' .. name .. '\n')
  end
end

local old_cwd = vim.fn.getcwd()
local old_dap = package.loaded.dap
local old_vscode = package.loaded['dap.ext.vscode']
local old_preload = package.preload['dap.ext.vscode']
local old_select = vim.ui.select
local storage = target._storage_path()
local storage_exists = vim.fn.filereadable(storage) == 1
local storage_lines = storage_exists and vim.fn.readfile(storage) or nil

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/.vscode', 'p')
vim.fn.writefile({ '{"configurations": []}' }, tmp .. '/.vscode/launch.json')
vim.fn.chdir(tmp)

local configs = {
  { name = 'first', type = 'cortex-debug', request = 'launch' },
  { name = 'second', type = 'cortex-debug', request = 'attach' },
}
local run_config
local dap = {
  configurations = {},
  session = function()
    return nil
  end,
  run = function(config)
    run_config = config
  end,
  continue = function() end,
}
package.loaded.dap = dap
package.preload['dap.ext.vscode'] = function()
  return {
    getconfigs = function()
      return configs
    end,
  }
end
package.loaded['dap.ext.vscode'] = nil
vim.ui.select = function(items, _, callback)
  callback(items[2])
end
target._state.store = nil

target.select()
check('selection is remembered', target._state.selected and target._state.selected.name == 'second')
check(
  'selection is stored outside workspace',
  vim.fn.filereadable(storage) == 1 and vim.fn.filereadable(tmp .. '/targets.json') == 0
)
run_config = nil
target.start()
check('saved target starts without another picker', run_config and run_config.name == 'second')

target.clear()
check('target can be cleared', target._state.selected == nil)

vim.ui.select = old_select
vim.fn.chdir(old_cwd)
vim.fn.delete(tmp, 'rf')
if storage_exists then
  vim.fn.writefile(storage_lines, storage)
else
  vim.fn.delete(storage)
end
package.loaded.dap = old_dap
package.loaded['dap.ext.vscode'] = old_vscode
package.preload['dap.ext.vscode'] = old_preload
target._state.store = nil

io.write(string.format('%d/%d target checks passed\n', checks - failures, checks))
if failures > 0 then
  os.exit(1)
end
