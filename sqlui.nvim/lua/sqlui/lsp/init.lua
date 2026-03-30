local state = require("sqlui.state")

local M = {}

local runtime = {
  capabilities = nil,
  sqls_cmd = nil,
  sql_connection = nil,
  root_dir_fn = nil,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "sqlui" })
end

local function sqls_driver_from_dsn(dsn)
  local scheme = (dsn or ""):match("^([%w+]+):")
  if not scheme then
    return "mssql"
  end

  scheme = scheme:lower()
  if scheme == "postgres" or scheme == "postgresql" then
    return "postgresql"
  end
  if scheme == "mysql" then
    return "mysql"
  end
  if scheme == "sqlite" or scheme == "sqlite3" then
    return "sqlite3"
  end
  if scheme == "mssql" or scheme == "sqlserver" then
    return "mssql"
  end

  return scheme
end

--- URL-encode a string component (RFC 3986 unreserved chars preserved).
local function url_encode(str)
  if not str then
    return ""
  end
  return (str:gsub("[^%w%-%.%_%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- URL-decode a percent-encoded string.
local function url_decode(str)
  if not str then
    return str
  end
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Normalize a mssql:// or sqlserver:// DSN for the patched sqls binary.
---
--- The patched sqls uses sql.Open("sqlserver", dsn) which expects a
--- sqlserver:// URL format. This function:
---   1. Converts mssql:// scheme to sqlserver://
---   2. Moves URL path (instance name) to ?database= query param
---   3. Preserves existing query parameters
---   4. Does NOT double-encode: passwords are already URL-encoded in the stored DSN
local function normalize_dsn_for_sqls(dsn)
  -- Step 1: scheme normalization
  local normalized = dsn:gsub("^mssql://", "sqlserver://")

  -- Step 2: move path segment to ?database= query param
  -- Pattern: sqlserver://userinfo@host:port/PATH?query
  -- The go-mssqldb "sqlserver" driver treats the URL path as an instance name,
  -- NOT a database name. We must move it to ?database=.
  local before_path, path, query = normalized:match("^(sqlserver://[^/]+)/([^%?]*)%??(.*)")
  if before_path and path and path ~= "" then
    -- Clean up path slashes
    path = path:gsub("^/+", ""):gsub("/+$", "")
    if path ~= "" then
      -- Check if database= already in query params
      local has_db = false
      if query ~= "" then
        for kv in query:gmatch("[^&]+") do
          local k = kv:match("^([^=]+)")
          if k and k:lower() == "database" then
            has_db = true
            break
          end
        end
      end

      -- Add database= if not already present
      if not has_db then
        local db_param = "database=" .. url_encode(url_decode(path))
        if query and query ~= "" then
          query = query .. "&" .. db_param
        else
          query = db_param
        end
      end

      -- Rebuild URL without path
      if query ~= "" then
        normalized = before_path .. "?" .. query
      else
        normalized = before_path
      end
    end
  end

  return normalized
end

--- Build sqls connectionConfig from the active DSN.
--- For mssql/sqlserver: normalize URL for the patched sqls (sqlserver:// scheme,
--- path moved to ?database= param), pass as dataSourceName.
--- For other drivers: pass dataSourceName directly.
local function build_connection_config(dsn)
  local driver = sqls_driver_from_dsn(dsn)

  if driver == "mssql" then
    local normalized = normalize_dsn_for_sqls(dsn)
    return {
      driver = driver,
      dataSourceName = normalized,
    }
  end

  return {
    driver = driver,
    dataSourceName = dsn,
  }
end

local function build_sqls_config()
  if not runtime.sqls_cmd then
    return nil
  end

  local init_options = vim.empty_dict()
  if runtime.sql_connection and runtime.sql_connection.dsn and runtime.sql_connection.dsn ~= "" then
    init_options = {
      connectionConfig = build_connection_config(runtime.sql_connection.dsn),
    }
  end

  return {
    cmd = runtime.sqls_cmd,
    capabilities = runtime.capabilities,
    filetypes = { "sql" },
    root_dir = runtime.root_dir_fn,
    init_options = init_options,
  }
end

local function restart_sqls_clients()
  local config = build_sqls_config()
  if not config then
    return
  end

  for _, client in ipairs(vim.lsp.get_clients({ name = "sqls" })) do
    client:stop(true)
  end

  vim.lsp.config("sqls", config)
  vim.lsp.enable("sqls")

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "sql" then
      vim.lsp.start(config, { bufnr = bufnr })
    end
  end
end

function M.setup(opts)
  runtime.capabilities = opts.capabilities
  runtime.sqls_cmd = opts.sqls_cmd
  runtime.root_dir_fn = opts.root_dir_fn

  if opts.initial_connection and opts.initial_connection.dsn and opts.initial_connection.dsn ~= "" then
    runtime.sql_connection = vim.deepcopy(opts.initial_connection)
  end

  local config = build_sqls_config()
  if config then
    vim.lsp.config("sqls", config)
    vim.lsp.enable("sqls")
  end
end

function M.sync_connection(connection)
  local config = state.get_config() or {}
  local lsp_opts = config.sqls or {}
  if not lsp_opts.enabled then
    return false
  end

  if not connection or not connection.dsn or connection.dsn == "" then
    return false
  end

  runtime.sql_connection = {
    alias = connection.alias,
    dsn = connection.dsn,
  }

  if lsp_opts.auto_sync_connection ~= false then
    restart_sqls_clients()
    notify("sqls conectado em '" .. (connection.alias or "conexao") .. "'")
  end

  return true
end

function M.get_connection()
  return vim.deepcopy(runtime.sql_connection)
end

return M
