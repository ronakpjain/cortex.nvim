-- Scratch-buffer and window lifecycle shared by Cortex views.
local api = vim.api

local M = {}
local View = {}
View.__index = View

---@class CortexViewOptions
---@field name string buffer name
---@field filetype string
---@field title string standalone float title
---@field element_title? string nvim-dap-ui float title
---@field element? string nvim-dap-ui element name
---@field float_width integer
---@field float_height integer
---@field window table default standalone window configuration

---Create a lifecycle helper backed by a feature module's public state table.
---@param state table
---@param options CortexViewOptions
---@return table
function M.new(state, options)
  vim.validate({
    state = { state, 'table' },
    options = { options, 'table' },
    name = { options.name, 'string' },
    filetype = { options.filetype, 'string' },
    title = { options.title, 'string' },
  })
  return setmetatable({ state = state, options = options }, View)
end

function View:buf_valid()
  return self.state.bufnr ~= nil and api.nvim_buf_is_valid(self.state.bufnr)
end

function View:win_valid()
  return self.state.winid ~= nil and api.nvim_win_is_valid(self.state.winid)
end

---Return the standalone window or the current dap-ui element window.
---@return integer|nil
function View:window()
  if self:win_valid() then
    return self.state.winid
  end
  if self.state.element_mode and self:buf_valid() and api.nvim_get_current_buf() == self.state.bufnr then
    return api.nvim_get_current_win()
  end
  return nil
end

---Create or return the scratch buffer.
---@return integer bufnr
---@return boolean created
function View:buffer()
  if self:buf_valid() then
    return self.state.bufnr, false
  end
  local bufnr = api.nvim_create_buf(false, true)
  self.state.bufnr = bufnr
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = self.options.filetype
  pcall(api.nvim_buf_set_name, bufnr, self.options.name)
  return bufnr, true
end

local function split_command(position, width, height)
  if position == 'left' then
    return 'topleft vertical ' .. width .. 'split'
  end
  if position == 'top' then
    return 'topleft ' .. height .. 'split'
  end
  if position == 'bottom' then
    return 'botright ' .. height .. 'split'
  end
  return 'botright vertical ' .. width .. 'split'
end

local function set_window_options(winid)
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].wrap = false
  vim.wo[winid].signcolumn = 'no'
  pcall(function()
    vim.wo[winid].winfixheight = true
    vim.wo[winid].winfixwidth = true
  end)
end

---Open the buffer in a standalone float or split.
---@param window? table
---@return integer winid
function View:open(window)
  if self:win_valid() then
    return self.state.winid
  end
  local cfg = vim.tbl_deep_extend('force', vim.deepcopy(self.options.window or {}), window or {})
  local bufnr = self:buffer()
  local previous = api.nvim_get_current_win()
  local position = cfg.position or 'right'
  local width = tonumber(cfg.width) or 80
  local height = tonumber(cfg.height) or 16
  local winid
  if position == 'float' then
    width = math.min(width, math.max(tonumber(cfg.min_width) or 20, vim.o.columns - 4))
    height = math.min(height, math.max(tonumber(cfg.min_height) or 5, vim.o.lines - 6))
    winid = api.nvim_open_win(bufnr, cfg.focus_on_open == true, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal',
      border = cfg.border or 'rounded',
      title = ' ' .. self.options.title .. ' ',
      title_pos = 'center',
    })
  else
    vim.cmd(split_command(position, width, height))
    winid = api.nvim_get_current_win()
    api.nvim_win_set_buf(winid, bufnr)
  end
  set_window_options(winid)
  self.state.winid = winid
  if not cfg.focus_on_open and api.nvim_win_is_valid(previous) then
    api.nvim_set_current_win(previous)
  end
  return winid
end

---Close the standalone window. dap-ui owns element windows.
---@return boolean closed
function View:close()
  if self.state.element_mode then
    return false
  end
  local closed = self:win_valid()
  if closed then
    pcall(api.nvim_win_close, self.state.winid, true)
  end
  self.state.winid = nil
  return closed
end

---Close through the feature module, or close dap-ui when it owns the window.
---@param close function
---@return 'standalone'|'element'
function View:close_from_buffer(close)
  if self.state.element_mode then
    local ok, dapui = pcall(require, 'dapui')
    if ok and dapui.close then
      dapui.close()
    end
    return 'element'
  end
  close()
  return 'standalone'
end

---Toggle the standalone window or dap-ui element float.
---@param window? table
---@return 'opened'|'closed'|'element'
function View:toggle(window)
  if self.state.element_mode then
    local ok, dapui = pcall(require, 'dapui')
    if ok and dapui.float_element then
      dapui.float_element(self.options.element, {
        width = self.options.float_width,
        height = self.options.float_height,
        enter = true,
      })
    end
    return 'element'
  end
  if self:win_valid() then
    self:close()
    return 'closed'
  end
  self:open(window)
  return 'opened'
end

---Register the buffer and renderer as an nvim-dap-ui element.
---@param render function
---@param buffer? function feature buffer provider that installs its keymaps
---@return table
function View:element(render, buffer)
  self.state.element_mode = true
  self:buffer()
  return {
    buffer = buffer or function()
      local bufnr = self:buffer()
      return bufnr
    end,
    render = render,
    allow_without_session = true,
    float_defaults = function()
      return {
        width = self.options.float_width,
        height = self.options.float_height,
        enter = true,
        title = self.options.element_title or self.options.title,
      }
    end,
  }
end

return M
