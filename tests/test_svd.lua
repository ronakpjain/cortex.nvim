-- Focused tests for the dependency-free CMSIS-SVD parser.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local svd = require('cortex.svd')
local failures, total = 0, 0
local function check(name, ok, detail)
  total = total + 1
  if ok then io.stdout:write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.stdout:write('FAIL ' .. name .. (detail and ('\n     ' .. tostring(detail)) or '') .. '\n')
  end
end
local function eq(name, got, want)
  local ok = vim.deep_equal(got, want)
  check(name, ok, not ok and ('got: ' .. vim.inspect(got) .. '\nwant: ' .. vim.inspect(want)) or nil)
end

local model, err = svd.load_file(root .. '/tests/fixtures/small.svd')
check('fixture parses', model ~= nil, err)
eq('device name', model and model.name, 'ExampleDevice')
eq('entity and cdata descriptions', model and model.vendor, 'Example & Co')
eq('device defaults', model and model.defaults, { size = 32, access = 'read-write', resetValue = 0 })
local base = model and model.peripherals_by_name.BASE
check('base peripheral address', base and base.baseAddress == 0x40000000)
eq('register address', base and base.registers_by_name.CTRL.address, 0x40000000)
eq('register default size', base and base.registers_by_name.CTRL.size, 32)
eq('register dimensions flattened', #base.registers, 3)
eq('dimension address', base and base.registers_by_name.DATA1.address, 0x40000014)
eq('bitOffset field', base and base.registers_by_name.CTRL.fields_by_name.ENABLE.bitWidth, 1)
eq('lsb/msb field', base and base.registers_by_name.CTRL.fields_by_name.MODE.bitOffset, 4)
eq('enum value', base and base.registers_by_name.CTRL.fields_by_name.ENABLE.enumeratedValuesByName.Enabled.value, 1)
local derived = model and model.peripherals_by_name.DERIVED
check('peripheral derived register', derived and derived.registers_by_name.STATUS ~= nil)
eq('derived register override', derived and derived.registers_by_name.STATUS.address, 0x50000008)
eq('derived register inherited field', derived and #derived.registers_by_name.STATUS.fields, 2)
local clustered = model and model.peripherals_by_name.CLUSTERED
check('cluster dimensions flattened', clustered and #clustered.registers == 4)
eq('clustered register address', clustered and clustered.registers_by_name['CHB.VALUE'].address, 0x60000024)
eq('derived cluster register address', clustered and clustered.registers_by_name['CLDERIVED.VALUE2'].address, 0x60000064)

local qualified_xml = [[
<device><name>UnitDevice</name><addressUnitBits>16</addressUnitBits><peripherals>
<peripheral><name>P</name><baseAddress>0x10</baseAddress><registers>
<register><name>A</name><addressOffset>1</addressOffset><fields><field><name>X</name><bitOffset>3</bitOffset><bitWidth>2</bitWidth></field></fields></register>
<register><name>B</name><addressOffset>2</addressOffset><fields><field derivedFrom="A.X"><name>Y</name></field></fields></register>
</registers></peripheral></peripherals></device>]]
local unit_model, unit_err = svd.parse(qualified_xml)
local unit_peripheral = unit_model and unit_model.peripherals_by_name.P
check('addressUnitBits scales addresses', unit_peripheral and unit_peripheral.baseAddress == 0x20
  and unit_peripheral.registers_by_name.B.address == 0x24, unit_err)
eq('qualified field derivedFrom', unit_peripheral and unit_peripheral.registers_by_name.B.fields_by_name.Y.bitOffset, 3)

local callback_model, callback_err
svd.load_file(root .. '/tests/fixtures/small.svd', function(value, load_err)
  callback_model, callback_err = value, load_err
end)
check('loader callback', callback_model and callback_model.name == model.name and callback_err == nil)

local real_path = '/Users/ronak/coding/PER/Projects/firmware/firmware/support/svd/STM32G474.svd'
local real = io.open(real_path, 'rb')
if real then
  real:close()
  local device, real_err = svd.load_file(real_path)
  check('STM32G474 parses', device ~= nil, real_err)
  check('STM32G474 has peripherals', device and #device.peripherals > 20)
  local gpioa = device and device.peripherals_by_name.GPIOA
  check('STM32G474 GPIOA', gpioa and gpioa.baseAddress == 0x48000000)
  check('STM32G474 registers flattened', gpioa and #gpioa.registers > 10)
else
  io.stdout:write('skip STM32G474 fixture (file not present)\n')
end

io.stdout:write(string.format('%d/%d SVD checks passed\n', total - failures, total))
os.exit(failures == 0 and 0 or 1)
