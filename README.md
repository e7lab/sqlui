# sqlui.nvim

A Neovim plugin for SQL workflows. Execute queries, browse schemas, view data, export results, and manage connections — all from inside Neovim.

Built around [`usql`](https://github.com/xo/usql) with optional [`sqls`](https://github.com/sqls-server/sqls) LSP integration.

## Features

- **Multi-driver** — MSSQL, PostgreSQL, MySQL out of the box
- **Query execution** — run current buffer, visual selection, or last connection
- **Schema browser** — Telescope-powered browsable tree of tables, views, functions, procedures
- **Data viewer** — paginated table viewer with filters, column sorting, page size selector, fixed header
- **Persistent cache** — incremental schema cache with column metadata for fast browsing and completion
- **Completion** — `nvim-cmp` source powered by cached schema (tables, views, functions, procedures)
- **Export** — CSV and XLSX export of query results
- **Connection management** — save, edit, rename, duplicate, delete connections with schema picker
- **Secure storage** — macOS Keychain, Linux `secret-tool`, KWallet, or file fallback
- **Lualine integration** — shows active `alias/schema` in the statusline
- **Cross-platform** — macOS and Linux

## Requirements

- Neovim >= 0.9
- [`usql`](https://github.com/xo/usql) — universal SQL CLI
- [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) (recommended, native `vim.ui.select` fallback available)
- [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) (optional, for schema completion)
- [`sqls`](https://github.com/sqls-server/sqls) (optional, for LSP features)

## Installation

### lazy.nvim

```lua
{
  "e7lab/sqlui",
  name = "sqlui.nvim",
  lazy = false,
  config = function()
    require("sqlui").setup({
      ui = { picker = "auto" },
      secrets = { backend = "auto" },
      usql = { bin = "usql" },
    })
  end,
  keys = {
    { "<leader>ss", function() require("sqlui").menu() end, desc = "SQL menu" },
    { "<leader>ss", function() require("sqlui").menu_selection_from_visual() end, mode = "x", desc = "SQL menu (selection)" },
    { "<leader>sr", function() require("sqlui").run_last_connection() end, desc = "Run SQL (last connection)" },
    { "<leader>sr", function() require("sqlui").run_last_connection_selection_from_visual() end, mode = "x", desc = "Run SQL selection (last connection)" },
    { "<leader>se", function() require("sqlui").export_csv() end, desc = "Export to CSV" },
    { "<leader>se", function() require("sqlui").export_csv_selection_from_visual() end, mode = "x", desc = "Export selection to CSV" },
    { "<leader>sx", function() require("sqlui").export_xlsx() end, desc = "Export to XLSX" },
    { "<leader>sx", function() require("sqlui").export_xlsx_selection_from_visual() end, mode = "x", desc = "Export selection to XLSX" },
    { "<leader>sl", function() require("sqlui").select_connection() end, desc = "Select connection" },
    { "<leader>sb", function() require("sqlui").select_connection() end, desc = "Select database" },
    { "<leader>sa", function() require("sqlui").browser() end, desc = "Schema browser" },
    { "<leader>sc", function() require("sqlui").build_cache() end, desc = "Build schema cache" },
    { "<leader>sh", function() require("sqlui").history() end, desc = "SQL history" },
    { "<leader>s?", function() require("sqlui").help() end, desc = "Help" },
  },
}
```

### Minimal setup

```lua
require("sqlui").setup({
  ui = { picker = "auto" },
  secrets = { backend = "auto" },
})
```

## Keymaps

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ss` | n | Open SQL actions menu |
| `<leader>ss` | x | SQL menu with visual selection |
| `<leader>sr` | n | Run SQL with last connection |
| `<leader>sr` | x | Run selected SQL with last connection |
| `<leader>se` | n/x | Export to CSV |
| `<leader>sx` | n/x | Export to XLSX |
| `<leader>sl` | n | Select connection |
| `<leader>sb` | n | Select database connection |
| `<leader>sa` | n | Open schema browser |
| `<leader>sc` | n | Build schema cache |
| `<leader>sh` | n | SQL history |
| `<leader>s?` | n | Help / keybinding guide |

### Schema browser

| Key | Action |
|-----|--------|
| `<Enter>` | Open data viewer (tables/views) |
| `<C-y>` | Insert object name into buffer |

### Data viewer

| Key | Action |
|-----|--------|
| `]p` | Next page |
| `[p` | Previous page |
| `ff` | Set filter |
| `fc` | Clear filter |
| `fo` | Change order column |
| `fp` | Change page size (25/50/100/250/500) |
| `r` | Refresh |
| `q` | Close |

Filters support multiple conditions separated by `;`:

```
status=ativo;nome~joao
```

Operators: `=` (exact), `~` (contains/LIKE), `!=` (not equal), `>`, `<`, `>=`, `<=`.

## Commands

| Command | Description |
|---------|-------------|
| `:SqlUiMenu` | Open SQL actions menu |
| `:SqlUiRun` | Execute current buffer |
| `:SqlUiRunSelection` | Execute visual selection |
| `:SqlUiRunLastConnection` | Run with last used connection |
| `:SqlUiSelectConnection` | Select or manage connections |
| `:SqlUiBrowser` | Open schema browser |
| `:SqlUiViewData [schema.table]` | Open data viewer |
| `:SqlUiHistory` | Browse SQL history |
| `:SqlUiExportCsv` | Export to CSV |
| `:SqlUiExportXlsx` | Export to XLSX |
| `:SqlUiBuildCache` | Build schema cache |
| `:SqlUiClearCache` | Clear schema cache |
| `:SqlUiHelp` | Show help |
| `:checkhealth sqlui` | Check dependencies |

## Connection management

`<leader>sb` opens the connection picker with these options:

- **Saved connections** — select and connect with schema picker
- **+ Nova conexao salva** — create a new saved connection (alias + DSN)
- **+ Editar conexao salva** — edit an existing connection's DSN
- **+ Renomear conexao salva** — rename a connection alias
- **+ Duplicar conexao salva** — duplicate an existing connection
- **+ Remover conexao salva** — delete a connection
- **+ Conexao temporaria** — one-time connection (not persisted)

DSN format follows `usql` conventions:

```
postgres://user:password@host:5432/database
mssql://user:password@host/database
mysql://user:password@host:3306/database
sqlserver://user:password@host?database=dbname
```

> Passwords with special characters must be URL-encoded in the DSN.

## Secure storage

Credentials are stored using the platform's native secret manager:

| Platform | Backend |
|----------|---------|
| macOS | Keychain (`security` CLI) |
| Linux (GNOME) | `secret-tool` |
| Linux (KDE) | `kwallet-query` |
| Fallback | Local file (development only) |

## Lualine integration

Add to your lualine config to show the active connection in the statusline:

```lua
lualine_x = {
  { require("sqlui.integrations.lualine").connection_status },
}
```

Displays: `alias/schema` when connected, empty otherwise.

## Architecture

```
sqlui.nvim/
├── lua/sqlui/
│   ├── init.lua              -- setup and public API
│   ├── config.lua            -- defaults and config merge
│   ├── state.lua             -- persistent state (aliases, history, cache paths)
│   ├── connection/           -- connection CRUD, schema picker, driver detection
│   ├── runner/               -- query execution, exports, history
│   ├── schema/               -- schema browser, cache, completion items
│   ├── data_viewer/          -- paginated data viewer with filters
│   ├── completion/           -- nvim-cmp source
│   ├── lsp/                  -- sqls LSP integration
│   ├── secrets/              -- platform secret backends
│   ├── integrations/         -- telescope, lualine
│   ├── ui/                   -- picker/input abstraction
│   └── util/                 -- fs, platform detection
├── plugin/sqlui.lua          -- Ex commands
├── doc/sqlui.txt             -- :help sqlui
├── health/                   -- :checkhealth
└── tests/                    -- smoke and regression tests
```

## License

MIT
