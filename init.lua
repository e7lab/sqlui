-- NOTE: Neovim errors with E5422 if both init.lua and init.vim exist.
-- This config uses init.lua as the single entrypoint.

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local config_paths = require("config.paths")

vim.opt.runtimepath:append(config_paths.sqlui_dir)

-- Disable netrw early (prevents gx/BrowserX behavior)
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

require("config.options")
require("config.keymaps")
require("config.autocmds")
require("config.lsp").setup()
require("config.lazy")
