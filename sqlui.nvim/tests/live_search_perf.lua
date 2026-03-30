vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local original_system = vim.system
local table_queries = 0

vim.system = function(cmd, opts)
  local sql = cmd[4]
  local rows

  if sql:find("from sys.schemas", 1, true) then
    rows = {
      { schema_name = "dbo" },
    }
  elseif sql:find("INFORMATION_SCHEMA.TABLES", 1, true) then
    table_queries = table_queries + 1
    rows = {
      { TABLE_SCHEMA = "dbo", TABLE_NAME = "produto" },
      { TABLE_SCHEMA = "dbo", TABLE_NAME = "produto_log" },
    }
  elseif sql:find("INFORMATION_SCHEMA.VIEWS", 1, true) or sql:find("ROUTINE_TYPE = 'FUNCTION'", 1, true) or sql:find("ROUTINE_TYPE = 'PROCEDURE'", 1, true) then
    rows = {}
  else
    error("unexpected SQL in live_search_perf test: " .. sql)
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
  cache = { live_search_min_chars = 3 },
})

local schema = require("sqlui.schema")
local conn = { alias = "perf-cache", dsn = "sqlserver://example", persistent_cache = { schemas = { { name = "dbo" } } } }

local short_items = schema._test_live_search_items(conn, "dbo", "tables", "pr")
assert(#short_items == 1 and short_items[1].kind == "hint", "expected hint for short search")
assert(table_queries == 0, "did not expect live query below minimum chars")

local first_items = schema._test_live_search_items(conn, "dbo", "tables", "pro")
assert(table_queries == 1, "expected first live query for valid term")
assert(#first_items == 2, "expected live search results")

local second_items = schema._test_live_search_items(conn, "dbo", "tables", "pro")
assert(table_queries == 1, "expected memoized live search result")
assert(#second_items == 2, "expected memoized live search results")

vim.system = original_system
