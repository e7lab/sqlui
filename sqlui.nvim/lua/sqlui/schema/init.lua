local connection = require("sqlui.connection")
local data_viewer = require("sqlui.data_viewer")
local fs = require("sqlui.util.fs")
local picker = require("sqlui.ui.picker")
local state = require("sqlui.state")

local M = {}

local session = {
  schema_stats = {},
  schema_cache = {},
}

local schema_categories = {
  {
    key = "tables",
    label = "Tabelas",
    list_sql = "select TABLE_SCHEMA, TABLE_NAME from INFORMATION_SCHEMA.TABLES where TABLE_TYPE = 'BASE TABLE' order by TABLE_SCHEMA, TABLE_NAME",
    list_sql_sqlite = "select 'main' as TABLE_SCHEMA, name as TABLE_NAME from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name",
  },
  {
    key = "views",
    label = "Views",
    list_sql = "select TABLE_SCHEMA, TABLE_NAME from INFORMATION_SCHEMA.VIEWS order by TABLE_SCHEMA, TABLE_NAME",
    list_sql_sqlite = "select 'main' as TABLE_SCHEMA, name as TABLE_NAME from sqlite_master where type = 'view' order by name",
  },
  {
    key = "functions",
    label = "Functions",
    list_sql = "select ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE from INFORMATION_SCHEMA.ROUTINES where ROUTINE_TYPE = 'FUNCTION' order by ROUTINE_SCHEMA, ROUTINE_NAME",
    list_sql_sqlite = nil,
  },
  {
    key = "procedures",
    label = "Procedures",
    list_sql = "select ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE from INFORMATION_SCHEMA.ROUTINES where ROUTINE_TYPE = 'PROCEDURE' order by ROUTINE_SCHEMA, ROUTINE_NAME",
    list_sql_sqlite = nil,
  },
}

local schema_count_field_by_category = {
  tables = "tables_count",
  views = "views_count",
  functions = "functions_count",
  procedures = "procedures_count",
}

local function trim(value)
  return vim.trim(value or "")
end

local function notify(msg, level)
  local safe_msg = tostring(msg or "sqlui: erro desconhecido")
  local ok = pcall(vim.notify, safe_msg, level or vim.log.levels.INFO, { title = "sqlui" })
  if not ok then
    vim.notify(safe_msg, level or vim.log.levels.INFO)
  end
end

local function cache_config()
  local config = state.get_config() or {}
  return config.cache or {}
end

local function schema_page_size()
  return cache_config().schema_page_size or 15
end

local function schema_live_search_debounce_ms()
  return cache_config().debounce_ms or 300
end

local function routine_preview_line_limit()
  return cache_config().routine_preview_line_limit or 40
end

local function usql_bin()
  local config = state.get_config() or {}
  return ((config.usql or {}).bin) or "usql"
end

local function ensure_dependency(bin, help)
  if vim.fn.executable(bin) == 1 then
    return true
  end
  notify(help or (bin .. " nao encontrado no PATH"), vim.log.levels.ERROR)
  return false
end

local function row_field(row, ...)
  if type(row) ~= "table" then
    return nil
  end

  for i = 1, select("#", ...) do
    local key = select(i, ...)
    local value = row[key]
    if value ~= nil then
      return value
    end
  end

  return nil
end

local function escape_sql_string(value)
  return tostring(value or ""):gsub("'", "''")
end

local function run_usql_json(dsn, sql)
  local attempts = 2
  local last_err = nil

  for _ = 1, attempts do
    local result = vim.system({ usql_bin(), "-J", "-c", sql, dsn }, { text = true }):wait()
    if result.code == 0 then
      local body = trim(result.stdout)
      if body == "" then
        return {}, nil
      end

      local ok, decoded = pcall(vim.json.decode, body)
      if not ok or type(decoded) ~= "table" then
        return nil, "nao foi possivel decodificar a resposta JSON do usql"
      end
      return decoded, nil
    end

    local err = trim(result.stderr)
    if err == "" then
      err = trim(result.stdout)
    end
    last_err = err ~= "" and err or "falha ao consultar metadados SQL"

    if not last_err:lower():match("eof") then
      break
    end
  end

  return nil, last_err or "falha ao consultar metadados SQL"
end

local function loading_panel(message)
  local current_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("botright 4split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "sqlui schema cache",
    message or "Aguarde.",
    "",
    "Fechando automaticamente ao concluir.",
  })
  vim.cmd("redraw!")
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return { win = win, buf = buf }
end

local function update_loading_panel(handle, lines)
  if not handle or not handle.buf or not vim.api.nvim_buf_is_valid(handle.buf) then
    return
  end
  vim.bo[handle.buf].modifiable = true
  vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, lines)
  vim.bo[handle.buf].modifiable = false
  vim.cmd("redraw!")
end

local function update_loading_panel(handle, lines)
  if not handle or not handle.buf or not vim.api.nvim_buf_is_valid(handle.buf) then
    return
  end
  vim.bo[handle.buf].modifiable = true
  vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, lines)
  vim.bo[handle.buf].modifiable = false
  vim.cmd("redraw!")
end

local function close_loading_panel(handle, on_closed)
  if handle and handle.win and vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  elseif handle and handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
    vim.api.nvim_buf_delete(handle.buf, { force = true })
  end
  if on_closed then
    on_closed()
  end
end

local function persistent_cache_root()
  return fs.data_path("schema_cache")
end

local function persistent_cache_key(alias)
  local safe_alias = trim(alias):gsub("[^%w_.-]", "_")
  if safe_alias == "" then
    safe_alias = "default"
  end
  return safe_alias
end

local function schema_bundle_cache_key(alias, schema_name)
  return table.concat({ "bundle", persistent_cache_key(alias), schema_name or "" }, "::")
end

local function persistent_cache_base_dir(alias)
  local path = string.format("%s/%s", persistent_cache_root(), persistent_cache_key(alias))
  fs.ensure_dir(path)
  return path
end

local function persistent_cache_manifest_path(alias)
  return string.format("%s/manifest.json", persistent_cache_base_dir(alias))
end

local function persistent_cache_schema_path(alias, schema_name)
  local safe_schema = trim(schema_name):gsub("[^%w_.-]", "_")
  if safe_schema == "" then
    safe_schema = "default"
  end
  return string.format("%s/%s.json", persistent_cache_base_dir(alias), safe_schema)
end

local function clear_runtime_cache()
  session.schema_stats = {}
  session.schema_cache = {}
end

local function load_persistent_manifest(alias)
  if trim(alias) == "" or alias == "temporaria" then
    return nil
  end

  local manifest = fs.read_json(persistent_cache_manifest_path(alias))
  if manifest then
    manifest.cache_dir = persistent_cache_base_dir(alias)
  end
  return manifest
end

local function save_persistent_manifest(alias, data)
  if trim(alias) == "" or alias == "temporaria" then
    return
  end
  fs.write_json(persistent_cache_manifest_path(alias), data)
end

local function load_persistent_bundle(alias, schema_name)
  if trim(alias) == "" or alias == "temporaria" then
    return nil
  end
  return fs.read_json(persistent_cache_schema_path(alias, schema_name))
end

local function save_persistent_bundle(alias, schema_name, data)
  if trim(alias) == "" or alias == "temporaria" then
    return
  end
  fs.write_json(persistent_cache_schema_path(alias, schema_name), data)
end

local function delete_persistent_cache(alias)
  if trim(alias) == "" or alias == "temporaria" then
    return
  end
  local dir = persistent_cache_base_dir(alias)
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
end

local function apply_schema_stats(items)
  session.schema_stats = {}
  for _, item in ipairs(items or {}) do
    if item.name then
      session.schema_stats[item.name] = item
    end
  end
end

local function sorted_schema_stats()
  local schemas = {}
  for _, item in pairs(session.schema_stats or {}) do
    table.insert(schemas, vim.deepcopy(item))
  end
  table.sort(schemas, function(a, b)
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return schemas
end

local function ensure_persistent_manifest(alias)
  local manifest = load_persistent_manifest(alias)
  if manifest then
    return manifest
  end

  manifest = {
    alias = alias,
    built_at = os.date("%Y-%m-%d %H:%M:%S"),
    version = 2,
    schemas = sorted_schema_stats(),
  }
  save_persistent_manifest(alias, manifest)
  manifest.cache_dir = persistent_cache_base_dir(alias)
  return manifest
end

local function merge_named_items(existing, incoming)
  local merged = {}
  local index = {}

  for _, item in ipairs(existing or {}) do
    local key = tostring(item.name or "")
    if key ~= "" then
      merged[#merged + 1] = item
      index[key] = #merged
    end
  end

  for _, item in ipairs(incoming or {}) do
    local key = tostring(item.name or "")
    if key ~= "" then
      if index[key] then
        merged[index[key]] = item
      else
        merged[#merged + 1] = item
        index[key] = #merged
      end
    end
  end

  table.sort(merged, function(a, b)
    return tostring(a.name or "") < tostring(b.name or "")
  end)

  return merged
end

local function connection_with_cache(conn, cache)
  local enriched = vim.deepcopy(conn)
  enriched.persistent_cache = cache
  return enriched
end

local function upsert_persistent_schema_objects(alias, schema_name, category_key, items, is_complete)
  if trim(alias) == "" or alias == "temporaria" then
    return
  end

  local bundle = load_persistent_bundle(alias, schema_name) or {
    schema = schema_name,
    objects = { tables = {}, views = {}, functions = {}, procedures = {} },
    columns = {},
    complete = {},
  }

  bundle.objects = bundle.objects or { tables = {}, views = {}, functions = {}, procedures = {} }
  bundle.columns = bundle.columns or {}
  bundle.complete = bundle.complete or {}
  bundle.objects[category_key] = merge_named_items(bundle.objects[category_key], items)
  if is_complete ~= nil then
    bundle.complete[category_key] = is_complete and true or false
  elseif bundle.complete[category_key] == nil then
    bundle.complete[category_key] = false
  end

  save_persistent_bundle(alias, schema_name, bundle)
  session.schema_cache[schema_bundle_cache_key(alias, schema_name)] = bundle

  local manifest = ensure_persistent_manifest(alias)
  manifest.built_at = os.date("%Y-%m-%d %H:%M:%S")
  manifest.schemas = sorted_schema_stats()
  save_persistent_manifest(alias, manifest)
  return manifest
end

local function upsert_persistent_schema_columns(alias, schema_name, object_name, columns)
  if trim(alias) == "" or alias == "temporaria" then
    return
  end

  local bundle = load_persistent_bundle(alias, schema_name) or {
    schema = schema_name,
    objects = { tables = {}, views = {}, functions = {}, procedures = {} },
    columns = {},
    complete = {},
  }

  bundle.objects = bundle.objects or { tables = {}, views = {}, functions = {}, procedures = {} }
  bundle.columns = bundle.columns or {}
  bundle.complete = bundle.complete or {}
  bundle.columns[object_name] = columns

  save_persistent_bundle(alias, schema_name, bundle)
  session.schema_cache[schema_bundle_cache_key(alias, schema_name)] = bundle

  local manifest = ensure_persistent_manifest(alias)
  manifest.built_at = os.date("%Y-%m-%d %H:%M:%S")
  manifest.schemas = sorted_schema_stats()
  save_persistent_manifest(alias, manifest)
  return manifest
end

local function list_schemas(dsn)
  local driver = connection.detect_driver(dsn)

  local schema_queries = {
    mssql = [[
select
  s.name as schema_name,
  sum(case when o.type = 'U' then 1 else 0 end) as tables_count,
  sum(case when o.type = 'V' then 1 else 0 end) as views_count,
  sum(case when o.type in ('FN','IF','TF','FS','FT') then 1 else 0 end) as functions_count,
  sum(case when o.type in ('P','PC') then 1 else 0 end) as procedures_count
from sys.schemas s
left join sys.objects o
  on o.schema_id = s.schema_id
 and o.is_ms_shipped = 0
group by s.name
order by s.name
]],
    postgres = [[
select
  n.nspname as schema_name,
  count(*) filter (where c.relkind = 'r') as tables_count,
  count(*) filter (where c.relkind = 'v') as views_count,
  count(*) filter (where c.relkind = 'f') as functions_count,
  0 as procedures_count
from pg_namespace n
left join pg_class c
  on c.relnamespace = n.oid
 and c.relkind in ('r','v','f')
where n.nspname !~ '^pg_'
  and n.nspname <> 'information_schema'
group by n.nspname
order by n.nspname
]],
    mysql = [[
select
  table_schema as schema_name,
  sum(case when table_type = 'BASE TABLE' then 1 else 0 end) as tables_count,
  sum(case when table_type = 'VIEW' then 1 else 0 end) as views_count,
  0 as functions_count,
  0 as procedures_count
from information_schema.tables
where table_schema not in ('information_schema','mysql','performance_schema','sys')
group by table_schema
order by table_schema
]],
    sqlite = [[
select
  'main' as schema_name,
  (select count(*) from sqlite_master where type = 'table' and name not like 'sqlite_%') as tables_count,
  (select count(*) from sqlite_master where type = 'view') as views_count,
  0 as functions_count,
  0 as procedures_count
]],
  }

  local sql = schema_queries[driver]
  if not sql then
    return nil, "driver '" .. driver .. "' nao suportado para listagem de schemas"
  end

  local rows, err = run_usql_json(dsn, sql)
  if not rows then
    return nil, err
  end

  local items = {}
  session.schema_stats = {}
  for _, row in ipairs(rows) do
    local item = {
      name = row_field(row, "schema_name", "SCHEMA_NAME", "schemaName") or "<schema>",
      tables_count = tonumber(row_field(row, "tables_count", "TABLES_COUNT", "tablesCount") or 0) or 0,
      views_count = tonumber(row_field(row, "views_count", "VIEWS_COUNT", "viewsCount") or 0) or 0,
      functions_count = tonumber(row_field(row, "functions_count", "FUNCTIONS_COUNT", "functionsCount") or 0) or 0,
      procedures_count = tonumber(row_field(row, "procedures_count", "PROCEDURES_COUNT", "proceduresCount") or 0) or 0,
    }
    table.insert(items, item)
    session.schema_stats[item.name] = item
  end

  return items, nil
end

local function schemas_for_connection(conn)
  if conn.persistent_cache and type(conn.persistent_cache.schemas) == "table" then
    apply_schema_stats(conn.persistent_cache.schemas)
    return vim.deepcopy(conn.persistent_cache.schemas), nil
  end

  return list_schemas(conn.dsn)
end

local function schema_category_count(schema_name, category_key)
  local stats = session.schema_stats[schema_name]
  if not stats then
    return nil
  end
  local field = schema_count_field_by_category[category_key]
  if not field then
    return nil
  end
  return tonumber(stats[field] or 0) or 0
end

local function group_items_by_schema(items)
  local grouped = {}
  for _, item in ipairs(items or {}) do
    local schema = item.schema or "<schema>"
    grouped[schema] = grouped[schema] or {}
    table.insert(grouped[schema], item)
  end
  return grouped
end

local function build_columns_cache_for_schema(dsn, schema_name)
  local driver = connection.detect_driver(dsn)

  if driver == "sqlite" then
    -- SQLite: list all tables, then PRAGMA table_info() for each (capped at 200)
    local tables_rows, tables_err = run_usql_json(
      dsn,
      "select name from sqlite_master where type in ('table','view') and name not like 'sqlite_%' order by name limit 200"
    )
    if not tables_rows then
      return nil, tables_err
    end

    local grouped = {}
    for _, tbl_row in ipairs(tables_rows) do
      local tbl_name = row_field(tbl_row, "name", "NAME") or "<table>"
      local cols, cols_err = run_usql_json(dsn, string.format("PRAGMA table_info('%s')", escape_sql_string(tbl_name)))
      if cols then
        grouped[tbl_name] = {}
        for _, col in ipairs(cols) do
          table.insert(grouped[tbl_name], {
            ordinal_position = row_field(col, "cid", "CID"),
            column_name = row_field(col, "name", "NAME"),
            data_type = row_field(col, "type", "TYPE") or "TEXT",
          })
        end
      elseif cols_err then
        notify("colunas nao carregadas para '" .. tbl_name .. "'", vim.log.levels.WARN)
      end
    end
    if #tables_rows >= 200 then
      notify("cache de colunas limitado a 200 tabelas SQLite", vim.log.levels.WARN)
    end
    return grouped, nil
  end

  local rows, err = run_usql_json(
    dsn,
    string.format(
      "select TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.COLUMNS where TABLE_SCHEMA = '%s' order by TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION",
      escape_sql_string(schema_name)
    )
  )
  if not rows then
    return nil, err
  end

  local grouped = {}
  for _, row in ipairs(rows) do
    local table_name = row_field(row, "TABLE_NAME", "table_name", "tableName") or "<table>"
    grouped[table_name] = grouped[table_name] or {}
    table.insert(grouped[table_name], {
      ordinal_position = row_field(row, "ORDINAL_POSITION", "ordinal_position", "ordinalPosition"),
      column_name = row_field(row, "COLUMN_NAME", "column_name", "columnName"),
      data_type = row_field(row, "DATA_TYPE", "data_type", "dataType"),
    })
  end

  return grouped, nil
end

local function schema_list_items(dsn, category, schema_name, search_term, limit, offset)
  local driver = connection.detect_driver(dsn)
  local cache_key = table.concat({ dsn, category.key, schema_name or "", search_term or "", tostring(limit or ""), tostring(offset or "") }, "::")
  if session.schema_cache[cache_key] then
    return vim.deepcopy(session.schema_cache[cache_key]), nil
  end

  -- SQLite: no functions/procedures
  if driver == "sqlite" and (category.key == "functions" or category.key == "procedures") then
    session.schema_cache[cache_key] = {}
    return {}, nil
  end

  local sql = driver == "sqlite" and category.list_sql_sqlite or category.list_sql
  if not sql then
    session.schema_cache[cache_key] = {}
    return {}, nil
  end

  if driver == "sqlite" then
    -- SQLite: filtering is done via LIKE on `name` column in sqlite_master
    if trim(search_term) ~= "" then
      local pattern = escape_sql_string(search_term) .. "%"
      if sql:lower():find(" order by ", 1, true) then
        sql = sql:gsub(" [Oo][Rr][Dd][Ee][Rr] [Bb][Yy] ", " and name like '" .. pattern .. "' order by ", 1)
      else
        sql = sql .. " and name like '" .. pattern .. "'"
      end
    end
    if limit and limit > 0 then
      sql = sql .. " limit " .. tostring(limit)
      if offset and offset > 0 then
        sql = sql .. " offset " .. tostring(offset)
      end
    end
  else
    local clauses = {}

    if trim(schema_name) ~= "" then
      if category.key == "functions" or category.key == "procedures" then
        table.insert(clauses, string.format("ROUTINE_SCHEMA = '%s'", escape_sql_string(schema_name)))
      else
        table.insert(clauses, string.format("TABLE_SCHEMA = '%s'", escape_sql_string(schema_name)))
      end
    end

    if trim(search_term) ~= "" then
      local pattern = escape_sql_string(search_term) .. "%%%"
      if category.key == "functions" or category.key == "procedures" then
        table.insert(clauses, string.format("ROUTINE_NAME like '%s'", pattern))
      else
        table.insert(clauses, string.format("TABLE_NAME like '%s'", pattern))
      end
    end

    if #clauses > 0 then
      local where_sql = table.concat(clauses, " and ")
      if sql:lower():find(" where ", 1, true) then
        sql = sql:gsub(" [Oo][Rr][Dd][Ee][Rr] [Bb][Yy] ", " and " .. where_sql .. " order by ", 1)
      else
        sql = sql:gsub(" [Oo][Rr][Dd][Ee][Rr] [Bb][Yy] ", " where " .. where_sql .. " order by ", 1)
      end
    end

    if limit and limit > 0 then
      if driver == "mssql" then
        if offset and offset > 0 then
          -- MSSQL: OFFSET/FETCH requires ORDER BY (already present in base SQL)
          sql = sql .. string.format(" offset %d rows fetch next %d rows only", offset, limit)
        else
          sql = sql:gsub("^[Ss][Ee][Ll][Ee][Cc][Tt]%s+", "select top " .. tostring(limit) .. " ", 1)
        end
      else
        sql = sql .. " limit " .. tostring(limit)
        if offset and offset > 0 then
          sql = sql .. " offset " .. tostring(offset)
        end
      end
    end
  end

  local rows, err = run_usql_json(dsn, sql)
  if not rows then
    return nil, err
  end

  local items = {}
  for _, row in ipairs(rows) do
    local table_schema = row_field(row, "TABLE_SCHEMA", "table_schema", "tableSchema")
    local table_name = row_field(row, "TABLE_NAME", "table_name", "tableName")
    local routine_schema = row_field(row, "ROUTINE_SCHEMA", "routine_schema", "routineSchema")
    local routine_name = row_field(row, "ROUTINE_NAME", "routine_name", "routineName")
    local routine_type = row_field(row, "ROUTINE_TYPE", "routine_type", "routineType")

    if category.key == "functions" or category.key == "procedures" then
      table.insert(items, {
        schema = routine_schema,
        name = routine_name,
        type = routine_type,
      })
    else
      table.insert(items, {
        schema = table_schema or "main",
        name = table_name,
        type = category.key == "tables" and "TABLE" or "VIEW",
      })
    end
  end

  session.schema_cache[cache_key] = vim.deepcopy(items)
  return items, nil
end

local function filter_cached_items(items, term, limit)
  local filtered = {}
  local search = trim(term or ""):lower()

  for _, item in ipairs(items or {}) do
    local name = tostring(item.name or "")
    local include = true
    if search ~= "" then
      include = name:lower():sub(1, #search) == search
    end
    if include then
      table.insert(filtered, item)
      if limit and #filtered >= limit then
        break
      end
    end
  end

  return filtered
end

local function cached_schema_items(conn, category, schema_name, search_term, limit)
  local cache = conn.persistent_cache
  if not cache then
    return nil, false
  end

  local alias = trim(conn.alias)
  if alias == "" or alias == "temporaria" then
    return nil, false
  end

  local bundle_key = schema_bundle_cache_key(alias, schema_name)
  local bundle = session.schema_cache[bundle_key]
  if not bundle then
    bundle = load_persistent_bundle(alias, schema_name)
    if bundle then
      session.schema_cache[bundle_key] = bundle
    end
  end

  if not bundle or type(bundle.objects) ~= "table" then
    return nil, false
  end

  local items = bundle.objects[category.key]
  if not items then
    return nil, false
  end

  bundle.complete = bundle.complete or {}
  return filter_cached_items(items, search_term, limit), bundle.complete[category.key] == true
end

local function fetch_columns_for_object(dsn, schema_name, object_name)
  local driver = connection.detect_driver(dsn)

  if driver == "sqlite" then
    local rows, err = run_usql_json(dsn, string.format("PRAGMA table_info('%s')", escape_sql_string(object_name)))
    if not rows then
      return nil, err
    end
    local columns = {}
    for _, row in ipairs(rows) do
      table.insert(columns, {
        ordinal_position = row_field(row, "cid", "CID"),
        column_name = row_field(row, "name", "NAME"),
        data_type = row_field(row, "type", "TYPE") or "TEXT",
      })
    end
    return columns, nil
  end

  local rows, err = run_usql_json(
    dsn,
    string.format(
      "select COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.COLUMNS where TABLE_SCHEMA = '%s' and TABLE_NAME = '%s' order by ORDINAL_POSITION",
      escape_sql_string(schema_name),
      escape_sql_string(object_name)
    )
  )
  if not rows then
    return nil, err
  end

  local columns = {}
  for _, row in ipairs(rows) do
    table.insert(columns, {
      ordinal_position = row_field(row, "ORDINAL_POSITION", "ordinal_position", "ordinalPosition"),
      column_name = row_field(row, "COLUMN_NAME", "column_name", "columnName"),
      data_type = row_field(row, "DATA_TYPE", "data_type", "dataType"),
    })
  end

  return columns, nil
end

local function columns_preview_text(item, category, columns)
  local lines = {
    string.format("%s.%s", item.schema, item.name),
    string.format("Tipo: %s", item.type or (category.key == "tables" and "TABLE" or "VIEW")),
    "",
    "Colunas:",
  }

  if not columns or #columns == 0 then
    table.insert(lines, "- nenhuma coluna encontrada")
  else
    for _, col in ipairs(columns) do
      table.insert(lines, string.format(
        "%s. %s (%s)",
        tostring(col.ordinal_position or "?"),
        tostring(col.column_name or "?"),
        tostring(col.data_type or "?")
      ))
    end
  end

  return table.concat(lines, "\n")
end

local function cached_columns_preview(conn, category, item)
  local alias = trim(conn.alias)
  if alias == "" or alias == "temporaria" then
    return nil
  end

  local bundle_key = schema_bundle_cache_key(alias, item.schema)
  local bundle = session.schema_cache[bundle_key]
  if not bundle then
    bundle = load_persistent_bundle(alias, item.schema)
    if bundle then
      session.schema_cache[bundle_key] = bundle
    end
  end

  local columns = bundle and bundle.columns and bundle.columns[item.name] or nil
  if not columns then
    return nil
  end

  return columns_preview_text(item, category, columns)
end

local function schema_preview_text(dsn, category, item)
  local schema = escape_sql_string(item.schema)
  local name = escape_sql_string(item.name)
  local driver = connection.detect_driver(dsn)

  if category.key == "functions" or category.key == "procedures" then
    -- SQLite has no functions/procedures
    if driver == "sqlite" then
      return "SQLite nao suporta funcoes ou procedures."
    end

    local lines = {
      string.format("%s.%s", item.schema, item.name),
      string.format("Tipo: %s", item.type or (category.key == "functions" and "FUNCTION" or "PROCEDURE")),
      "",
    }

    local params, params_err = run_usql_json(
      dsn,
      string.format(
        "select PARAMETER_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.PARAMETERS where SPECIFIC_SCHEMA = '%s' and SPECIFIC_NAME = '%s' order by ORDINAL_POSITION",
        schema,
        name
      )
    )

    if params and #params > 0 then
      table.insert(lines, "Parametros:")
      for _, param in ipairs(params) do
        table.insert(lines, string.format(
          "- %s: %s",
          row_field(param, "PARAMETER_NAME", "parameter_name", "parameterName") or "<retorno>",
          row_field(param, "DATA_TYPE", "data_type", "dataType") or "?"
        ))
      end
    elseif params_err then
      table.insert(lines, "Parametros: erro ao carregar")
      table.insert(lines, params_err)
    else
      table.insert(lines, "Parametros: nenhum parametro encontrado")
    end

    local driver = connection.detect_driver(dsn)
    local def_sql
    if driver == "mssql" then
      def_sql = string.format(
        "select top 1 ROUTINE_DEFINITION from INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA = '%s' and ROUTINE_NAME = '%s'",
        schema,
        name
      )
    else
      def_sql = string.format(
        "select ROUTINE_DEFINITION from INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA = '%s' and ROUTINE_NAME = '%s' limit 1",
        schema,
        name
      )
    end

    local def, def_err = run_usql_json(dsn, def_sql)

    local definition = def and def[1] and row_field(def[1], "ROUTINE_DEFINITION", "routine_definition", "routineDefinition")
    if trim(definition) ~= "" then
      table.insert(lines, "")
      table.insert(lines, "Definicao:")
      local definition_lines = vim.split(definition, "\n", { plain = true })
      local shown = 0
      for _, line in ipairs(definition_lines) do
        shown = shown + 1
        if shown > routine_preview_line_limit() then
          table.insert(lines, string.format("... (%d linhas ocultas)", #definition_lines - routine_preview_line_limit()))
          break
        end
        table.insert(lines, line)
      end
    elseif def_err then
      table.insert(lines, "")
      table.insert(lines, "Definicao: erro ao carregar")
      table.insert(lines, def_err)
    end

    return table.concat(lines, "\n")
  end

  local columns, err = fetch_columns_for_object(dsn, item.schema, item.name)
  if not columns then
    return err
  end

  return columns_preview_text(item, category, columns)
end

local function schema_summary_preview(schema_item, conn)
  local lines = {
    string.format("Schema: %s", schema_item.name),
    "",
    string.format("Tabelas: %d", schema_item.tables_count or 0),
    string.format("Views: %d", schema_item.views_count or 0),
    string.format("Functions: %d", schema_item.functions_count or 0),
    string.format("Procedures: %d", schema_item.procedures_count or 0),
    "",
    string.format("Objetos por categoria: use Telescope para filtrar localmente."),
  }

  if conn and conn.persistent_cache and conn.persistent_cache.built_at then
    table.insert(lines, "")
    table.insert(lines, "Cache local: " .. conn.persistent_cache.built_at)
  end

  return table.concat(lines, "\n")
end

local function browser_source_label(item)
  if item.source_status == "complete" then
    return "COMPLETO"
  end
  if item.source_status == "partial" then
    return "PARCIAL"
  end
  return "LIVE"
end

local function apply_source_status(items, status)
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and not item.kind then
      item.source_status = status
    end
  end
  return items
end

local function schema_browser_preview(conn, category, item)
  if item.kind == "hint" or item.kind == "error" then
    return table.concat({
      string.format("Schema: %s", item.schema or "?"),
      string.format("Categoria: %s", category.label),
      "",
      item.name,
      "",
      "Digite no prompt para filtrar em tempo real.",
    }, "\n")
  end

  local header = "Origem: " .. browser_source_label(item)
  if category.key == "tables" or category.key == "views" then
    local preview = cached_columns_preview(conn, category, item)
    if preview then
      return header .. "\n\n" .. preview
    end

    local alias = trim(conn.alias)
    if alias ~= "" and alias ~= "temporaria" then
      local columns, err = fetch_columns_for_object(conn.dsn, item.schema, item.name)
      if columns then
        conn.persistent_cache = upsert_persistent_schema_columns(alias, item.schema, item.name, columns)
        return header .. "\n\n" .. columns_preview_text(item, category, columns)
      end
      if err then
        return err
      end
    end
  end

  return header .. "\n\n" .. schema_preview_text(conn.dsn, category, item)
end

local function insert_schema_object(item, category)
  local text = string.format("%s.%s", item.schema, item.name)
  if category.key == "functions" or category.key == "procedures" then
    text = text .. "()"
  end
  vim.api.nvim_put({ text }, "c", true, true)
end

local function next_schema_category(key, step)
  local index = 1
  for i, category in ipairs(schema_categories) do
    if category.key == key then
      index = i
      break
    end
  end
  local target = ((index - 1 + step) % #schema_categories) + 1
  return schema_categories[target]
end

local function schema_category_by_key(key)
  return next_schema_category(key or "tables", 0)
end

local function resolve_schema_connection(conn, on_ready)
  local alias = trim(conn.alias)
  if alias == "" or alias == "temporaria" then
    on_ready(conn)
    return
  end

  local cached = load_persistent_manifest(alias)
  if cached then
    on_ready(connection_with_cache(conn, cached))
    return
  end

  picker.select({
    { label = "Gerar cache local (Recomendado)", kind = "build" },
    { label = "Abrir sem cache", kind = "live" },
  }, {
    prompt = string.format("Browser SQL para %s", alias),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice.kind == "live" then
      on_ready(conn)
      return
    end

    local loading = loading_panel("Gerando cache local do browser SQL")
    vim.schedule(function()
      vim.defer_fn(function()
        local cache, err = M._build_cache_for_connection(conn)
        close_loading_panel(loading, function()
          if not cache then
            notify(err or "falha ao gerar cache do browser SQL", vim.log.levels.ERROR)
            return
          end
          notify("cache SQL gerado para '" .. alias .. "'")
          on_ready(connection_with_cache(conn, cache))
        end)
      end, 30)
    end)
  end)
end

local function native_browser(conn, schema_name, category_key, page)
  local category = schema_category_by_key(category_key or "tables")
  local page_size = schema_page_size()
  local current_page = page or 1
  local current_offset = (current_page - 1) * page_size
  local fetch_limit = page_size + 1
  local items, err = schema_list_items(conn.dsn, category, schema_name, nil, fetch_limit, current_offset)
  if not items then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local has_more = #items > page_size
  if has_more then
    while #items > page_size do
      table.remove(items)
    end
  end

  local native_items = {
    { label = "[Schemas] voltar", kind = "schemas" },
  }
  for _, switch_category in ipairs(schema_categories) do
    table.insert(native_items, {
      label = string.format("[%s] abrir", switch_category.label),
      kind = "category",
      category = switch_category.key,
    })
  end
  if current_page > 1 then
    table.insert(native_items, {
      label = string.format("[< Página %d]", current_page - 1),
      kind = "prev_page",
    })
  end
  for _, item in ipairs(items) do
    table.insert(native_items, {
      label = string.format("%s.%s", item.schema, item.name),
      kind = "object",
      item = item,
    })
  end
  if has_more then
    table.insert(native_items, {
      label = string.format("[Página %d >]", current_page + 1),
      kind = "next_page",
    })
  end

  picker.select(native_items, {
    prompt = string.format("%s | %s (pág. %d)", schema_name, category.label, current_page),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.kind == "schemas" then
      M.browser()
      return
    end
    if choice.kind == "category" then
      native_browser(conn, schema_name, choice.category)
      return
    end
    if choice.kind == "prev_page" then
      native_browser(conn, schema_name, category_key, current_page - 1)
      return
    end
    if choice.kind == "next_page" then
      native_browser(conn, schema_name, category_key, current_page + 1)
      return
    end

    if category.key == "tables" or category.key == "views" then
      data_viewer.open_for_item(conn, choice.item)
      return
    end

    insert_schema_object(choice.item, category)
  end)
end

local BROWSER_PAGE_SIZE = 1000

local function open_schema_browser(conn, schema_name, category_key, page)
  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if not has_telescope then
    native_browser(conn, schema_name, category_key, page)
    return
  end

  local category = schema_category_by_key(category_key or "tables")
  local schema_sql_name = trim(schema_name)
  local current_page = page or 1
  local offset = (current_page - 1) * BROWSER_PAGE_SIZE

  -- Fetch one extra to detect if there is a next page.
  local items, err = schema_list_items(conn.dsn, category, schema_sql_name, "", BROWSER_PAGE_SIZE + 1, offset)

  if not items then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local has_next = #items > BROWSER_PAGE_SIZE
  if has_next then
    while #items > BROWSER_PAGE_SIZE do
      table.remove(items)
    end
  end

  local alias = trim(conn.alias)
  if alias ~= "" and alias ~= "temporaria" and conn.persistent_cache then
    conn.persistent_cache = upsert_persistent_schema_objects(alias, schema_sql_name, category.key, items, false)
  end
  apply_source_status(items, "live")

  -- Pagination hint rows (non-selectable).
  if has_next then
    table.insert(items, {
      kind = "hint",
      name = string.format("<C-g>  próxima página (%d)", current_page + 1),
      schema = schema_sql_name,
      type = category.label,
    })
  end
  if current_page > 1 then
    table.insert(items, 1, {
      kind = "hint",
      name = string.format("<C-e>  página anterior (%d)", current_page - 1),
      schema = schema_sql_name,
      type = category.label,
    })
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 12 },
      { remaining = true },
    },
  })

  local function make_entry(item)
    if item.kind == "hint" or item.kind == "error" then
      local display = string.format("[info] %s", item.name)
      return {
        value = display,
        item = item,
        display = display,
        ordinal = display,
      }
    end

    local schema = item.schema or schema_sql_name
    local name = item.name or "<name>"
    local text = string.format("%s.%s", schema, name)
    local badge = browser_source_label(item)
    return {
      value = text,
      item = item,
      ordinal = text,
      display = function()
        return displayer({ badge, text })
      end,
    }
  end

  pickers
    .new(require("telescope.themes").get_dropdown({
      prompt_title = current_page > 1
        and string.format("%s | %s (%s) [Pág. %d]", schema_sql_name, category.label, conn.alias, current_page)
        or  string.format("%s | %s (%s)", schema_sql_name, category.label, conn.alias),
      layout_strategy = "horizontal",
      layout_config = {
        width = 0.9,
        height = 0.78,
        preview_width = 0.58,
      },
    }), {
      finder = finders.new_table({
        results = items,
        entry_maker = make_entry,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local preview = schema_browser_preview(conn, category, entry.item)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(preview, "\n", { plain = true }))
          vim.bo[self.state.bufnr].filetype = "txt"
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        local function reopen(next_category_key)
          actions.close(prompt_bufnr)
          vim.schedule(function()
            open_schema_browser(conn, schema_sql_name, next_category_key, 1)
          end)
        end

        local function map(lhs, fn)
          vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = prompt_bufnr, silent = true })
        end

        if has_next then
          map("<C-g>", function()
            actions.close(prompt_bufnr)
            vim.schedule(function()
              open_schema_browser(conn, schema_sql_name, category.key, current_page + 1)
            end)
          end)
        end
        if current_page > 1 then
          map("<C-e>", function()
            actions.close(prompt_bufnr)
            vim.schedule(function()
              open_schema_browser(conn, schema_sql_name, category.key, current_page - 1)
            end)
          end)
        end

        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry or not entry.item or entry.item.kind == "hint" or entry.item.kind == "error" then
            return
          end
          if category.key == "tables" or category.key == "views" then
            vim.schedule(function()
              data_viewer.open_for_item(conn, entry.item)
            end)
            return
          end
          insert_schema_object(entry.item, category)
        end)

        map("<C-y>", function()
          local entry = action_state.get_selected_entry()
          if not entry or not entry.item or entry.item.kind == "hint" or entry.item.kind == "error" then
            return
          end
          actions.close(prompt_bufnr)
          vim.schedule(function()
            insert_schema_object(entry.item, category)
          end)
        end)

        map("<Up>", function()
          actions.move_selection_previous(prompt_bufnr)
        end)
        map("<Down>", function()
          actions.move_selection_next(prompt_bufnr)
        end)
        map("<PageUp>", function()
          actions.results_scrolling_up(prompt_bufnr)
        end)
        map("<PageDown>", function()
          actions.results_scrolling_down(prompt_bufnr)
        end)
        map("<S-PageUp>", function()
          actions.preview_scrolling_up(prompt_bufnr)
        end)
        map("<S-PageDown>", function()
          actions.preview_scrolling_down(prompt_bufnr)
        end)
        map("<Space>t", function()
          reopen("tables")
        end)
        map("<Space>v", function()
          reopen("views")
        end)
        map("<Space>f", function()
          reopen("functions")
        end)
        map("<Space>p", function()
          reopen("procedures")
        end)
        map("<Space>n", function()
          reopen(next_schema_category(category.key, 1).key)
        end)
        map("<Space>b", function()
          reopen(next_schema_category(category.key, -1).key)
        end)
        map("<Space>s", function()
          actions.close(prompt_bufnr)
          vim.schedule(function()
            M.browser()
          end)
        end)

        return true
      end,
    })
    :find()
end

local function open_schema_picker(conn)
  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if not has_telescope then
    local schemas, err = schemas_for_connection(conn)
    if not schemas then
      notify(err, vim.log.levels.ERROR)
      return
    end
    picker.select(schemas, {
      prompt = "SQL Schemas",
      format_item = function(item)
        return string.format("%s  T:%d V:%d F:%d P:%d", item.name, item.tables_count or 0, item.views_count or 0, item.functions_count or 0, item.procedures_count or 0)
      end,
    }, function(choice)
      if choice then
        native_browser(conn, choice.name, "tables")
      end
    end)
    return
  end

  local schemas, err = schemas_for_connection(conn)
  if not schemas then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new(require("telescope.themes").get_dropdown({
      prompt_title = string.format("SQL Schemas (%s)", conn.alias),
      layout_strategy = "horizontal",
      layout_config = {
        width = 0.82,
        height = 0.72,
        preview_width = 0.5,
      },
    }), {
      finder = finders.new_table({
        results = schemas,
        entry_maker = function(item)
          local display = string.format(
            "%s  T:%d V:%d F:%d P:%d",
            item.name,
            item.tables_count or 0,
            item.views_count or 0,
            item.functions_count or 0,
            item.procedures_count or 0
          )
          return {
            value = item.name,
            item = item,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local preview = schema_summary_preview(entry.item, conn)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(preview, "\n", { plain = true }))
          vim.bo[self.state.bufnr].filetype = "txt"
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.item then
            vim.schedule(function()
              open_schema_browser(conn, entry.item.name, "tables")
            end)
          end
        end)
        return true
      end,
    })
    :find()
end

function M._build_cache_for_connection(conn)
  local alias = trim(conn.alias)
  if alias == "" or alias == "temporaria" then
    return nil, "cache persistente requer uma conexao salva"
  end

  local schemas, err = list_schemas(conn.dsn)
  if not schemas then
    return nil, err
  end

  local manifest = {
    alias = alias,
    built_at = os.date("%Y-%m-%d %H:%M:%S"),
    schemas = schemas,
    version = 2,
    partial = true,
  }
  save_persistent_manifest(alias, manifest)
  conn.persistent_cache = manifest

  local preferred_categories = { "tables", "views", "functions", "procedures" }

  for index, schema_item in ipairs(schemas) do
    local schema_name = schema_item.name
    local bundle = load_persistent_bundle(alias, schema_name) or {
      schema = schema_name,
      objects = {
        tables = {},
        views = {},
        functions = {},
        procedures = {},
      },
      columns = {},
      complete = {
        tables = false,
        views = false,
        functions = false,
        procedures = false,
      },
    }

    update_loading_panel(conn._loading_panel, {
      "sqlui schema cache",
      string.format("Conexao: %s", alias),
      string.format("Schema %d/%d: %s", index, #schemas, schema_name),
      "Etapa: objetos (tabelas/views/functions/procedures)",
      "",
      "Fechando automaticamente ao concluir.",
    })

    for _, category_key in ipairs(preferred_categories) do
      local category
      for _, candidate in ipairs(schema_categories) do
        if candidate.key == category_key then
          category = candidate
          break
        end
      end

      if category and not (bundle.complete and bundle.complete[category.key] == true) then
        local items, category_err = schema_list_items(conn.dsn, category, schema_name, nil, nil)
        if not items then
          return nil, category_err
        end
        bundle.objects[category.key] = items
        bundle.complete[category.key] = true
        save_persistent_bundle(alias, schema_name, bundle)
        session.schema_cache[schema_bundle_cache_key(alias, schema_name)] = vim.deepcopy(bundle)
      end
    end

    update_loading_panel(conn._loading_panel, {
      "sqlui schema cache",
      string.format("Conexao: %s", alias),
      string.format("Schema %d/%d: %s", index, #schemas, schema_name),
      "Etapa: colunas",
      "",
      "Fechando automaticamente ao concluir.",
    })

    if next(bundle.columns or {}) == nil then
      local columns, columns_err = build_columns_cache_for_schema(conn.dsn, schema_name)
      if columns then
        bundle.columns = columns
        save_persistent_bundle(alias, schema_name, bundle)
        session.schema_cache[schema_bundle_cache_key(alias, schema_name)] = vim.deepcopy(bundle)
      elseif columns_err then
        notify("cache de colunas nao gerado para schema '" .. schema_name .. "': " .. columns_err, vim.log.levels.WARN)
      end
    end

    manifest.built_at = os.date("%Y-%m-%d %H:%M:%S")
    save_persistent_manifest(alias, manifest)
  end

  manifest.built_at = os.date("%Y-%m-%d %H:%M:%S")
  manifest.partial = false
  save_persistent_manifest(alias, manifest)
  conn.persistent_cache = manifest
  return manifest, nil
end

function M.build_cache()
  if not ensure_dependency(usql_bin(), "usql nao encontrado no PATH") then
    return
  end

  local function run(conn)
    local loading = loading_panel("Gerando cache local para " .. conn.alias)
    conn._loading_panel = loading
    vim.schedule(function()
      vim.defer_fn(function()
        local cache, err = M._build_cache_for_connection(conn)
        conn._loading_panel = nil
        close_loading_panel(loading, function()
          if not cache then
            notify(err or "falha ao gerar cache SQL", vim.log.levels.ERROR)
            return
          end
          clear_runtime_cache()
          notify("cache SQL atualizado para '" .. conn.alias .. "'")
        end)
      end, 30)
    end)
  end

  local conn = state.get_current_connection()
  if conn and trim(conn.alias) ~= "" and conn.alias ~= "temporaria" then
    run(conn)
    return
  end

  local alias = state.get_last_connection_alias()
  if alias then
    conn = connection.load(alias)
    if conn and trim(conn.alias) ~= "" and conn.alias ~= "temporaria" then
      state.set_current_connection(conn)
      run(conn)
      return
    end
  end

  connection.select_existing(run)
end

function M.clear_cache()
  connection.select_existing(function(conn)
    delete_persistent_cache(conn.alias)
    clear_runtime_cache()
    notify("cache SQL removido para '" .. conn.alias .. "'")
  end)
end

function M.browser()
  if not ensure_dependency(usql_bin(), "usql nao encontrado no PATH") then
    return
  end

  local conn = state.get_current_connection()
  if not conn then
    local alias = state.get_last_connection_alias()
    if alias then
      conn = connection.load(alias)
      if conn then
        state.set_current_connection(conn)
      end
    end
  end

  local function start_browser(selected_conn)
    resolve_schema_connection(selected_conn, function(resolved)
      open_schema_picker(resolved)
    end)
  end

  if conn then
    start_browser(conn)
    return
  end

  connection.select(function(selected_conn)
    start_browser(selected_conn)
  end)
end

function M.get_completion_items(prefix)
  local conn = state.get_current_connection()
  if not conn then
    local alias = state.get_last_connection_alias()
    if alias then
      conn = connection.load(alias)
    end
  end

  if not conn then
    return {}
  end

  local alias = trim(conn.alias)
  if alias == "" or alias == "temporaria" then
    return {}
  end

  local manifest = load_persistent_manifest(alias)
  if not manifest or type(manifest.schemas) ~= "table" then
    return {}
  end

  local search = trim(prefix or ""):lower()
  if search == "" then
    return {}
  end

  local items = {}
  local seen = {}
  for _, schema_item in ipairs(manifest.schemas or {}) do
    local schema_name = schema_item.name
    local bundle_key = schema_bundle_cache_key(alias, schema_name)
    local bundle = session.schema_cache[bundle_key]
    if not bundle then
      bundle = load_persistent_bundle(alias, schema_name)
      if bundle then
        session.schema_cache[bundle_key] = bundle
      end
    end

    if bundle and type(bundle.objects) == "table" then
      for _, category in ipairs(schema_categories) do
        local schema_items = bundle.objects[category.key] or {}
        for _, item in ipairs(schema_items) do
          local full_name = string.format("%s.%s", schema_name, item.name)
          local full_lower = full_name:lower()
          local short_lower = tostring(item.name or ""):lower()
          if (full_lower:sub(1, #search) == search or short_lower:sub(1, #search) == search) and not seen[full_name] then
            seen[full_name] = true
            local insert_text = full_name
            if category.key == "functions" or category.key == "procedures" then
              insert_text = full_name .. "()"
            end
            table.insert(items, {
              label = full_name,
              insert_text = insert_text,
              kind = category.key,
            })
            if #items >= 200 then
              return items
            end
          end
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

return M
