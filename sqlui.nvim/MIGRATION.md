# Migration to sqlui.nvim

This document tracks the migration from the old in-config SQL workflow to the standalone `sqlui.nvim` plugin.

## Current State

The active Neovim configuration already routes SQL keymaps and commands through `sqlui.nvim`.

Migrated runtime features:

- connection selection and management
- current buffer execution
- visual selection execution
- run on last connection
- SQL history
- CSV export
- XLSX export
- schema browser
- schema cache build/clear
- cached completion source for `nvim-cmp`
- `sqls` connection synchronization

## Removed Legacy Runtime

The legacy module `lua/config/usql_runner.lua` has been removed from the active config.

The source of truth is now the plugin repo at:

- `sqlui.nvim/`

## Next Migration Targets

1. expand automated tests around schema cache and export behavior
2. harden Linux secret backends and deletion workflows
3. polish plugin help and release metadata
4. prepare first public tagged release

## Recommended Validation

Run these after major changes:

```bash
nvim --headless +qa
nvim --headless "+checkhealth sqlui" +qa
```

Manual smoke checks:

- `:SqlUiSelectConnection`
- `:SqlUiRun`
- `:SqlUiRunSelection`
- `:SqlUiBrowser`
- `:SqlUiBuildCache`
- `:SqlUiExportCsv`
- `:SqlUiExportXlsx`
