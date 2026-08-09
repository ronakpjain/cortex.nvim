-- Stopped-only peripheral browser checks with an isolated fake Telnet client.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local peripheral = require('cortex.peripheral')
local failures, total = 0, 0
local function check(name, ok, detail)
  total = total + 1
  if ok then io.stdout:write('ok   ' .. name .. '\n')
  else failures = failures + 1; io.stdout:write('FAIL ' .. name .. ' ' .. tostring(detail or '') .. '\n') end
end

local sent = {}
local FakeTelnet = {}
FakeTelnet.__index = FakeTelnet
function FakeTelnet.new() return setmetatable({ closed = false }, FakeTelnet) end
function FakeTelnet:connect(cb) self.connected = true; cb(nil) end
function FakeTelnet:is_connected() return self.connected and not self.closed end
function FakeTelnet:close() self.closed = true end
function FakeTelnet:send(command, cb)
  sent[#sent + 1] = command
  cb(nil, '0x40000000: 03 12 00 00\n')
end

local fake_core = {
  config = { peripheral = { timeout_ms = 100 } },
  _is_stopped = function() return true end,
  _new_peripheral_telnet = function() return FakeTelnet.new() end,
}
peripheral.setup(fake_core)
local path = root .. '/tests/fixtures/small.svd'
local model, err = peripheral.load({ svdFile = path, cwd = root })
check('headless SVD load', model ~= nil, err)
local base = model and model.peripherals_by_name.BASE
local ctrl = base and base.registers_by_name.CTRL
check('register address available', ctrl and ctrl.address == 0x40000000)
check('register command uses address and width', peripheral.register_command(ctrl) == 'mdb 0x40000000 4')
local bad_decoded = peripheral.decode_register(ctrl, 'Error: cannot read', 'little')
check('failed memory reply is not decoded as zero', bad_decoded == nil)
check('write-only register is not read', peripheral.register_command({ address = 0x40000010, size = 32, access = 'write-only' }) == nil)

peripheral._state.session_config = { svdFile = path, cwd = root }
local refreshed, refresh_err = peripheral.refresh()
check('stopped refresh starts', refreshed == true, refresh_err)
check('isolated fake telnet received request', #sent > 0 and sent[1] == 'mdb 0x40000000 4')
local decoded = ctrl and ctrl.decoded
check('little-endian register value decoded', decoded and decoded.hex == '0x00001203', decoded and decoded.hex)
check('field value decoded', decoded and decoded.fields.ENABLE.value == 1)
check('enumerated field name decoded', decoded and decoded.fields.ENABLE.enum == 'Enabled')
check('field mask decoded', decoded and decoded.fields.ENABLE.mask == '0x00000001')

fake_core._is_stopped = function() return false end
local no_read = #sent
local result, running_err = peripheral.refresh()
check('running refresh rejected', result == nil and running_err == 'target must be stopped')
check('running refresh sends no request', #sent == no_read)

io.stdout:write(string.format('%d/%d peripheral checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
