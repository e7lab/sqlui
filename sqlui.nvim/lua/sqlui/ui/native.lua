local M = {}

function M.select(items, opts, on_choice)
  vim.ui.select(items, opts or {}, on_choice)
end

function M.input(opts, on_confirm)
  vim.ui.input(opts or {}, on_confirm)
end

return M
