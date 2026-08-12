# cortex.nvim

cortex.nvim provides an ARM Cortex-M debug adapter and target-aware debugging views for Neovim.

## Features

| Capability | Behavior |
| --- | --- |
| DAP adapter | Runs in a headless Neovim process, drives GDB/MI, and supports launch or attach through OpenOCD or an external GDB server. |
| Live Watch | Samples addresses, OpenOCD commands, and hydrated C expressions through the OpenOCD telnet port while the target runs. |
| SVD peripherals | Parses CMSIS-SVD files and reads expanded peripheral registers through a separate telnet connection while stopped. |
| FreeRTOS tasks | Walks FreeRTOS kernel lists through the stopped DAP/GDB session. |
| Call stack | Shows and selects frames from the current stopped DAP thread. |
| Target selection | Remembers a `.vscode/launch.json` configuration per workspace. |

The adapter implements the DAP requests used for breakpoints, execution control,
threads, stacks, scopes, variables, evaluation, variable writes, memory reads,
and session teardown. Standard nvim-dap views continue to provide registers,
scopes, watches, and the REPL.

## Requirements

- Neovim 0.10 or newer.
- [nvim-dap](https://github.com/mfussenegger/nvim-dap), which is required and
  must be available when `setup()` runs.
- `arm-none-eabi-gdb` on `PATH`, or another GDB selected with `gdbPath`,
  `toolchainPrefix`, and `toolchainPath`.
- OpenOCD for `servertype = "openocd"`, or an already running GDB server for
  `servertype = "external"`. Live Watch and the peripheral view additionally
  need an OpenOCD-compatible telnet endpoint.

## Installation

`require('cortex').setup()` is required; it registers the adapter, listeners,
and commands. See `:help cortex.nvim` for the in-editor reference.

### vim.pack (Neovim 0.11+)

```lua
vim.pack.add({
  { src = 'https://github.com/mfussenegger/nvim-dap' },
  { src = 'https://github.com/ronakpjain/cortex.nvim' },
})

require('cortex').setup({})
```

### lazy.nvim

```lua
{
  'ronakpjain/cortex.nvim',
  dependencies = { 'mfussenegger/nvim-dap' },
  config = function()
    require('cortex').setup({})
  end,
}
```

## Quick start

1. Install GDB and either OpenOCD or an external GDB server.
2. Add a `cortex-debug` entry to `.vscode/launch.json`, using the example below.
3. Start from the project with `:CortexDebugStart`. The first invocation asks
   for a target; later invocations reuse it or continue the active session.
4. Set breakpoints and control execution with normal nvim-dap commands or
   keymaps. Open the optional Cortex views with the commands below.

The remembered selection is keyed by the nearest directory containing
`.vscode/launch.json` and stored under
`stdpath('state')/cortex.nvim/targets.json`. Project files are never modified.

## Setup

All fields are optional, but the `setup()` call itself is required. This is a
representative configuration showing the defaults most often changed:

```lua
require('cortex').setup({
  mouse = true,

  peripheral = {
    auto_refresh_on_stop = true,
    svdFile = '${workspaceFolder}/support/device.svd',
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    read_all = false,
  },

  rtos = {
    enabled = false,
    auto_open = false,
    auto_refresh_on_stop = true,
    max_tasks = 128,
    max_priorities = nil,
    tcb_type = 'TCB_t',
    list_item_type = 'ListItem_t',
    stack_growth = -1,
    stack_word_bytes = 4,
    symbols = {},
    fields = {},
  },

  callstack = {
    auto_open = false,
    auto_refresh_on_stop = true,
    levels = 0,
  },

  live_watch = {
    auto_open = true,
    samples_per_second = 4,
    host = '127.0.0.1',
    port = 4444,
    timeout_ms = 1000,
    max_depth = 4,
    max_children = 32,
    expressions = {},
  },

  window = {
    position = 'right', -- right, left, top, bottom, or float
    width = 60,
    height = 12,
    border = 'rounded',
    focus_on_open = false,
  },
})
```

| Setup key | Default | Purpose |
| --- | --- | --- |
| `nvim` | `vim.v.progpath` | Neovim executable used to host the adapter. |
| `adapter_path` | bundled `adapter_main.lua` | Override the adapter entry script. |
| `adapter_args` | `{}` | Arguments appended after the adapter script. |
| `adapter_name` | `cortex-debug` | Name registered in `dap.adapters`. |
| `filetypes` | `c`, `cpp`, `rust`, `asm` | Mapping used by nvim-dap's legacy `load_launchjs()` path. |
| `mouse` | `true` | Appends `a` to Neovim's `mouse` option for view actions. |
| `peripheral.svdFile`, `peripheral.svdPath` | none | Default CMSIS-SVD path; `svdFile` has precedence. |
| `peripheral.host`, `peripheral.port`, `peripheral.timeout_ms` | `127.0.0.1`, `4444`, `1000` | Endpoint and timeout for stopped register reads. |
| `peripheral.read_all` | `false` | Read all peripherals rather than only expanded ones. |
| `rtos.symbols`, `rtos.fields` | built-in FreeRTOS names | Override firmware-specific kernel symbols or TCB fields. |
| `peripheral.window`, `rtos.window`, `callstack.window` | shared `window` | Per-view layout override. |

`window` tables accept `position`, `width`, `height`, `border`, and
`focus_on_open`. Partial nested tables are merged with defaults.

## Launch configuration

nvim-dap reads `cortex-debug` entries from `.vscode/launch.json`. A minimal
OpenOCD launch can be expanded as follows:

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug firmware",
      "type": "cortex-debug",
      "request": "launch",
      "cwd": "${workspaceFolder}",
      "executable": "${workspaceFolder}/build/app.elf",
      "servertype": "openocd",
      "configFiles": [
        "interface/stlink.cfg",
        "target/stm32f4x.cfg"
      ],
      "gdbPath": "arm-none-eabi-gdb",
      "serverpath": "openocd",
      "gdbPort": 3333,
      "telnetPort": 4444,
      "runToEntryPoint": "main",
      "svdFile": "${workspaceFolder}/support/device.svd",
      "liveWatch": {
        "enabled": true,
        "samplesPerSecond": 4
      }
    }
  ]
}
```

### Session and toolchain options

| Key | Default | Meaning |
| --- | --- | --- |
| `request` | `launch` | `launch` resets/downloads; `attach` skips that sequence. Both can spawn OpenOCD. |
| `executable` or `program` | none | ELF used for symbols and, on launch, download. |
| `cwd` | editor working directory | Working directory for GDB and OpenOCD. |
| `servertype` or `serverType` | `openocd` | `openocd` or `external`; external does not spawn a server. |
| `gdbPath` | `<toolchainPrefix>-gdb` | GDB executable. |
| `toolchainPrefix` | `arm-none-eabi` | Prefix used when `gdbPath` is absent. |
| `toolchainPath` | none | Directory prepended to a bare GDB executable name. |
| `gdbArgs` or `debuggerArgs` | none | Additional GDB arguments. |
| `gdbTarget` | `localhost:<gdbPort>` | GDB server host, optionally including a port. |
| `gdbPort` | `3333` | GDB server port. |
| `env` | inherited environment | Additional environment values for GDB and spawned OpenOCD. |

### OpenOCD and startup options

| Key | Default | Meaning |
| --- | --- | --- |
| `serverpath` or `serverPath` | `openocd` | OpenOCD executable. |
| `configFiles` | none | OpenOCD configuration files, each passed with `-f`. |
| `searchDir` | none | OpenOCD search directories, each passed with `-s`. |
| `serverArgs` | none | Additional OpenOCD arguments. |
| `openOCDLaunchCommands` or `openocdLaunchCommands` | none | OpenOCD commands, each passed with `-c`. |
| `telnetPort` | `4444` | OpenOCD telnet port. |
| `serverStartTimeout` | `20` seconds | Wait for the GDB server port; values above 1000 are treated as milliseconds. |
| `loadFiles` | `true` | Set to `false` to skip `-target-download` on launch. |
| `runToEntryPoint` | none | Set a temporary breakpoint, continue, and report an `entry` stop. |
| `runToMain` | none | Legacy alias for `runToEntryPoint = "main"`. |
| `stopAtEntry` | `true` | Stay stopped after setup when no entry point is requested. |
| `noDebug` | `false` | Continue immediately after configuration. |

### Command and view options

| Key | Meaning |
| --- | --- |
| `preLaunchCommands`, `postLaunchCommands` | GDB console commands, or MI commands when prefixed with `-`, around launch setup. |
| `preAttachCommands`, `postAttachCommands` | Equivalent command lists for attach. |
| `overrideLaunchCommands` | Replace the default launch reset/download/reset sequence. |
| `overrideAttachCommands` | Commands run after the attach connection instead of an otherwise empty attach sequence. |
| `liveWatch` | `enabled`, `samplesPerSecond`, `telnetPort`, `maxDepth`, and `maxChildren`. Sampling is capped at 20 Hz. |
| `svdFile`, `svdPath` | SVD path; launch `svdFile` wins over `svdPath` and setup values. |
| `telnetHost`, `openocdTelnetHost` | Live Watch telnet host. |
| `openocdTelnetPort` | Alternative top-level telnet port. |
| `svdTelnetHost`, `peripheralTelnetHost` | Peripheral-view host override. |
| `svdTelnetPort`, `peripheralTelnetPort` | Peripheral-view port override. |
| `peripheral` | `autoRefreshOnStop` and SVD/window options. |
| `rtos` | `enabled`, `autoOpen`, `autoRefreshOnStop`, `maxTasks`, `maxPriorities`, `tcbType`, `listItemType`, `stackGrowth`, `stackWordBytes`, `symbols`, and `fields`. |
| `callstack` | `autoOpen`, `autoRefreshOnStop`, and `levels`; `stackLevels` is an alias for `levels`. |

The adapter recursively expands `${workspaceFolder}`, `${workspaceRoot}`,
`${cwd}`, `${userHome}`, `${file}`, `${fileDirname}`, `${fileBasename}`,
`${fileBasenameNoExtension}`, and `${pathSeparator}` when nvim-dap has not
already expanded them.

## Commands

### Target selection

| Command | Action |
| --- | --- |
| `:CortexDebugStart` | Continue an active session, run the remembered target, or select one. |
| `:CortexDebugSelect` | Select and remember a launch target for the workspace. |
| `:CortexDebugTarget` | Show the remembered target. |
| `:CortexDebugClearTarget` | Forget the remembered target. |

### Live Watch and telnet

| Command | Action |
| --- | --- |
| `:CortexDebugWatch` | Toggle Live Watch. |
| `:CortexDebugWatchAdd [expr]` | Add an expression; prompt when omitted. |
| `:CortexDebugWatchClear` | Remove all expressions. |
| `:CortexDebugTelnet [command]` | Send a raw OpenOCD command; prompt when omitted. |

### Stopped views

| Command | Action |
| --- | --- |
| `:CortexDebugPeripheral` | Toggle the CMSIS-SVD peripheral view. |
| `:CortexDebugPeripheralRefresh` | Read register values while stopped. |
| `:CortexDebugRTOS` | Toggle the FreeRTOS task view. |
| `:CortexDebugRTOSRefresh` | Walk task lists while stopped. |
| `:CortexFreeRTOS` | Alias for `:CortexDebugRTOS`. |
| `:CortexDebugCallStack` | Toggle the current-thread stack. |
| `:CortexDebugCallStackRefresh` | Request the current stack while stopped. |
| `:CortexDebugStack` | Alias for `:CortexDebugCallStack`. |

## View behavior and keymaps

| View | Data and refresh behavior | Buffer-local keys |
| --- | --- | --- |
| Live Watch | Raw addresses and recognized OpenOCD commands sample directly. C expressions use DAP/GDB while stopped to resolve address, size, and children, then use telnet while running. | `a` add, `d` delete, `c` clear, `r` hydrate/sample, `q` close |
| SVD peripherals | Loads the configured SVD and reads register memory only while stopped. It decodes register widths, endianness, masks, bitfields, and enumerated values. | `<CR>` expand/collapse, `r` refresh, `q` close |
| FreeRTOS tasks | Walks ready, delayed, pending, suspended, and termination lists only while stopped; missing optional symbols are skipped. | `r` refresh, `q` close |
| Call stack | Requests `stackTrace` for the current stopped thread; it is not a per-task FreeRTOS unwinder. | `<CR>` select frame, `r` refresh, `q` close |

Single and double left clicks perform the corresponding row action in the SVD
and call-stack views; in the RTOS view they position the cursor. A single Live
Watch click positions the cursor. Live Watch accepts addresses such as
`0x20000010`, commands such as `reg` or
`mdw 0x20000000 4`, and C expressions such as `config[0].field`. Add or refresh
a new C expression while stopped so its metadata can be hydrated.

## nvim-dap-ui integration

The three stopped views can be registered as nvim-dap-ui elements before
`dapui.setup()`:

```lua
local cortex = require('cortex')
local dapui = require('dapui')

dapui.register_element('cortex_callstack', cortex.callstack_element())
dapui.register_element('cortex_rtos', cortex.rtos_element())
dapui.register_element('cortex_peripherals', cortex.peripheral_element())

dapui.setup({
  layouts = {
    {
      position = 'right',
      size = 60,
      elements = {
        { id = 'cortex_callstack', size = 0.25 },
        { id = 'cortex_rtos', size = 0.35 },
        { id = 'cortex_peripherals', size = 0.40 },
      },
    },
  },
})
```

`close_views()` closes standalone Cortex windows and cancels pending view
reads. Standard dap-ui elements can be used in the same layouts.

## Public Lua API

Use these after `local cortex = require('cortex')`; call `setup()` first.
Callbacks use `(error, data)` where applicable.

| Area | Functions |
| --- | --- |
| Configuration | `setup(opts)` |
| Adapter paths | `adapter_nvim()`, `adapter_script()` |
| Live Watch | `start(opts)`, `stop(opts)`, `open()`, `close()`, `toggle()`, `add(expr)`, `clear()`, `remove_at_line(line)`, `refresh()`, `telnet(command, callback)`, `status()` |
| Peripherals | `peripheral_open()`, `peripheral_close()`, `peripheral_toggle()`, `peripheral_refresh(callback)`, `peripheral_load(config)`, `peripheral_element()` |
| FreeRTOS | `rtos_open()`, `rtos_close()`, `rtos_toggle()`, `rtos_refresh(callback)`, `rtos_element()` |
| Call stack | `callstack_open()`, `callstack_close()`, `callstack_toggle()`, `callstack_refresh(callback)`, `callstack_element()` |
| Targets | `debug_start()`, `debug_select()`, `debug_target()`, `debug_clear_target()` |
| Views | `close_views()` |

Underscore-prefixed fields are internal.

## Troubleshooting and logging

- If commands or the adapter are missing, confirm that nvim-dap loads before
  `require('cortex').setup()` and that `setup()` is actually called.
- If a target cannot be selected, run Neovim below a project containing
  `.vscode/launch.json`; a removed or renamed saved target triggers selection
  again.
- If GDB or OpenOCD does not start, use absolute `gdbPath` and `serverpath`
  values, then inspect nvim-dap output and `:messages`.
- With `servertype = "external"`, start the server yourself and verify
  `gdbTarget` and `gdbPort`. Configure a separate telnet endpoint if using Live
  Watch or SVD registers.
- SVD, FreeRTOS, and call-stack views refresh automatically whenever they are
  open or embedded in dap-ui and the target stops. Set
  `auto_refresh_on_stop = false` (or launch `autoRefreshOnStop = false`) on a
  view to opt out. Manual refresh still requires a stopped target. Check the
  SVD path, firmware debug information, and `rtos.symbols`/`rtos.fields`
  overrides.
- A new Live Watch C expression must be resolved while stopped before it can be
  sampled while running.

Enable adapter protocol and GDB/MI logging before starting Neovim:

```sh
CORTEX_DAP_LOG=/tmp/cortex-dap.log nvim
# Use CORTEX_DAP_LOG=1 to write to stderr instead.
```

## Development and tests

Run the complete suite with Neovim 0.10 or newer:

```sh
./tests/run.sh
```

The script checks Lua syntax and runs unit, transport, UI, target, SVD,
peripheral, FreeRTOS, call-stack, Live Watch, launch, and attach suites. The
e2e tests use bundled fake GDB and OpenOCD processes. CI also runs
`stylua --check .`.
