# sqlui.nvim

`sqlui.nvim` is a Neovim plugin scaffold for SQL workflows built around `usql`, optional `sqls`, cache-aware browsing, and portable connection storage.

This repository is the standalone extraction target for the SQL workflow currently used in the author's personal Neovim configuration.

## Status

Active extraction build.

Already implemented in the standalone plugin:

- core setup and public commands
- connection selection and secure backend resolution
- current buffer execution with `usql`
- visual selection execution
- run with last connection
- persistent history
- CSV export
- XLSX export
- schema browser with Telescope fallback to native UI
- table/view data viewer with pagination and filter support
- persistent schema cache with build/clear commands
- lazy column cache by default, with optional eager preload
- cached completion source for `nvim-cmp`
- `sqls` connection sync managed by the plugin
- healthcheck scaffold

Still being migrated:

- richer help picker/actions
- broader Linux secret backend behavior
- automated tests and CI

## Planned Features

- Connection management with secure secret backends
- Query execution with `usql`
- CSV and XLSX export
- Optional `sqls` integration
- Schema browser with cache support
- Cached completion source
- Telescope UI with native fallback
- Cross-platform support for macOS and Linux

## Repo Layout

- `lua/sqlui/` - core plugin modules
- `plugin/sqlui.lua` - Ex commands
- `doc/sqlui.txt` - `:help sqlui`
- `tests/` - smoke and future regression tests

## Installation

### lazy.nvim

```lua
{
  dir = vim.fn.stdpath("config") .. "/sqlui.nvim",
  name = "sqlui.nvim",
  lazy = false,
  config = function()
    require("sqlui").setup({
      ui = { picker = "auto" },
      secrets = { backend = "auto" },
      usql = { bin = "usql" },
    })
  end,
}
```

### Minimal Setup

```lua
require("sqlui").setup({
  ui = {
    picker = "auto",
  },
  secrets = {
    backend = "auto",
  },
})
```

## Commands

- `:SqlUiMenu`
- `:SqlUiRun`
- `:SqlUiRunSelection`
- `:SqlUiRunLastConnection`
- `:SqlUiSelectConnection`
- `:SqlUiBrowser`
- `:SqlUiViewData [schema.table]`
- `:SqlUiHistory`
- `:SqlUiExportCsv`
- `:SqlUiExportXlsx`
- `:SqlUiBuildCache`
- `:SqlUiClearCache`
- `:SqlUiHelp`
- `:checkhealth sqlui`

## Current Test Flow

Use these commands in the current build:

- `:SqlUiSelectConnection` - select or manage a connection
- `:SqlUiRun` - execute the current SQL buffer
- `:SqlUiRunSelection` - execute the selected SQL
- `:SqlUiRunLastConnection` - run the current SQL on the last connection
- `:SqlUiHistory` - re-run an item from SQL history
- `:SqlUiExportCsv` - export current SQL to CSV
- `:SqlUiExportXlsx` - export current SQL to XLSX
- `:SqlUiBrowser` - browse schemas and SQL objects
- `:SqlUiViewData` - open paginated data viewer for a table/view
- `:SqlUiBuildCache` - build persistent schema cache
  - object metadata is cached first; columns are fetched on demand by default
- `:SqlUiClearCache` - clear persistent schema cache
- `<leader>sc` builds cache for the current connection (or the last saved one)

Inside the schema browser:

- `<Enter>` on tables/views opens the data viewer
- `<C-y>` inserts the selected object name into the current buffer

Inside the data viewer:

- `]p` / `[p` paginate
- `ff` set filter
- `fc` clear filter
- `fo` change order column
- `r` refresh
- `q` close viewer
- multiple filters are supported with `;`
  - example: `status=ativo;nome~joao`

## Architecture

- `lua/sqlui/init.lua` - public setup and command entrypoints
- `lua/sqlui/config.lua` - defaults and user config merge
- `lua/sqlui/state.lua` - runtime state and persisted aliases/history
- `lua/sqlui/connection/` - connection CRUD and secret backend selection
- `lua/sqlui/runner/` - execution, exports, and history integration
- `lua/sqlui/schema/` - schema browser and cache migration target
- `lua/sqlui/secrets/` - secure secret backends by platform
- `lua/sqlui/ui/` - picker/input abstraction
- `plugin/sqlui.lua` - Ex commands
- `doc/sqlui.txt` - `:help` documentation

## Platform Strategy

- macOS: `security` Keychain backend
- Linux GNOME: `secret-tool`
- Linux KDE: `kwallet-query`
- fallback: local file backend for development only

## Development Roadmap

1. stabilize runner and connection lifecycle
2. migrate schema browser and persistent cache
3. migrate completion and `sqls` integration
4. add Telescope-native UI module
5. add tests, CI, and first release tag

## Development Priorities

1. Core execution and connection lifecycle
2. Secret backend abstraction
3. Persistent schema cache
4. Browser and completion integration
5. Linux portability and CI
