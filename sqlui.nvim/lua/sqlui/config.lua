local M = {}

M.defaults = {
  ui = {
    picker = "auto",
  },
  secrets = {
    backend = "auto",
  },
  usql = {
    bin = "usql",
  },
  sqls = {
    enabled = true,
    auto_sync_connection = true,
  },
  cache = {
    enabled = true,
    persistent = true,
    batch_size = 200,
    preload_columns = false,
    schema_object_limit = 30,
    debounce_ms = 300,
    live_search_min_chars = 3,
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
