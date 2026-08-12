-- Stopped-only peripheral browser checks with an isolated fake Telnet client.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local peripheral = require('cortex.peripheral')
local failures, total = 0, 0
local function check(name, ok, detail)
  total = total + 1
  if ok then
    io.stdout:write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.stdout:write('FAIL ' .. name .. ' ' .. tostring(detail or '') .. '\n')
  end
end

local sent = {}
local FakeTelnet = {}
FakeTelnet.__index = FakeTelnet
function FakeTelnet.new()
  return setmetatable({ closed = false }, FakeTelnet)
end
function FakeTelnet:connect(cb)
  self.connected = true
  cb(nil)
end
function FakeTelnet:is_connected()
  return self.connected and not self.closed
end
function FakeTelnet:close()
  self.closed = true
end
function FakeTelnet:send(command, cb)
  sent[#sent + 1] = command
  cb(nil, '0x40000000: 03 12 00 00\n')
end

local fake_core = {
  config = { peripheral = { timeout_ms = 100 } },
  _is_stopped = function()
    return true
  end,
  _new_peripheral_telnet = function()
    return FakeTelnet.new()
  end,
}
peripheral.setup(fake_core)
local path = root .. '/tests/fixtures/small.svd'
local expanded_workspace_path = peripheral.resolve_path({
  svdFile = '${workspaceroot}/tests/fixtures/small.svd',
  workspaceRoot = root,
  cwd = '${workspaceRoot}',
})
local absolute_path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
check('workspaceRoot path expands', expanded_workspace_path == absolute_path, expanded_workspace_path)
local model, err = peripheral.load({ svdFile = path, cwd = root })
check('headless SVD load', model ~= nil, err)
local base = model and model.peripherals_by_name.BASE
local ctrl = base and base.registers_by_name.CTRL
check('register address available', ctrl and ctrl.address == 0x40000000)
check('register command uses address and width', peripheral.register_command(ctrl) == 'mdb 0x40000000 4')
local bad_decoded = peripheral.decode_register(ctrl, 'Error: cannot read', 'little')
check('failed memory reply is not decoded as zero', bad_decoded == nil)
check(
  'write-only register is not read',
  peripheral.register_command({ address = 0x40000010, size = 32, access = 'write-only' }) == nil
)

peripheral._state.session_config = { svdFile = path, cwd = root }
local refreshed, refresh_err = peripheral.refresh()
check('stopped refresh starts', refreshed == true, refresh_err)
check('isolated fake telnet received request', #sent > 0 and sent[1] == 'mdb 0x40000000 4')
local decoded = ctrl and ctrl.decoded
check('little-endian register value decoded', decoded and decoded.hex == '0x00001203', decoded and decoded.hex)
check('field value decoded', decoded and decoded.fields.ENABLE.value == 1)
check('enumerated field name decoded', decoded and decoded.fields.ENABLE.enum == 'Enabled')
check('field mask decoded', decoded and decoded.fields.ENABLE.mask == '0x00000001')

fake_core._is_stopped = function()
  return false
end
local no_read = #sent
local result, running_err = peripheral.refresh()
check('running refresh rejected', result == nil and running_err == 'target must be stopped')
check('running refresh sends no request', #sent == no_read)
peripheral._state.expanded.BASE = true
peripheral._state.expanded['BASE.CTRL'] = true
local captured_highlights = {}
local add_highlight = vim.api.nvim_buf_add_highlight
vim.api.nvim_buf_add_highlight = function(bufnr, namespace, group, line, start, finish)
  captured_highlights[#captured_highlights + 1] = {
    group = group,
    line = line,
    start = start,
    finish = finish,
  }
  return add_highlight(bufnr, namespace, group, line, start, finish)
end
local element = peripheral.element()
element.render()
vim.api.nvim_buf_add_highlight = add_highlight
local element_lines = vim.api.nvim_buf_get_lines(element.buffer(), 0, -1, false)
local element_text = table.concat(element_lines, '\n')
check('dapui SVD element shows peripherals', element_text:find('BASE', 1, true) ~= nil)
local address_line, address_column
for index, line in ipairs(element_lines) do
  local column = line:find('0x40000000', 1, true)
  if column then
    address_line, address_column = index - 1, column - 1
    break
  end
end
local address_highlighted = false
for _, highlight in ipairs(captured_highlights) do
  if highlight.group == 'CortexAddress' and highlight.line == address_line and highlight.start == address_column then
    address_highlighted = true
    break
  end
end
check('peripheral address highlight uses rendered column', address_highlighted)

fake_core._is_stopped = function()
  return true
end
fake_core.config.peripheral.auto_refresh_on_stop = true
local sent_before_stop = #sent
peripheral.on_session_stopped()
check('peripheral refreshes on stop when embedded', #sent > sent_before_stop)

io.stdout:write(string.format('%d/%d peripheral checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
