local M = {}

-- Phase 6: Configuration updated for RPC-based execution
-- usql/sqlcmd/python3 are no longer required; all operations delegated to easysql RPC
M.defaults = {
  ui = {
    picker = "auto",
  },
  secrets = {
    backend = "auto",
  },
  easysql = {
    bin = "easysql",
    request_timeout_ms = 30000,
    restart_on_crash = true,
  },
  sqls = {
    enabled = true,
    auto_sync_connection = true,
  },
  cache = {
    enabled = true,
    persistent = true,
    schema_object_limit = 30,
    schema_page_size = 15,
    debounce_ms = 300,
    routine_preview_line_limit = 40,
  },
  history = {
    limit = 20,
  },
  keymaps = {
    enable = false,
    prefix = "<leader>s",
  },
  logging = {
    level = vim.log.levels.INFO,
  },
}

function M.merge(user_opts)
  return vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
end

return M
