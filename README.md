# cortex.nvim

A self-contained ARM Cortex-M debugging plugin for Neovim.

* **Pure Lua DAP adapter** (`lua/cortex/adapter.lua`) — drives
  `arm-none-eabi-gdb --interpreter=mi2` and OpenOCD, speaks Content-Length
  framed DAP JSON on stdin/stdout.
* **Native OpenOCD Live Watch** (`lua/cortex/init.lua`) — a libuv TCP telnet
  client that samples memory/symbols while the target is *running*.
* **Stopped-only SVD peripheral browser** (`lua/cortex/peripheral.lua`) — a
  separate read-only register/bitfield tree using its own telnet client.
* **Stopped-only FreeRTOS task browser** (`lua/cortex/rtos.lua`) — walks
  FreeRTOS kernel task lists through stopped GDB expressions.
* **Stopped-only current call-stack window** (`lua/cortex/callstack.lua`) —
  displays the ordinary DAP/GDB stack for the halted CPU thread.
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
  mouse = true,                 -- enable mouse actions in Cortex windows

  peripheral = {
    -- Either may also be supplied by launch config as svdFile/svdPath.
    svdFile = '${workspaceFolder}/support/svd/STM32G474.svd',
    svdPath = nil,
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    read_all = false,          -- refresh only expanded peripherals by default
  },

  rtos = {
    enabled = false,
    auto_open = false,
    auto_refresh_on_stop = false,
    max_tasks = 128,
    max_priorities = nil, -- probe from the ELF; fallback is 32
    tcb_type = 'TCB_t',
    list_item_type = 'ListItem_t',
    -- Override symbols/fields when a kernel or port renames them.
    symbols = {},
    fields = {},
  },

  callstack = {
    auto_open = false,
    auto_refresh_on_stop = false,
    levels = 0,
  },

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
| `svdFile` / `svdPath` | – | CMSIS-SVD path for the stopped-only peripheral browser |
| `rtos` | – | `{ enabled, autoOpen, autoRefreshOnStop }` for the FreeRTOS task browser |
| `callstack` | – | `{ autoOpen, autoRefreshOnStop, levels }` for the current DAP stack window |

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

Out of scope (by design): pre/postLaunchTask, semihosting UIs, disassembly.

## Persistent target selection

Use the Cortex commands instead of the raw `:DapContinue` picker:

| command | action |
| --- | --- |
| `:CortexDebugStart` | start the remembered target, or choose one the first time |
| `:CortexDebugSelect` | choose and remember a target for this workspace |
| `:CortexDebugTarget` | show the remembered target |
| `:CortexDebugClearTarget` | forget the remembered target |

The selection is keyed by the nearest workspace containing `.vscode/launch.json`
and is stored in Neovim's state directory at
`cortex.nvim/targets.json`. The plugin only reads project launch files; it
never writes into the project. If a saved target disappears, the selector
opens again. A normal active session still uses `:CortexDebugStart` to
continue it.

## FreeRTOS task view

Enable it in a launch configuration or open it manually:

```jsonc
"rtos": {
  "enabled": true,
  "autoOpen": true,
  "autoRefreshOnStop": false
}
```

Commands:

| command | action |
| --- | --- |
| `:CortexDebugRTOS` | toggle the stopped-only task view |
| `:CortexDebugRTOSRefresh` | walk and refresh task data while stopped |
| `:CortexFreeRTOS` | alias for `:CortexDebugRTOS` |

The view reads `TCB_t`/`List_t` data through GDB and walks ready, blocked,
pending, suspended, and termination lists. It displays the task name, state,
priority, runtime counter, stack estimate, and TCB address. Missing optional
kernel symbols are skipped; `rtos.symbols`, `rtos.fields`, `maxTasks`, and
`maxPriorities` can override firmware-specific names and limits. It never
polls while running and never shares the Live Watch or SVD connections.

## Call-stack window

`:CortexDebugCallStack` opens a separate view of the current stopped CPU
thread's DAP/GDB stack. `r` or `:CortexDebugCallStackRefresh` refreshes it,
`<CR>` or a mouse click selects a frame, and `q` closes it. This is intentionally the normal
DAP stack, not an attempted unwinder for every FreeRTOS task; dapui remains
available for the same session.

| command | action |
| --- | --- |
| `:CortexDebugCallStack` | toggle the current stopped-thread stack |
| `:CortexDebugCallStackRefresh` | request `stackTrace` while stopped |
| `:CortexDebugStack` | alias for `:CortexDebugCallStack` |

## nvim-dap-ui integration

The auxiliary views can be embedded in nvim-dap-ui layouts without forking
nvim-dap-ui. Register `cortex_callstack`, `cortex_rtos`, and
`cortex_peripherals` with `dapui.register_element()` using the corresponding
`callstack_element()`, `rtos_element()`, and `peripheral_element()` APIs. They
then behave like normal dapui layout panes; the SVD pane includes the
peripheral rows above its registers. `close_views()` closes standalone Cortex
windows and cancels their pending reads.

## Five value views

These views are intentionally separate:

* **DAP CPU registers/scopes** are the live nvim-dap/GDB register and scope
  panes. They follow the selected stack frame and preserve normal DAP behavior.
* **SVD peripheral view** is `:CortexDebugPeripheral`. It shows peripheral →
  register → bitfield rows from the SVD and reads register memory only after
  `:CortexDebugPeripheralRefresh` (or `r`) while the target is stopped. It
  decodes register width/endianness, masks, and enumerated field names.
* **FreeRTOS tasks** are shown by `:CortexDebugRTOS`. The view is a separate
  stopped-only GDB task-list walk; it is not merged into DAP threads, SVD
  values, or Live Watch polling.
* **Call stack** is shown by `:CortexDebugCallStack`. It requests only the
  current stopped DAP thread's stack and is independent of the RTOS task list.
* **Live Watch** is the native `:CortexDebugWatch` window. It uses its own
  polling socket for memory/symbol samples while running; SVD and RTOS values
  are never merged into that queue or window.

SVD paths expand `${workspaceFolder}`, `${workspaceRoot}`, and `${cwd}`.
Launch configuration `svdFile` takes precedence over `svdPath`; setup options
may provide either key as well.

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
`q` close. Clicking a peripheral or register expands it, and clicking a
call-stack row selects that frame. Enable Neovim
mouse input with `vim.opt.mouse = 'a'` if your configuration does not already.

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
Persistent DAP target API: `debug_start()`, `debug_select()`,
`debug_target()`, and `debug_clear_target()`.

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
