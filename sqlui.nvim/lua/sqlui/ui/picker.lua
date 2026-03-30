local native = require("sqlui.ui.native")
local telescope = require("sqlui.integrations.telescope")

local M = {}

function M.select(items, opts, on_choice)
  if telescope.available() then
    return telescope.select(items, opts, on_choice)
  end
  return native.select(items, opts, on_choice)
end

function M.input(opts, on_confirm)
  if telescope.available() then
    return telescope.input(opts, on_confirm)
  end
  return native.input(opts, on_confirm)
end

return M
