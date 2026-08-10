-- Headless tests for the OpenOCD telnet transport.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local Telnet = require('cortex.telnet')
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

local writes = {}
local transport = Telnet.new('127.0.0.1', 4444, 1000)
transport.connected = true
transport.ready = true
transport.handle = {
  write = function(_, data, callback)
    writes[#writes + 1] = data
    if callback then
      callback(nil)
    end
  end,
}

local first_error, first_response
local second_response
transport:send('mdw 0x20000000', function(err, response)
  first_error, first_response = err, response
end)
transport:send('reg', function(_, response)
  second_response = response
end)

check('first request is written immediately', writes[1] == 'mdw 0x20000000\n')
check('requests are serialized', #writes == 1 and transport:queue_size() == 2)
transport:_on_data('mdw 0x20000000\r\n0x20000000: 12345678\r\n> ')
check('echo and prompt are removed', first_error == nil and first_response == '0x20000000: 12345678')
check('next request starts after response', writes[2] == 'reg\n')
transport:_on_data('reg\r\nr0 (/32): 0x1')
check('partial response remains pending', second_response == nil and transport:queue_size() == 1)
transport:_on_data('\r\n> ')
check('split response completes', second_response == 'r0 (/32): 0x1' and transport:queue_size() == 0)
transport:close()

local banner = Telnet.new('127.0.0.1', 4444, 1000)
banner.connected = true
banner:_on_data(string.char(255, 251, 1) .. 'Open On-Chip Debugger\r\n> ')
check('telnet negotiation is stripped from banner', banner.ready == true and banner.iac_pending == '')
banner:close()

io.write(string.format('%d/%d telnet checks passed\n', checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
