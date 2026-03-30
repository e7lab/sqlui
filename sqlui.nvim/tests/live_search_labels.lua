vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local original_system = vim.system

vim.system = function(cmd, opts)
  local sql = cmd[4]

  local rows
  if sql:find("from sys.schemas", 1, true) then
    rows = {
      { schema_name = "dbo" },
    }
  elseif sql:find("INFORMATION_SCHEMA.TABLES", 1, true) then
    local search = sql:match("TABLE_NAME like '([^%%']+)%%'")
    if search == "cli" then
      rows = {
        { TABLE_SCHEMA = "dbo", TABLE_NAME = "clientes" },
        { TABLE_SCHEMA = "dbo", TABLE_NAME = "clientes_log" },
      }
    else
      rows = {
        { TABLE_SCHEMA = "dbo", TABLE_NAME = "clientes" },
      }
    end
  elseif sql:find("INFORMATION_SCHEMA.VIEWS", 1, true) or sql:find("ROUTINE_TYPE = 'FUNCTION'", 1, true) or sql:find("ROUTINE_TYPE = 'PROCEDURE'", 1, true) then
    rows = {}
  else
    error("unexpected SQL in live_search_labels test: " .. sql)
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

require("sqlui").setup({
  secrets = { backend = "file" },
  sqls = { enabled = false },
  cache = { live_search_min_chars = 2 },
})

local fs = require("sqlui.util.fs")
local schema = require("sqlui.schema")

local alias = "label-cache"
local safe_alias = alias:gsub("[^%w_.-]", "_")
local dir = fs.data_path("schema_cache", safe_alias)
if vim.fn.isdirectory(dir) == 1 then
  vim.fn.delete(dir, "rf")
end

local conn = { alias = alias, dsn = "sqlserver://example" }
local manifest, err = schema._build_cache_for_connection(conn)
assert(not err, err)
assert(manifest, "expected manifest")

local schema_file = fs.data_path("schema_cache", safe_alias, "dbo.json")
local bundle = fs.read_json(schema_file)
bundle.complete.tables = false
bundle.objects.tables = {
  { schema = "dbo", name = "clientes", type = "TABLE" },
}
fs.write_json(schema_file, bundle)

local enriched = { alias = alias, dsn = conn.dsn, persistent_cache = manifest }
package.loaded["sqlui.schema"] = nil
schema = require("sqlui.schema")
local items = schema._test_live_search_items(enriched, "dbo", "tables", "cli")

local by_name = {}
for _, item in ipairs(items) do
  if not item.kind then
    by_name[item.name] = item.source_status
  end
end

assert(by_name.clientes == "partial", "expected cached table to stay partial")
assert(by_name.clientes_log == "live", "expected uncached table to stay live")

vim.system = original_system
