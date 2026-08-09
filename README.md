# cortex.nvim

A self-contained ARM Cortex-M debugging plugin for Neovim.

* **Pure Lua DAP adapter** (`lua/cortex/adapter.lua`) — drives
  `arm-none-eabi-gdb --interpreter=mi2` and OpenOCD, speaks Content-Length
  framed DAP JSON on stdin/stdout.
* **Native OpenOCD Live Watch** (`lua/cortex/init.lua`) — a libuv TCP telnet
  client that samples memory/symbols while the target is *running*.
* **No external dependencies**: no Python, no Node, no VSCode extension, no
  third-party Lua rocks. Only Neovim + libuv APIs.

The adapter is hosted by a second, headless Neovim process:

```
nvim --headless --clean -u NONE -l <plugin>/lua/cortex/adapter_main.lua
```

## Install with `vim.pack`

```lua
vim.pack.add({
  {
    src = 'gh:ronakpjain/cortex.nvim',
    name = 'cortex.nvim',
  },
}, { confirm = false, load = true })

require('cortex').setup({})
```

Add the `vim.pack` entry after `nvim-dap` is installed. `setup()` registers
`dap.adapters['cortex-debug']` using the *current* Neovim executable
(`vim.v.progpath`) plus the bundled Lua entry script. The repository is also available at `https://github.com/ronakpjain/cortex.nvim`.

## Configuration

```lua
require('cortex').setup({
  -- Neovim binary that hosts the adapter (default: vim.v.progpath).
  nvim = nil,
  -- Override the adapter entry script (default: <plugin>/lua/cortex/adapter_main.lua).
  adapter_path = nil,
  adapter_args = {},
  adapter_name = 'cortex-debug',
  filetypes = { 'c', 'cpp', 'rust', 'asm' },

  live_watch = {
    auto_open = true,          -- open when the session sets liveWatch.enabled
    samples_per_second = 4,
    host = '127.0.0.1',
    port = 4444,               -- OpenOCD telnet port
    timeout_ms = 1000,
    max_depth = 4,             -- recursive struct/array expansion
    max_children = 32,
    expressions = {},          -- always-present watch expressions
  },

  window = {
    position = 'right',        -- right | left | top | bottom | float
    width = 60,
    height = 12,
    border = 'rounded',
    focus_on_open = false,
  },
})
```

## Debug configuration

Standard nvim-dap / `.vscode/launch.json` format — nvim-dap picks up
`"type": "cortex-debug"` entries automatically.

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug (OpenOCD)",
      "type": "cortex-debug",
      "request": "launch",
      "cwd": "${workspaceFolder}",
      "executable": "${workspaceFolder}/build/app.elf",
      "servertype": "openocd",
      "configFiles": ["interface/stlink.cfg", "target/stm32f4x.cfg"],
      "gdbPath": "arm-none-eabi-gdb",     // or "toolchainPrefix": "arm-none-eabi"
      "serverpath": "openocd",
      "gdbPort": 3333,
      "telnetPort": 4444,
      "runToEntryPoint": "main",
      "liveWatch": { "enabled": true, "samplesPerSecond": 4 }
    }
  ]
}
```

### Supported keys

| key | default | notes |
| --- | --- | --- |
| `request` | `launch` | `launch` loads + flashes the ELF, `attach` connects only |
| `executable` / `program` | – | ELF passed to `-file-exec-and-symbols` |
| `cwd` | editor cwd | working directory of gdb and OpenOCD |
| `servertype` | `openocd` | `openocd` or `external` (no server spawned) |
| `serverpath` / `serverPath` | `openocd` | OpenOCD binary |
| `configFiles` | – | one `-f` per entry |
| `searchDir` | – | one `-s` per entry |
| `serverArgs` | – | extra OpenOCD argv |
| `openOCDLaunchCommands` | – | one `-c` per entry |
| `gdbPath` | `<toolchainPrefix>-gdb` | |
| `toolchainPrefix` | `arm-none-eabi` | |
| `toolchainPath` | – | directory prepended to a bare `gdbPath` |
| `gdbArgs` | – | extra gdb argv |
| `gdbPort` | `3333` | |
| `telnetPort` | `4444` | also used by the live watch |
| `gdbTarget` | `localhost:<gdbPort>` | |
| `serverStartTimeout` | `20` (s) | |
| `runToEntryPoint` | – | temporary breakpoint + continue; reported as an `entry` stop |
| `runToMain` | – | legacy alias for `runToEntryPoint: "main"` |
| `stopAtEntry` | `true` | when no entry point is given |
| `loadFiles` | `true` | set `false` to skip flashing |
| `overrideLaunchCommands` / `overrideAttachCommands` | – | replace the default reset/flash sequence |
| `preLaunchCommands` / `postLaunchCommands` | – | gdb console or MI (`-`-prefixed) commands |
| `preAttachCommands` / `postAttachCommands` | – | same, for `attach` |
| `env` | – | extra environment for gdb/OpenOCD |
| `liveWatch` | – | `{ enabled, samplesPerSecond, telnetPort }`, used by the plugin only |

`${workspaceFolder}`, `${workspaceRoot}`, `${cwd}`, `${userHome}`, `${file}`,
`${fileDirname}`, `${fileBasename}`, `${fileBasenameNoExtension}` and
`${pathSeparator}` are expanded by the adapter if the editor did not.

## Implemented DAP surface

`initialize`, `launch`, `attach`, `configurationDone`, `setBreakpoints`,
`setFunctionBreakpoints`, `setExceptionBreakpoints`, `continue`, `pause`,
`next`, `stepIn`, `stepOut`, `threads`, `stackTrace`, `scopes`, `variables`,
`evaluate`, `setVariable`, `readMemory`, `disconnect`, `terminate`.

Events: `initialized`, `stopped`, `continued`, `thread`, `breakpoint`,
`output`, `terminated`, `exited` — enough for `nvim-dap-ui` to populate its
threads / stacks / scopes / watches / repl panes.

Out of scope (by design): pre/postLaunchTask, SVD parsing, peripheral register
views, RTOS views, semihosting UIs, disassembly.

## Live Watch

Reads memory over the OpenOCD **telnet** port while the CPU is running, so the
values keep updating without halting the target.

| command | action |
| --- | --- |
| `:CortexDebugWatch` | toggle the watch window |
| `:CortexDebugWatchAdd [expr]` | add an expression (prompts if omitted) |
| `:CortexDebugWatchClear` | remove all expressions |
| `:CortexDebugTelnet [cmd]` | send a raw OpenOCD command |

Inside the window: `a` add, `d` delete under cursor, `c` clear, `r` refresh,
`q` close.

Entries can be a raw address (`0x20000010`), an OpenOCD command (`reg`,
`mdw 0x20000000 4`, `targets`, …) or a C expression (`gpio_config`,
`gpio_config[0].pin`, `my_struct.field`, and so on). C expressions are
resolved through the active nvim-dap/GDB session (`&(expr)` / `sizeof(expr)`)
while the target is halted. Their debug-info children are expanded recursively
for structs and arrays, including pointer values and optional dereferenced
children. The resulting address/type plan is then sampled from OpenOCD telnet
while the target runs; running samples never issue DAP/GDB requests. Add or
refresh a new C expression while stopped, or stop once to hydrate it.

Lua API: `require('cortex').start/stop/toggle/add/clear/refresh/telnet/status`.

## Debugging the adapter

```sh
CORTEX_DAP_LOG=/tmp/cortex-dap.log nvim   # or CORTEX_DAP_LOG=1 for stderr
```

## Tests

```sh
./tests/run.sh
```

* syntax check of every Lua file
* `tests/test_adapter.lua` — MI parser, DAP framing, `${}` expansion, OpenOCD
  argv, capabilities, stop-event mapping, gdb path/target resolution
* `tests/test_e2e.lua` — spawns the real adapter process and drives a full DAP
  session (initialize → launch → breakpoints → configurationDone → stopped →
  threads/stack/scopes/variables/evaluate → step/continue/pause →
  terminate/disconnect) against `tests/fake_gdb.lua` and
  `tests/fake_openocd.lua`
