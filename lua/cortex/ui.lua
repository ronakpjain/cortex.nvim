-- Small UI helpers shared by Cortex's auxiliary windows.
local api = vim.api

local M = {}

---@class CortexHighlight
---@field line integer 1-based buffer line
---@field group string highlight group name
---@field start? integer inclusive 0-based byte column (defaults to 0)
---@field finish? integer exclusive 0-based byte column, or -1 for end-of-line

---@alias CortexStatusVariant 'default'|'live_watch'

M.namespace = api.nvim_create_namespace('cortex-ui')

-- Use linked built-in groups so the views follow the user's colorscheme while
-- still having a consistent visual language across every Cortex buffer.
local highlight_links = {
  CortexTitle = 'Title',
  CortexHeader = 'Special',
  CortexSeparator = 'WinSeparator',
  CortexDim = 'Comment',
  CortexName = 'Identifier',
  CortexAddress = 'Number',
  CortexValue = 'String',
  CortexSuccess = 'DiagnosticOk',
  CortexWarn = 'DiagnosticWarn',
  CortexError = 'DiagnosticError',
  CortexCurrent = 'CursorLine',
}

for group, link in pairs(highlight_links) do
  pcall(api.nvim_set_hl, 0, group, { default = true, link = link })
end

---Map a view status to its icon and highlight group.
---The live-watch variant distinguishes connected/connecting/stopped states;
---other Cortex views treat an otherwise neutral status as successful.
---@param status any
---@param variant? CortexStatusVariant
---@return string icon
---@return string highlight_group
function M.status_icon(status, variant)
  local normalized = tostring(status or ''):lower()
  if normalized:find('error', 1, true) or normalized:find('failed', 1, true) then
    return '✖', 'CortexError'
  end

  if variant == 'live_watch' then
    -- Test the complete state before the substring: "connected" also contains
    -- "connect", but is no longer pending.
    if normalized == 'connected' then
      return '●', 'CortexSuccess'
    end
    if normalized:find('connect', 1, true) then
      return '◌', 'CortexWarn'
    end
    return '·', 'CortexDim'
  end

  if normalized:find('running', 1, true) then
    return '▶', 'CortexWarn'
  end
  if normalized:find('refresh', 1, true) or normalized:find('loading', 1, true) then
    return '◌', 'CortexWarn'
  end
  return '●', 'CortexSuccess'
end

---Render lines and byte-range highlights into a Cortex buffer.
---@param bufnr integer
---@param lines string[]
---@param highlights? CortexHighlight[]
function M.render(bufnr, lines, highlights)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- A view can be rendered once before DAP-UI places its buffer in a window.
  -- When it is already visible, cap every line here as a final safety net so
  -- a transiently narrow pane never lets a title/row spill into its neighbor.
  local window_width = M.width(bufnr)
  if window_width then
    local clipped = {}
    for index, line in ipairs(lines) do
      clipped[index] = M.truncate(line, window_width)
    end
    lines = clipped
  end
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
  for _, mark in ipairs(highlights or {}) do
    local line_number = tonumber(mark.line)
    if
      line_number
      and line_number == math.floor(line_number)
      and line_number >= 1
      and line_number <= #lines
      and type(mark.group) == 'string'
      and mark.group ~= ''
    then
      local line_length = #lines[line_number]
      local start = tonumber(mark.start) or 0
      if start == start then
        start = math.max(0, math.floor(start))
        if start <= line_length then
          local finish = mark.finish == nil and -1 or tonumber(mark.finish)
          if finish and finish == finish then
            finish = math.floor(finish)
            if finish ~= -1 then
              finish = math.max(0, math.min(finish, line_length))
            end
            -- A non-sentinel end at/before the start is an empty range. Drop
            -- it rather than forwarding an invalid or ineffective mark.
            if finish == -1 or finish > start then
              api.nvim_buf_add_highlight(bufnr, M.namespace, mark.group, line_number - 1, start, finish)
            end
          end
        end
      end
    end
  end
end

---Add a whole-line highlight entry to a render highlight list.
---@param highlights CortexHighlight[]
---@param line integer
---@param group string
function M.highlight_line(highlights, line, group)
  highlights[#highlights + 1] = { line = line, group = group }
end

---Return the width of a window displaying a buffer, if it is currently open.
---@param bufnr integer
---@param fallback? integer
---@return integer|nil
function M.width(bufnr, fallback)
  for _, winid in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(winid) == bufnr then
      return api.nvim_win_get_width(winid)
    end
  end
  return fallback
end

---Available text width inside a Cortex buffer.
---@param bufnr integer
---@param fallback integer
---@return integer
function M.content_width(bufnr, fallback)
  return math.max(1, M.width(bufnr, fallback) - 2)
end

---Trim a display string without allowing a pane title or row to overflow.
---@param value any
---@param width integer
---@return string
function M.truncate(value, width)
  local text = tostring(value or '')
  width = math.max(1, math.floor(tonumber(width) or 1))
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  local ellipsis = '…'
  if vim.fn.strdisplaywidth(ellipsis) >= width then
    return ellipsis
  end

  -- Character counts are not display widths: wide glyphs consume two cells,
  -- while combining characters consume none. Find the longest character-safe
  -- prefix whose rendered form (including the ellipsis) fits the pane.
  local low, high = 0, vim.fn.strchars(text)
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    local candidate = vim.fn.strcharpart(text, 0, middle) .. ellipsis
    if vim.fn.strdisplaywidth(candidate) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. ellipsis
end

---Move the cursor to the Neovim mouse event and focus the target window.
---@param winid integer
---@return integer|nil line 1-based buffer line
function M.mouse_line(winid)
  if not winid or not api.nvim_win_is_valid(winid) then
    return nil
  end
  local position = vim.fn.getmousepos()
  if position.winid and position.winid ~= 0 and position.winid ~= winid then
    return nil
  end
  local line = tonumber(position.line)
  if not line then
    return nil
  end
  local bufnr = api.nvim_win_get_buf(winid)
  local count = api.nvim_buf_line_count(bufnr)
  line = math.max(1, math.min(line, count))
  local column = math.max(0, (tonumber(position.column) or 1) - 1)
  api.nvim_set_current_win(winid)
  api.nvim_win_set_cursor(winid, { line, column })
  return line
end

return M
