-- Minimal fake OpenOCD: parses `-c "gdb_port N"` and listens on that port.
--   nvim --headless --clean -u NONE -l tests/fake_openocd.lua -f x.cfg -c "gdb_port 3333" ...

local uv = vim.uv or vim.loop

local argv = _G.arg or {}
local gdb_port = 3333
for i = 1, #argv do
  local p = tostring(argv[i]):match('^gdb_port%s+(%d+)$')
  if p then
    gdb_port = tonumber(p)
  end
end

io.stdout:write('Open On-Chip Debugger (fake)\n')
io.stdout:write(string.format('Info : Listening on port %d for gdb connections\n', gdb_port))
io.stdout:flush()

local server = uv.new_tcp()
local ok = pcall(function()
  server:bind('127.0.0.1', gdb_port)
  server:listen(8, function()
    local client = uv.new_tcp()
    server:accept(client)
    client:read_start(function() end)
  end)
end)
if not ok then
  io.stderr:write('fake openocd: cannot bind port\n')
  os.exit(1)
end

vim.wait(30000, function()
  return false
end, 100)
os.exit(0)
