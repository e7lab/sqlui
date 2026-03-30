vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local fs = require("sqlui.util.fs")

local original_system = vim.system

local function reset_cache_dir(alias)
  local dir = fs.data_path("schema_cache", alias)
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
end

local function with_system_stub(fn)
  local calls = {}

  vim.system = function(cmd, opts)
    local sql = cmd[4]
    calls[#calls + 1] = sql

    local rows = nil
    if sql:find("from sys.schemas", 1, true) then
      rows = {
        { schema_name = "dbo" },
      }
    elseif sql:find("INFORMATION_SCHEMA.TABLES", 1, true) then
      local offset = tonumber(sql:match("offset (%d+) rows")) or 0
      if offset == 0 then
        rows = {
          { TABLE_SCHEMA = "dbo", TABLE_NAME = "users" },
        }
      elseif offset == 1 then
        rows = {
          { TABLE_SCHEMA = "dbo", TABLE_NAME = "z_logs" },
        }
      else
        rows = {}
      end
    elseif sql:find("INFORMATION_SCHEMA.VIEWS", 1, true) then
      local offset = tonumber(sql:match("offset (%d+) rows")) or 0
      if offset == 0 then
        rows = {
          { TABLE_SCHEMA = "dbo", TABLE_NAME = "active_users" },
        }
      elseif offset == 1 then
        rows = {
          { TABLE_SCHEMA = "dbo", TABLE_NAME = "z_active_users" },
        }
      else
        rows = {}
      end
    elseif sql:find("ROUTINE_TYPE = 'FUNCTION'", 1, true) then
      local offset = tonumber(sql:match("offset (%d+) rows")) or 0
      if offset == 0 then
        rows = {
          { ROUTINE_SCHEMA = "dbo", ROUTINE_NAME = "user_count", ROUTINE_TYPE = "FUNCTION" },
        }
      elseif offset == 1 then
        rows = {
          { ROUTINE_SCHEMA = "dbo", ROUTINE_NAME = "z_user_count", ROUTINE_TYPE = "FUNCTION" },
        }
      else
        rows = {}
      end
    elseif sql:find("ROUTINE_TYPE = 'PROCEDURE'", 1, true) then
      local offset = tonumber(sql:match("offset (%d+) rows")) or 0
      if offset == 0 then
        rows = {
          { ROUTINE_SCHEMA = "dbo", ROUTINE_NAME = "refresh_users", ROUTINE_TYPE = "PROCEDURE" },
        }
      elseif offset == 1 then
        rows = {
          { ROUTINE_SCHEMA = "dbo", ROUTINE_NAME = "z_refresh_users", ROUTINE_TYPE = "PROCEDURE" },
        }
      else
        rows = {}
      end
    elseif sql:find("INFORMATION_SCHEMA.COLUMNS", 1, true) then
      rows = {
        { TABLE_SCHEMA = "dbo", TABLE_NAME = "users", COLUMN_NAME = "id", DATA_TYPE = "int", ORDINAL_POSITION = 1 },
      }
    else
      error("unexpected SQL in test: " .. sql)
    end

    return {
      wait = function()
        return {
          code = 0,
          stdout = vim.json.encode(rows),
          stderr = "",
        }
      end,
    }
  end

  local result = { pcall(fn, calls) }
  vim.system = original_system
  if not result[1] then
    error(result[2])
  end
  return unpack(result, 2)
end

local function run_case(alias, setup_opts)
  package.loaded["sqlui"] = nil
  package.loaded["sqlui.config"] = nil
  package.loaded["sqlui.schema"] = nil
  package.loaded["sqlui.state"] = nil

  local sqlui = require("sqlui")
  local schema = require("sqlui.schema")
  local fresh_state = require("sqlui.state")

  sqlui.setup(vim.tbl_deep_extend("force", {
    secrets = { backend = "file" },
    sqls = { enabled = false },
  }, setup_opts or {}))
  fresh_state.reset_runtime()
  reset_cache_dir(alias)

  return with_system_stub(function(calls)
    local manifest, err = schema._build_cache_for_connection({ alias = alias, dsn = "sqlserver://example" })
    assert(not err, err)
    assert(manifest, "expected manifest")
    return calls, manifest
  end)
end

local function read_cache(alias)
  local safe_alias = alias:gsub("[^%w_.-]", "_")
  local manifest = fs.read_json(fs.data_path("schema_cache", safe_alias, "manifest.json"))
  local bundle = fs.read_json(fs.data_path("schema_cache", safe_alias, "dbo.json"))
  return manifest, bundle
end

do
  local calls, manifest = run_case("cache-default", {
    cache = { batch_size = 1 },
  })
  local manifest_file, bundle = read_cache("cache-default")

  assert(manifest.partial == false, "expected completed cache manifest")
  assert(manifest_file and manifest_file.partial == false, "expected persisted completed cache manifest")
  assert(bundle and bundle.objects and #bundle.objects.tables == 2, "expected persisted table cache")
  assert(bundle.complete.tables == true, "expected tables cache marked complete")
  assert(bundle.columns and next(bundle.columns) == nil, "expected columns to stay lazy by default")
  assert(manifest.schemas[1].tables_count == nil, "expected lightweight schema manifest without eager counts")

  for _, sql in ipairs(calls) do
    assert(not sql:find("INFORMATION_SCHEMA.COLUMNS", 1, true), "did not expect eager column preload by default")
  end

  assert(calls[1]:find("from sys.schemas", 1, true), "expected lightweight schema listing query")
  assert(not calls[1]:find("sys.objects", 1, true), "did not expect schema listing to join sys.objects")

  local batched_queries = 0
  for _, sql in ipairs(calls) do
    if sql:find("offset 1 rows", 1, true) then
      batched_queries = batched_queries + 1
    end
  end
  assert(batched_queries >= 3, "expected paginated metadata queries")
end

do
  local calls = run_case("cache-preload-columns", {
    cache = { preload_columns = true },
  })

  local _, bundle = read_cache("cache-preload-columns")
  local saw_columns_query = false
  for _, sql in ipairs(calls) do
    if sql:find("INFORMATION_SCHEMA.COLUMNS", 1, true) then
      saw_columns_query = true
      break
    end
  end

  assert(saw_columns_query, "expected eager column preload when explicitly enabled")
  assert(bundle and bundle.columns and bundle.columns.users and #bundle.columns.users == 1, "expected persisted preloaded columns")
end

vim.system = original_system
