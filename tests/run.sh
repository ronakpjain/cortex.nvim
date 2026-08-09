#!/bin/sh
# Run the cortex.nvim test suite.
#
#   ./tests/run.sh
#
# Requires only `nvim` (>= 0.10) on PATH.
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
nvim=${NVIM:-nvim}

echo "== syntax check =="
for f in "$root"/lua/cortex/*.lua "$root"/tests/*.lua; do
  "$nvim" --headless --clean -u NONE -l /dev/stdin "$f" <<'EOF'
local path = _G.arg[1]
local fn, err = loadfile(path)
if not fn then
  io.stdout:write('FAIL ' .. path .. ': ' .. tostring(err) .. '\n')
  os.exit(1)
end
io.stdout:write('ok   ' .. path .. '\n')
EOF
done

echo
echo "== unit tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_adapter.lua"

echo
echo "== persistent target tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_target.lua"

echo
echo "== SVD parser tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_svd.lua"

echo
echo "== peripheral browser tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_peripheral.lua"

echo
echo "== RTOS browser tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_rtos.lua"

echo
echo "== call-stack browser tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_callstack.lua"

echo
echo "== live-watch hydration tests =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_live_watch.lua"

echo
echo "== end-to-end tests (launch + openocd) =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_e2e.lua"

echo
echo "== end-to-end tests (attach + external server) =="
"$nvim" --headless --clean -u NONE -l "$root/tests/test_attach.lua"
