-- ftplugin/bru.lua
-- Indentation and treesitter activation for Bruno (.bru) files.

vim.opt_local.expandtab   = true
vim.opt_local.shiftwidth  = 2
vim.opt_local.tabstop     = 2
vim.opt_local.softtabstop = 2

-- Ativa treesitter (highlight + indent via indents.scm).
-- vim.treesitter.start() ativa highlight; o indentexpr é definido pelo
-- módulo nvim-treesitter quando a query indents.scm estiver presente.
local ok_ts = pcall(vim.treesitter.start, 0, "bruno")

if ok_ts then
  -- nvim-treesitter define indentexpr via seu módulo de indent
  local ok_ind = pcall(function()
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter.indent'.get_indent(v:lnum)"
  end)
  if not ok_ind then
    -- fallback: linematch simples baseado em chaves
    vim.opt_local.cindent = true
  end
else
  -- Treesitter não disponível: usa cindent como fallback
  vim.opt_local.cindent = true
end
