local api = vim.api
local callstack = require('cortex.callstack')
local live_watch = require('cortex.live_watch')
local peripheral = require('cortex.peripheral')
local rtos = require('cortex.rtos')
local target = require('cortex.target')

local M = {}

---@class cortex.Config
local defaults = {
  nvim = nil, ---@type string?
  adapter_path = nil, ---@type string?
  adapter_args = {}, ---@type string[]
  adapter_name = 'cortex-debug',
  filetypes = { 'c', 'cpp', 'rust', 'asm' },
  mouse = true,

  peripheral = {
    auto_refresh_on_stop = true,
    svdFile = nil,
    svdPath = nil,
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    read_all = false, -- otherwise refresh only expanded peripherals
    window = nil,
  },

  rtos = {
    enabled = false,
    auto_open = false,
    auto_refresh_on_stop = true,
    max_tasks = 128,
    max_priorities = nil,
    tcb_type = 'TCB_t',
    list_item_type = 'ListItem_t',
    stack_growth = -1,
    stack_word_bytes = 4,
    symbols = {},
    fields = {},
    window = nil,
  },

  callstack = {
    auto_open = false,
    auto_refresh_on_stop = true,
    levels = 0,
    window = nil,
  },

  live_watch = {
    auto_open = true,
    samples_per_second = 4,
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    max_depth = 4,
    max_children = 32,
    expressions = {}, ---@type string[]
  },

  window = {
    position = 'right',
    width = 60,
    height = 12,
    border = 'rounded',
    focus_on_open = false,
  },
}

---@type cortex.Config
M.config = vim.deepcopy(defaults)

local function notify(msg, level)
  vim.notify('[cortex.nvim] ' .. msg, level or vim.log.levels.INFO)
end

--- Root directory of this plugin (the parent of `lua/`).
---@return string
local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(src, ':p:h:h:h'))
end

--- Default location of the bundled Lua adapter entry script.
---@return string
function M.adapter_script()
  if M.config.adapter_path and M.config.adapter_path ~= '' then
    return vim.fs.normalize(vim.fn.expand(M.config.adapter_path))
  end
  return plugin_root() .. '/lua/cortex/adapter_main.lua'
end

--- Neovim executable used to host the adapter.
---@return string
function M.adapter_nvim()
  local exe = M.config.nvim
  if exe and exe ~= '' then
    return vim.fs.normalize(vim.fn.expand(exe))
  end
  local progpath = vim.v.progpath
  if progpath and progpath ~= '' then
    return progpath
  end
  return vim.fn.exepath('nvim') ~= '' and vim.fn.exepath('nvim') or 'nvim'
end

---@return table|nil dap
local function get_dap()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil
  end
  return dap
end

local function active_session()
  local dap = get_dap()
  if not dap then
    return nil
  end
  local session = dap.session()
  if not session or not session.initialized then
    return nil
  end
  return session
end

local function stopped_session()
  local session = active_session()
  if not session or not session.stopped_thread_id or not session.current_frame then
    return nil
  end
  return session
end

function M._is_stopped()
  return stopped_session() ~= nil
end

function M._stopped_session()
  return stopped_session()
end

live_watch.setup(M)
M._watch = live_watch.state

function M.start(...)
  return live_watch.start(...)
end

function M.stop(...)
  return live_watch.stop(...)
end

function M.close(...)
  return live_watch.close(...)
end

function M.open(...)
  return live_watch.open(...)
end

function M.toggle(...)
  return live_watch.toggle(...)
end

function M.add(...)
  return live_watch.add(...)
end

function M.clear(...)
  return live_watch.clear(...)
end

function M.remove_at_line(...)
  return live_watch.remove_at_line(...)
end

function M.refresh(...)
  return live_watch.refresh(...)
end

function M.telnet(...)
  return live_watch.telnet(...)
end

function M.status(...)
  return live_watch.status(...)
end

local function on_session_start(config)
  live_watch.on_session_start(config)
  peripheral.on_session_start(config)
  rtos.on_session_start(config)
  callstack.on_session_start(config)
end

local function on_session_end()
  live_watch.on_session_end()
  peripheral.on_session_end()
  rtos.on_session_end()
  callstack.on_session_end()
  M.close_views()
end

local function register_listeners(dap)
  local key = 'cortex.nvim'
  dap.listeners.after.event_initialized[key] = function(session)
    on_session_start(session and session.config)
  end
  dap.listeners.after.event_continued[key] = function()
    live_watch.on_session_continued()
    peripheral.on_session_continued()
    rtos.on_session_continued()
    callstack.on_session_continued()
  end
  dap.listeners.after.event_stopped[key] = function()
    live_watch.on_session_stopped()
    peripheral.on_session_stopped()
    rtos.on_session_stopped()
    callstack.on_session_stopped()
  end
  dap.listeners.after.event_terminated[key] = on_session_end
  dap.listeners.after.event_exited[key] = on_session_end
  dap.listeners.after.disconnect[key] = on_session_end
end

local function register_autocmds()
  local group = api.nvim_create_augroup('CortexNvim', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = M._shutdown,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      live_watch.on_window_closed(args.match)
    end,
  })
end

function M._shutdown(...)
  return live_watch.shutdown(...)
end

--- Register the `cortex-debug` executable adapter with nvim-dap.
---
--- The adapter is a pure Lua DAP implementation hosted by a second, headless
--- Neovim process: `nvim --headless --clean -u NONE -l adapter_main.lua`.
---@param dap table
local function register_adapter(dap)
  local script = M.adapter_script()
  local args = { '--headless', '--clean', '-u', 'NONE', '-l', script }
  vim.list_extend(args, M.config.adapter_args or {})

  ---@type table
  dap.adapters[M.config.adapter_name] = {
    type = 'executable',
    command = M.adapter_nvim(),
    args = args,
    options = {
      -- Keep the adapter tied to the DAP session so disconnect tears down
      -- its headless Neovim process as well.
      detached = false,
      initialize_timeout_sec = 8,
    },
    -- Keep every key from `.vscode/launch.json` (including `liveWatch`) and
    -- only fill in the pieces the adapter/live watch need.
    enrich_config = function(config, on_config)
      local final = vim.deepcopy(config)
      if final.cwd == nil then
        final.cwd = vim.fn.getcwd()
      end
      if final.request == nil then
        final.request = 'launch'
      end
      if final.servertype == nil and final.serverType ~= nil then
        final.servertype = final.serverType
      end
      -- `liveWatch` is passed through verbatim; we only use it locally.
      live_watch.configure(final)
      on_config(final)
    end,
  }

  -- Make `.vscode/launch.json` entries with `"type": "cortex-debug"` show up
  -- for C/C++ buffers. Recent nvim-dap reads launch.json automatically
  -- (`dap.providers.configs["dap.launch.json"]`); this mapping is only used by
  -- the legacy `dap.ext.vscode.load_launchjs()` helper.
  local ok, vscode = pcall(require, 'dap.ext.vscode')
  if ok and vscode.type_to_filetypes then
    vscode.type_to_filetypes[M.config.adapter_name] = M.config.filetypes
  end
end

function M.peripheral_open()
  return peripheral.open()
end

function M.peripheral_close()
  return peripheral.close()
end

function M.peripheral_toggle()
  return peripheral.toggle()
end

function M.peripheral_refresh(callback)
  return peripheral.refresh(callback)
end

function M.peripheral_element()
  return peripheral.element()
end

function M.peripheral_load(config)
  return peripheral.load(config)
end

function M.rtos_open()
  return rtos.open()
end

function M.rtos_close()
  return rtos.close()
end

function M.rtos_toggle()
  return rtos.toggle()
end

function M.rtos_refresh(callback)
  return rtos.refresh(callback)
end

function M.rtos_element()
  return rtos.element()
end

function M.callstack_open()
  return callstack.open()
end

function M.callstack_close()
  return callstack.close()
end

function M.callstack_toggle()
  return callstack.toggle()
end

function M.callstack_refresh(callback)
  return callstack.refresh(callback)
end

function M.callstack_element()
  return callstack.element()
end

function M.close_views()
  M.close()
  peripheral.close()
  rtos.close()
  callstack.close()
end

function M.debug_select()
  return target.select()
end

function M.debug_start()
  return target.start()
end

function M.debug_clear_target()
  return target.clear()
end

function M.debug_target()
  return target.status()
end

local commands = {
  { 'CortexDebugWatch', M.toggle, { desc = 'Toggle the Cortex live watch window' } },
  {
    'CortexDebugWatchAdd',
    function(opts)
      M.add(opts.args ~= '' and opts.args or nil)
    end,
    { nargs = '*', desc = 'Add a Cortex live watch expression' },
  },
  { 'CortexDebugWatchClear', M.clear, { desc = 'Clear all Cortex live watch expressions' } },
  {
    'CortexDebugTelnet',
    function(opts)
      M.telnet(opts.args ~= '' and opts.args or nil)
    end,
    { nargs = '*', desc = 'Send a command to the OpenOCD telnet server' },
  },
  { 'CortexDebugPeripheral', M.peripheral_toggle, { desc = 'Toggle the stopped-only Cortex SVD peripheral browser' } },
  {
    'CortexDebugPeripheralRefresh',
    function()
      M.peripheral_refresh()
    end,
    { desc = 'Refresh SVD peripheral registers (stopped only)' },
  },
  { 'CortexDebugRTOS', M.rtos_toggle, { desc = 'Toggle the stopped-only FreeRTOS task browser' } },
  {
    'CortexDebugRTOSRefresh',
    function()
      M.rtos_refresh()
    end,
    { desc = 'Refresh FreeRTOS tasks (stopped only)' },
  },
  { 'CortexFreeRTOS', M.rtos_toggle, { desc = 'Toggle the stopped-only FreeRTOS task browser' } },
  { 'CortexDebugCallStack', M.callstack_toggle, { desc = 'Toggle the stopped-only current call stack' } },
  {
    'CortexDebugCallStackRefresh',
    function()
      M.callstack_refresh()
    end,
    { desc = 'Refresh the current call stack (stopped only)' },
  },
  { 'CortexDebugStack', M.callstack_toggle, { desc = 'Toggle the stopped-only current call stack' } },
  { 'CortexDebugSelect', M.debug_select, { desc = 'Select and remember a DAP launch target' } },
  { 'CortexDebugStart', M.debug_start, { desc = 'Start or continue the remembered DAP target' } },
  { 'CortexDebugTarget', M.debug_target, { desc = 'Show the remembered DAP launch target' } },
  { 'CortexDebugClearTarget', M.debug_clear_target, { desc = 'Forget the remembered DAP launch target' } },
}

---Create the user commands unless another plugin or user config owns the name.
function M._create_commands()
  for _, command in ipairs(commands) do
    local name = command[1]
    if vim.fn.exists(':' .. name) ~= 2 then
      api.nvim_create_user_command(name, command[2], command[3])
    end
  end
end

---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  live_watch.setup(M)
  if M.config.mouse and not vim.o.mouse:find('a', 1, true) then
    vim.opt.mouse:append('a')
  end
  peripheral.setup(M)
  rtos.setup(M)
  callstack.setup(M)
  target.setup(M)

  local dap = get_dap()
  if not dap then
    notify('nvim-dap not found; adapter not registered', vim.log.levels.WARN)
  else
    register_adapter(dap)
    register_listeners(dap)
  end

  register_autocmds()
  M._create_commands()
  return M
end

return M
