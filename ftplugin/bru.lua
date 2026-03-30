-- ftplugin/bru.lua
-- Indentation settings for Bruno (.bru) files.
-- The bru format uses braces {} for blocks, similar to C-style languages.

vim.opt_local.expandtab  = true
vim.opt_local.shiftwidth = 2
vim.opt_local.tabstop    = 2
vim.opt_local.softtabstop = 2

-- Use a simple brace-based indent expression as fallback when the
-- tree-sitter parser is not yet compiled.
if not pcall(vim.treesitter.get_parser, 0, "bruno") then
  vim.opt_local.cindent    = true
  vim.opt_local.cinkeys    = vim.opt_local.cinkeys + "{"
  vim.opt_local.cinkeys    = vim.opt_local.cinkeys + "}"
  vim.opt_local.indentkeys = vim.opt_local.indentkeys + "{"
  vim.opt_local.indentkeys = vim.opt_local.indentkeys + "}"
end
