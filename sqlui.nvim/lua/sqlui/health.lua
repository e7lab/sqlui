local platform = require("sqlui.util.platform")
local secrets = require("sqlui.secrets")

local M = {}

function M.check()
  vim.health.start("sqlui.nvim")

  if platform.has_executable("usql") then
    vim.health.ok("usql found")
  else
    vim.health.warn("usql not found in PATH")
  end

  if platform.has_executable("sqlcmd") then
    vim.health.ok("sqlcmd found (required for MSSQL BEGIN TRAN/COMMIT support)")
  else
    vim.health.info("sqlcmd not found; install via 'brew install sqlcmd' to enable MSSQL sqlcmd runner")
  end

  if platform.has_executable("python3") then
    vim.health.ok("python3 found")
  else
    vim.health.warn("python3 not found in PATH; XLSX export may be unavailable")
  end

  local backend = secrets.resolve("auto")
  if backend and backend.available() then
    vim.health.ok("secret backend available: " .. backend.name())
  else
    vim.health.warn("no secure secret backend detected; fallback may be required")
  end

  if platform.has_executable("sqls") then
    vim.health.ok("sqls found")
  else
    vim.health.info("sqls not found; autocomplete/LSP sync stays optional")
  end
end

return M
