local platform = require("sqlui.util.platform")
local secrets = require("sqlui.secrets")

local M = {}

function M.check()
  vim.health.start("sqlui.nvim")

  -- Phase 6: All database operations now via RPC (easysql sidecar)
  -- No need to check for usql, sqlcmd, or python3
  vim.health.ok("easysql RPC mode: all database operations delegated to sidecar")

  local backend = secrets.resolve("auto")
  if backend and backend.available() then
    vim.health.ok("secret backend available: " .. backend.name())
  else
    vim.health.warn("no secure secret backend detected; fallback may be required")
  end
end

return M
