local M = {}

function M.available()
  return vim.fn.executable("kwallet-query") == 1
end

function M.name()
  return "linux-kwallet"
end

return M
