-- Headless tests for the shared Cortex UI helpers.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local ui = require('cortex.ui')
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

local function status_is(name, status, variant, expected_icon, expected_group)
  local icon, group = ui.status_icon(status, variant)
  check(name, icon == expected_icon and group == expected_group)
end

status_is('error status', 'refresh failed', nil, '✖', 'CortexError')
status_is('running status', 'target running', nil, '▶', 'CortexWarn')
status_is('refreshing status', 'refreshing', nil, '◌', 'CortexWarn')
status_is('neutral status', 'stopped', nil, '●', 'CortexSuccess')
status_is('live watch connected status', 'connected', 'live_watch', '●', 'CortexSuccess')
status_is('live watch connecting status', 'connecting', 'live_watch', '◌', 'CortexWarn')
status_is('live watch stopped status', 'stopped', 'live_watch', '·', 'CortexDim')

check('short text is unchanged', ui.truncate('abc', 4) == 'abc')
check('ASCII truncation includes ellipsis', ui.truncate('abcdef', 4) == 'abc…')
check('multibyte text is not split', ui.truncate('ééé', 2) == 'é…')
check('wide text respects display width', ui.truncate('界界界', 4) == '界…')
check('wide truncation fits requested cells', vim.fn.strdisplaywidth(ui.truncate('界界界', 4)) <= 4)
check('one-cell truncation is an ellipsis', ui.truncate('wide', 1) == '…')

-- Force render clipping and spy on the real highlight API. This verifies that
-- ranges computed for pre-clipped text are normalized before reaching Neovim.
local bufnr = vim.api.nvim_create_buf(false, true)
local original_width = ui.width
local original_add_highlight = vim.api.nvim_buf_add_highlight
local calls = {}
ui.width = function()
  return 4
end
vim.api.nvim_buf_add_highlight = function(buffer, namespace, group, line, start, finish)
  calls[#calls + 1] = {
    buffer = buffer,
    namespace = namespace,
    group = group,
    line = line,
    start = start,
    finish = finish,
  }
  return original_add_highlight(buffer, namespace, group, line, start, finish)
end

local render_ok, render_error = pcall(ui.render, bufnr, { 'abcdef', 'xy' }, {
  { line = 1, group = 'CortexName', start = 2, finish = 50 }, -- clamp end after clipping
  { line = 2, group = 'CortexValue', start = -7, finish = 1 }, -- clamp negative start
  { line = 1, group = 'CortexError', start = 100, finish = 101 }, -- drop start past EOL
  { line = 3, group = 'CortexError', start = 0, finish = 1 }, -- drop missing line
  { line = 2, group = 'CortexError', start = 1, finish = -2 }, -- drop empty clamped range
  { line = 2, group = 'CortexDim' }, -- retain whole-line sentinel
})
vim.api.nvim_buf_add_highlight = original_add_highlight
ui.width = original_width

check('render safely handles invalid highlight ranges', render_ok)
if not render_ok then
  io.write('     ' .. tostring(render_error) .. '\n')
end
local rendered = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check('render clips by display width', rendered[1] == 'abc…')
check('render drops invalid marks', #calls == 3)
check(
  'render clamps finish to clipped byte length',
  calls[1] and calls[1].line == 0 and calls[1].start == 2 and calls[1].finish == #'abc…'
)
check(
  'render clamps negative byte start',
  calls[2] and calls[2].line == 1 and calls[2].start == 0 and calls[2].finish == 1
)
check('render preserves whole-line range', calls[3] and calls[3].start == 0 and calls[3].finish == -1)
vim.api.nvim_buf_delete(bufnr, { force = true })

io.write(string.format('%d/%d UI checks passed\n', checks - failures, checks))
if failures > 0 then
  os.exit(1)
end
