local M = {}

local source = debug.getinfo(1, "S").source:sub(2)

M.config_root = vim.fn.fnamemodify(source, ":p:h:h:h")
M.sqlui_dir = M.config_root .. "/sqlui.nvim"

return M
