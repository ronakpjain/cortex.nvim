-- Small UI helpers shared by Cortex's auxiliary windows.
local api = vim.api

local M = {}

---Move the cursor to the Neovim mouse event and focus the target window.
---@param winid integer
---@return integer|nil line 1-based buffer line
function M.mouse_line(winid)
  if not winid or not api.nvim_win_is_valid(winid) then return nil end
  local position = vim.fn.getmousepos()
  if position.winid and position.winid ~= 0 and position.winid ~= winid then return nil end
  local line = tonumber(position.line)
  if not line then return nil end
  local bufnr = api.nvim_win_get_buf(winid)
  local count = api.nvim_buf_line_count(bufnr)
  line = math.max(1, math.min(line, count))
  local column = math.max(0, (tonumber(position.column) or 1) - 1)
  api.nvim_set_current_win(winid)
  api.nvim_win_set_cursor(winid, { line, column })
  return line
end

return M
