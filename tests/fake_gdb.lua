-- Minimal fake `arm-none-eabi-gdb --interpreter=mi2` used by the e2e test.
--   nvim --headless --clean -u NONE -l tests/fake_gdb.lua --interpreter=mi2 ...

local uv = vim.uv or vim.loop

local stdin = uv.new_pipe(false)
stdin:open(0)
local stdout = uv.new_pipe(false)
stdout:open(1)

local done = false
local buf = ''
local bp = 0

local function emit(s)
  stdout:write(s .. '\n')
end

emit('=thread-group-added,id="i1"')
emit('(gdb)')

local function reply(token, text)
  emit((token or '') .. text)
  emit('(gdb)')
end

local function handle(line)
  local token, command = line:match('^(%d*)(.*)$')
  local verb = command:match('^(%-[%w%-]+)') or ''

  if verb == '-gdb-exit' then
    reply(token, '^exit')
    done = true
    return
  elseif verb == '-break-insert' then
    bp = bp + 1
    local loc = command:match('"([^"]*)"%s*$') or '??'
    local line_no = loc:match(':(%d+)$') or '1'
    reply(
      token,
      string.format(
        '^done,bkpt={number="%d",type="breakpoint",disp="keep",enabled="y",addr="0x08000200",func="main",file="main.c",fullname="/tmp/main.c",line="%s",times="0"}',
        bp,
        line_no
      )
    )
    return
  elseif verb == '-exec-continue' then
    reply(token, '^running')
    emit('*running,thread-id="all"')
    -- Pretend we hit the temporary entry breakpoint shortly after.
    local timer = uv.new_timer()
    timer:start(60, 0, function()
      timer:stop()
      timer:close()
      emit(
        '*stopped,reason="breakpoint-hit",disp="del",bkptno="1",frame={addr="0x08000200",func="main",args=[],file="main.c",fullname="/tmp/main.c",line="12"},thread-id="1",stopped-threads="all"'
      )
      emit('(gdb)')
    end)
    return
  elseif verb == '-thread-info' then
    reply(token, '^done,threads=[{id="1",target-id="Thread 1",name="cortex-m4",state="stopped"}],current-thread-id="1"')
    return
  elseif verb == '-stack-list-frames' then
    reply(
      token,
      '^done,stack=[frame={level="0",addr="0x08000200",func="main",file="main.c",fullname="/tmp/main.c",line="12"},frame={level="1",addr="0x08000100",func="Reset_Handler",file="start.c",fullname="/tmp/start.c",line="40"}]'
    )
    return
  elseif verb == '-stack-list-variables' then
    reply(
      token,
      '^done,variables=[{name="counter",type="int",value="7"},{name="flag",type="char",value="1 \'\\001\'"}]'
    )
    return
  elseif verb == '-data-list-register-names' then
    reply(token, '^done,register-names=["r0","r1","sp","pc"]')
    return
  elseif verb == '-data-list-register-values' then
    reply(
      token,
      '^done,register-values=[{number="0",value="0x0"},{number="1",value="0x20000100"},{number="2",value="0x20001000"},{number="3",value="0x8000200"}]'
    )
    return
  elseif verb == '-var-create' then
    reply(token, '^done,name="var1",numchild="0",value="7",type="int",thread-id="1",has_more="0"')
    return
  elseif verb == '-data-evaluate-expression' then
    reply(token, '^done,value="0x20000100"')
    return
  elseif verb == '-exec-interrupt' then
    reply(token, '^done')
    local timer = uv.new_timer()
    timer:start(30, 0, function()
      timer:stop()
      timer:close()
      emit(
        '*stopped,reason="signal-received",signal-name="SIGINT",signal-meaning="Interrupt",frame={addr="0x08000300",func="loop",file="main.c",fullname="/tmp/main.c",line="20"},thread-id="1",stopped-threads="all"'
      )
      emit('(gdb)')
    end)
    return
  elseif verb == '-exec-next' or verb == '-exec-step' or verb == '-exec-finish' then
    reply(token, '^running')
    local timer = uv.new_timer()
    timer:start(30, 0, function()
      timer:stop()
      timer:close()
      emit(
        '*stopped,reason="end-stepping-range",frame={addr="0x08000210",func="main",file="main.c",fullname="/tmp/main.c",line="13"},thread-id="1",stopped-threads="all"'
      )
      emit('(gdb)')
    end)
    return
  elseif verb == '-interpreter-exec' then
    emit('~"' .. command:gsub('\\', '\\\\'):gsub('"', '\\"') .. '\\n"')
    reply(token, '^done')
    return
  end
  reply(token, '^done')
end

stdin:read_start(function(err, chunk)
  if err or not chunk then
    done = true
    return
  end
  buf = buf .. chunk
  while true do
    local nl = buf:find('\n', 1, true)
    if not nl then
      break
    end
    local line = buf:sub(1, nl - 1):gsub('\r$', '')
    buf = buf:sub(nl + 1)
    if line ~= '' then
      handle(line)
    end
  end
end)

vim.wait(20000, function()
  return done
end, 20)
os.exit(0)
