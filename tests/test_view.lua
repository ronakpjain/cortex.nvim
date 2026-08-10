-- Headless lifecycle checks for the shared auxiliary-view abstraction.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local view = require('cortex.view')
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

local state = { bufnr = nil, winid = nil, element_mode = false }
local pane = view.new(state, {
  name = 'cortex://view-test',
  filetype = 'cortex-view-test',
  title = 'View Test',
  element_title = 'Cortex View Test',
  element = 'cortex_view_test',
  float_width = 45,
  float_height = 9,
  window = {
    position = 'right',
    width = 24,
    height = 6,
    border = 'single',
    focus_on_open = false,
    min_width = 10,
  },
})

check('new view starts invalid', not pane:buf_valid() and not pane:win_valid())
local bufnr, created = pane:buffer()
check('buffer is created into shared state', created and state.bufnr == bufnr and pane:buf_valid())
check(
  'scratch buffer options are configured',
  vim.bo[bufnr].buftype == 'nofile'
    and vim.bo[bufnr].bufhidden == 'hide'
    and not vim.bo[bufnr].swapfile
    and not vim.bo[bufnr].modifiable
    and vim.bo[bufnr].filetype == 'cortex-view-test'
)
local same, recreated = pane:buffer()
check('buffer creation is idempotent', same == bufnr and not recreated)

local original = vim.api.nvim_get_current_win()
local float = pane:open({ position = 'float', width = 31, height = 7 })
local float_config = vim.api.nvim_win_get_config(float)
check(
  'float opens with merged overrides',
  float_config.relative == 'editor' and float_config.width == 31 and float_config.height == 7
)
check(
  'float uses configured border',
  vim.deep_equal(float_config.border, { '┌', '─', '┐', '│', '┘', '─', '└', '│' })
)
check('focus is restored by default', vim.api.nvim_get_current_win() == original)
check(
  'window options are normalized',
  not vim.wo[float].number
    and not vim.wo[float].relativenumber
    and not vim.wo[float].wrap
    and vim.wo[float].signcolumn == 'no'
)
check('standalone window lookup works', pane:window() == float)
check('close clears standalone window state', pane:close() and state.winid == nil and not pane:win_valid())

local action = pane:toggle({ position = 'bottom', height = 4, focus_on_open = true })
check(
  'toggle opens and honors focus configuration',
  action == 'opened' and vim.api.nvim_get_current_win() == state.winid
)
check('toggle closes standalone window', pane:toggle() == 'closed' and state.winid == nil)
local feature_closes = 0
check('buffer close delegates to the feature in standalone mode', pane:close_from_buffer(function()
  feature_closes = feature_closes + 1
end) == 'standalone' and feature_closes == 1)

local render = function() end
local buffer_calls = 0
local function configured_buffer()
  buffer_calls = buffer_calls + 1
  local configured = pane:buffer()
  return configured
end
local element = pane:element(render, configured_buffer)
local defaults = element.float_defaults()
check('element mode is registered in shared state', state.element_mode and element.allow_without_session)
check(
  'element exposes the configured buffer and renderer',
  element.buffer() == bufnr and buffer_calls == 1 and element.render == render
)
check(
  'element float defaults are configured',
  defaults.width == 45 and defaults.height == 9 and defaults.enter and defaults.title == 'Cortex View Test'
)

local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, other)
check('element lookup ignores unrelated current windows', pane:window() == nil)
vim.api.nvim_win_set_buf(0, bufnr)
check('element lookup finds its current dap-ui window', pane:window() == vim.api.nvim_get_current_win())

local floated, dapui_closes
package.loaded.dapui = {
  float_element = function(name, options)
    floated = { name = name, options = options }
  end,
  close = function()
    dapui_closes = (dapui_closes or 0) + 1
  end,
}
check('element toggle delegates to dap-ui', pane:toggle() == 'element')
check(
  'dap-ui float receives element configuration',
  floated
    and floated.name == 'cortex_view_test'
    and floated.options.width == 45
    and floated.options.height == 9
    and floated.options.enter
)
check('buffer close delegates to dap-ui in element mode', pane:close_from_buffer(function()
  feature_closes = feature_closes + 1
end) == 'element' and dapui_closes == 1 and feature_closes == 1)
package.loaded.dapui = nil

vim.api.nvim_buf_delete(bufnr, { force = true })
local replacement = element.buffer()
check(
  'element provider recreates invalid buffers',
  buffer_calls == 2 and replacement ~= bufnr and state.bufnr == replacement
)
state.element_mode = false
vim.api.nvim_buf_delete(replacement, { force = true })
if vim.api.nvim_buf_is_valid(other) then
  vim.api.nvim_buf_delete(other, { force = true })
end

io.write(string.format('%d/%d view checks passed\n', checks - failures, checks))
if failures > 0 then
  os.exit(1)
end
