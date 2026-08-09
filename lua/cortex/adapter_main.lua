--- Entry script for the pure Lua cortex-debug DAP adapter.
---
--- nvim-dap launches this with:
---
---   nvim --headless --clean -u NONE -l <plugin>/lua/cortex/adapter_main.lua
---
--- `--clean -u NONE` means the user's `runtimepath` (and therefore this
--- plugin's `lua/` directory) is not on `package.path`, so we derive the
--- plugin root from this script's own path and prepend it manually.

local this = debug.getinfo(1, 'S').source
if this:sub(1, 1) == '@' then
  this = this:sub(2)
end

-- `<root>/lua/cortex/adapter_main.lua` -> `<root>/lua`
local lua_dir = this:match('^(.*)[/\\]cortex[/\\]adapter_main%.lua$')
if lua_dir and lua_dir ~= '' then
  if not lua_dir:match('^[/\\]') and not lua_dir:match('^%a:') then
    lua_dir = (vim.uv or vim.loop).cwd() .. '/' .. lua_dir
  end
  package.path = table.concat({
    lua_dir .. '/?.lua',
    lua_dir .. '/?/init.lua',
    package.path,
  }, ';')
end

local ok, adapter = pcall(require, 'cortex.adapter')
if not ok then
  io.stderr:write('[cortex-dap] cannot load cortex.adapter: ' .. tostring(adapter) .. '\n')
  os.exit(1)
end

local code = adapter.main({})
os.exit(code or 0)
