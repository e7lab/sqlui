local M = {}

function M.os_name()
  local uname = vim.uv.os_uname()
  return uname.sysname
end

function M.is_macos()
  return M.os_name() == "Darwin"
end

function M.is_linux()
  return M.os_name() == "Linux"
end

function M.has_executable(bin)
  return vim.fn.executable(bin) == 1
end

return M
