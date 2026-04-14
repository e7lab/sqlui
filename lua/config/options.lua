-- Options migrated from init.vim

vim.cmd("syntax on")

-- Better colors in modern terminals + enables transparent backgrounds from colorschemes.
vim.opt.termguicolors = true

-- Transparency is provided by the terminal emulator, not by Neovim blending.
-- winblend/pumblend > 0 cause ghost artifacts when Normal bg = NONE because
-- Neovim has no solid colour to composite against.
vim.opt.winblend = 0
vim.opt.pumblend = 0

-- Neovide: use its own alpha channel instead of winblend.
if vim.g.neovide then
  local ui_opacity = 0.93
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
