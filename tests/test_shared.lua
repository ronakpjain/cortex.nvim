-- Shared configuration and stopped-session helpers.
local this = debug.getinfo(1, 'S').source:sub(2)
local root = this:match('^(.*)/tests/[^/]+$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local config = require('cortex.config')
local session = require('cortex.session')
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

check('get rejects non-tables', config.get(nil, 'key') == nil)
check('first returns the first configured alias', config.first({ second = 2 }, { 'first', 'second' }) == 2)

local merged = config.merge(
  { enabled = false, limit = 1, nested = { left = true } },
  { enabled = true, nested = { right = true } },
  { maxItems = 3 },
  { limit = 'maxItems' }
)
check('merge preserves nested setup values', merged.nested.left and merged.nested.right)
check('merge normalizes launch aliases', merged.enabled and merged.limit == 3)

local stopped = { initialized = true, stopped_thread_id = 1, current_frame = { id = 2 } }
local core = {
  _stopped_session = function()
    return stopped
  end,
  _is_stopped = function()
    return true
  end,
}
check('session helper honors injected session', session.stopped(core) == stopped)
check('session helper reports stopped state', session.is_stopped(core))
check('session generation accepts current request', session.is_current(core, { generation = 4 }, 4, stopped))
check('session generation rejects stale request', not session.is_current(core, { generation = 5 }, 4, stopped))

io.write(string.format('%d/%d shared checks passed\n', checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
