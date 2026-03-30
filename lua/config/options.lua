-- Options migrated from init.vim

vim.cmd("syntax on")

-- Better colors in modern terminals + enables transparent backgrounds from colorschemes.
vim.opt.termguicolors = true

-- Target opacity for UI elements that support blending.
-- Your terminal is at ~0.90 opacity; this keeps Neovim a bit LESS transparent.
local ui_opacity = 0.93

-- 0..100 (higher = more transparent) for floating UI (pum/floats).
-- Note: the main editor background in a terminal can't have per-app opacity.
local blend = math.floor((1 - ui_opacity) * 100 + 0.5)
vim.opt.winblend = blend
vim.opt.pumblend = blend

-- If you're using Neovide, set black background with alpha.
if vim.g.neovide then
  local alpha = math.floor(ui_opacity * 255 + 0.5)
  vim.g.neovide_background_color = string.format("#000000%02X", alpha)
end

vim.opt.number = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smarttab = true
vim.opt.smartindent = true
vim.opt.hidden = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.scrolloff = 8
vim.opt.colorcolumn = "125"
vim.opt.signcolumn = "yes"
vim.opt.cmdheight = 2
vim.opt.updatetime = 10
vim.opt.encoding = "utf-8"
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.autoread = true
vim.opt.mouse = "a"
