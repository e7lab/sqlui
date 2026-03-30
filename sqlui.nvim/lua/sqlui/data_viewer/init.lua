local connection = require("sqlui.connection")
local picker = require("sqlui.ui.picker")
local state = require("sqlui.state")

local M = {}

local viewers = {}
local page_size = 100

local function trim(value)
  return vim.trim(value or "")
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "sqlui" })
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

local function driver_from_dsn(dsn)
  local scheme = trim((dsn or ""):match("^([%w+]+):")):lower()
  if scheme == "postgres" or scheme == "postgresql" then
    return "postgres"
  end
  if scheme == "mysql" or scheme == "mariadb" then
    return "mysql"
  end
  if scheme == "mssql" or scheme == "sqlserver" then
    return "mssql"
  end
  return scheme ~= "" and scheme or "mssql"
end

local function quote_ident(driver, value)
  if driver == "mysql" then
    return "`" .. tostring(value):gsub("`", "``") .. "`"
  end
  if driver == "mssql" then
    return "[" .. tostring(value):gsub("]", "]]" ) .. "]"
  end
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function escape_sql_string(value)
  return tostring(value or ""):gsub("'", "''")
end

local function object_ref(driver, schema_name, object_name)
  return string.format("%s.%s", quote_ident(driver, schema_name), quote_ident(driver, object_name))
end

local function run_usql_json(conn, sql)
  local result = vim.system({ usql_bin(), "-J", "-c", sql, conn.dsn }, { text = true }):wait()
  if result.code ~= 0 then
    local err = trim(result.stderr)
    if err == "" then
      err = trim(result.stdout)
    end
    return nil, err ~= "" and err or "falha ao consultar dados"
  end

  local body = trim(result.stdout)
  if body == "" then
    return {}, nil
  end

  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "nao foi possivel decodificar a resposta JSON"
  end
  return decoded, nil
end

local function split_target(target)
  local schema_name, object_name = tostring(target or ""):match("^([^%.]+)%.(.+)$")
  if schema_name and object_name then
    return schema_name, object_name
  end
  return nil, nil
end

local function resolve_connection(on_ready)
  local conn = state.get_current_connection()
  if conn and trim(conn.dsn) ~= "" then
    on_ready(conn)
    return
  end

  local alias = state.get_last_connection_alias()
  if alias then
    conn = connection.load(alias)
    if conn then
      state.set_current_connection(conn)
      on_ready(conn)
      return
    end
  end

  connection.select(function(selected)
    on_ready(selected)
  end)
end

local function column_query(driver, schema_name, object_name)
  local where = string.format(
    "TABLE_SCHEMA = '%s' and TABLE_NAME = '%s'",
    escape_sql_string(schema_name),
    escape_sql_string(object_name)
  )
  if driver == "mssql" or driver == "postgres" or driver == "mysql" then
    return "select COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.COLUMNS where " .. where .. " order by ORDINAL_POSITION"
  end
  return "select COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.COLUMNS where " .. where .. " order by ORDINAL_POSITION"
end

local function primary_key_query(schema_name, object_name)
  return string.format(
    [[select kcu.COLUMN_NAME, kcu.ORDINAL_POSITION
from INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
join INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
  on tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
 and tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
 and tc.TABLE_NAME = kcu.TABLE_NAME
where tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
  and tc.TABLE_SCHEMA = '%s'
  and tc.TABLE_NAME = '%s'
order by kcu.ORDINAL_POSITION]],
    escape_sql_string(schema_name),
    escape_sql_string(object_name)
  )
end

local function discover_columns(conn, schema_name, object_name)
  local rows, err = run_usql_json(conn, column_query(driver_from_dsn(conn.dsn), schema_name, object_name))
  if not rows then
    return nil, err
  end

  local columns = {}
  for _, row in ipairs(rows) do
    table.insert(columns, {
      name = row.COLUMN_NAME or row.column_name,
      data_type = row.DATA_TYPE or row.data_type,
      ordinal = row.ORDINAL_POSITION or row.ordinal_position,
    })
  end
  return columns, nil
end

local function discover_primary_key(conn, schema_name, object_name)
  local rows = run_usql_json(conn, primary_key_query(schema_name, object_name))
  if type(rows) ~= "table" then
    return {}
  end

  local columns = {}
  for _, row in ipairs(rows) do
    table.insert(columns, row.COLUMN_NAME or row.column_name)
  end
  return columns
end

local function sql_literal(raw)
  local value = trim(raw)
  if value:lower() == "null" then
    return nil, true
  end
  if value:match("^-?%d+%.?%d*$") then
    return value, false
  end
  return "'" .. escape_sql_string(value) .. "'", false
end

local function normalize_filter_parts(value)
  local parts = {}
  for _, part in ipairs(vim.split(value or "", ";", { plain = true, trimempty = true })) do
    local clean = trim(part)
    if clean ~= "" then
      table.insert(parts, clean)
    end
  end
  return parts
end

local function build_filter_clause(driver, filter_text)
  local parts = normalize_filter_parts(filter_text)
  if vim.tbl_isempty(parts) then
    return nil
  end

  local clauses = {}
  for _, text in ipairs(parts) do
    local column, op, value = text:match("^([%w_]+)%s*([=~])%s*(.+)$")
    if not column then
      return nil, "use o formato coluna=valor ou coluna~valor;coluna2=valor2"
    end

    local quoted = quote_ident(driver, column)
    if op == "~" then
      table.insert(clauses, string.format("%s LIKE '%%%s%%'", quoted, escape_sql_string(value)))
    else
      local literal, is_null = sql_literal(value)
      if is_null then
        table.insert(clauses, string.format("%s IS NULL", quoted))
      else
        table.insert(clauses, string.format("%s = %s", quoted, literal))
      end
    end
  end

  return table.concat(clauses, " AND ")
end

local function build_page_query(ctx)
  local driver = ctx.driver
  local ref = object_ref(driver, ctx.schema_name, ctx.object_name)
  local where_clause, where_err = build_filter_clause(driver, ctx.filter)
  if where_err then
    return nil, where_err
  end

  local where_sql = where_clause and (" where " .. where_clause) or ""
  local order_column = quote_ident(driver, ctx.order_by)
  local offset = (ctx.page - 1) * ctx.page_size
  local limit = ctx.page_size + 1

  if driver == "mssql" then
    return string.format(
      "select * from %s%s order by %s offset %d rows fetch next %d rows only",
      ref,
      where_sql,
      order_column,
      offset,
      limit
    )
  end

  return string.format(
    "select * from %s%s order by %s limit %d offset %d",
    ref,
    where_sql,
    order_column,
    limit,
    offset
  )
end

local function normalize_row(columns, row)
  local values = {}
  for _, col in ipairs(columns) do
    values[col.name] = row[col.name]
  end
  return values
end

local function fetch_page(ctx)
  local sql, err = build_page_query(ctx)
  if not sql then
    return nil, err
  end

  local rows, query_err = run_usql_json(ctx.conn, sql)
  if not rows then
    return nil, query_err
  end

  local has_next = #rows > ctx.page_size
  while #rows > ctx.page_size do
    table.remove(rows)
  end

  local normalized = {}
  for _, row in ipairs(rows) do
    table.insert(normalized, normalize_row(ctx.columns, row))
  end

  return normalized, has_next, nil
end

local function format_cell(value)
  if value == nil then
    return "NULL"
  end
  local text = tostring(value):gsub("\r\n", " "):gsub("\n", " ")
  if #text > 40 then
    return text:sub(1, 37) .. "..."
  end
  return text
end

local function render_table(ctx)
  local widths = {}
  for _, col in ipairs(ctx.columns) do
    widths[col.name] = math.min(math.max(#tostring(col.name), 8), 24)
  end

  for _, row in ipairs(ctx.rows or {}) do
    for _, col in ipairs(ctx.columns) do
      widths[col.name] = math.min(math.max(widths[col.name], #format_cell(row[col.name])), 24)
    end
  end

  local function line_from_row(map)
    local parts = {}
    for _, col in ipairs(ctx.columns) do
      local text = map[col.name] or col.name
      table.insert(parts, string.format("%-" .. widths[col.name] .. "s", text))
    end
    return table.concat(parts, " | ")
  end

  local header_map = {}
  for _, col in ipairs(ctx.columns) do
    header_map[col.name] = col.name
  end

  local header = line_from_row(header_map)
  local separator = string.rep("-", #header)
  local lines = {
    string.format("%s.%s", ctx.schema_name, ctx.object_name),
    string.format("Pagina: %d | Ordem: %s | Filtro: %s", ctx.page, ctx.order_by, trim(ctx.filter) ~= "" and ctx.filter or "<nenhum>"),
    string.format("Atalhos: ]p proxima | [p anterior | ff filtro | fo ordenar | r recarregar | q fechar"),
    "",
    header,
    separator,
  }

  for _, row in ipairs(ctx.rows or {}) do
    local row_map = {}
    for _, col in ipairs(ctx.columns) do
      row_map[col.name] = format_cell(row[col.name])
    end
    table.insert(lines, line_from_row(row_map))
  end

  if vim.tbl_isempty(ctx.rows or {}) then
    table.insert(lines, "<sem linhas nesta pagina>")
  end

  if ctx.has_next then
    table.insert(lines, "")
    table.insert(lines, "Existe proxima pagina.")
  end

  return lines
end

local function refresh_viewer(bufnr)
  local ctx = viewers[bufnr]
  if not ctx then
    return
  end

  local rows, has_next, err = fetch_page(ctx)
  if not rows then
    notify(err, vim.log.levels.ERROR)
    return
  end

  ctx.rows = rows
  ctx.has_next = has_next

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, render_table(ctx))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function set_viewer_maps(bufnr)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
  end

  map("]p", function()
    local ctx = viewers[bufnr]
    if not ctx or not ctx.has_next then
      notify("nao ha proxima pagina", vim.log.levels.WARN)
      return
    end
    ctx.page = ctx.page + 1
    refresh_viewer(bufnr)
  end, "sqlui next page")

  map("[p", function()
    local ctx = viewers[bufnr]
    if not ctx or ctx.page <= 1 then
      notify("ja esta na primeira pagina", vim.log.levels.WARN)
      return
    end
    ctx.page = ctx.page - 1
    refresh_viewer(bufnr)
  end, "sqlui previous page")

  map("ff", function()
    local ctx = viewers[bufnr]
    if not ctx then
      return
    end
    picker.input({ prompt = "Filtro (coluna=valor;coluna2~valor): ", default = ctx.filter or "" }, function(value)
      ctx.filter = trim(value)
      ctx.page = 1
      refresh_viewer(bufnr)
    end)
  end, "sqlui set filter")

  map("fc", function()
    local ctx = viewers[bufnr]
    if not ctx then
      return
    end
    ctx.filter = ""
    ctx.page = 1
    refresh_viewer(bufnr)
  end, "sqlui clear filter")

  map("fo", function()
    local ctx = viewers[bufnr]
    if not ctx then
      return
    end
    picker.select(ctx.columns, {
      prompt = "Ordenar por coluna",
      format_item = function(item)
        return item.name
      end,
    }, function(choice)
      if not choice then
        return
      end
      ctx.order_by = choice.name
      ctx.page = 1
      refresh_viewer(bufnr)
    end)
  end, "sqlui change order")

  map("r", function()
    refresh_viewer(bufnr)
  end, "sqlui refresh")

  map("q", function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end, "sqlui close viewer")
end

local function open_viewer(ctx)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  viewers[buf] = ctx
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sql"
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  set_viewer_maps(buf)
  refresh_viewer(buf)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      viewers[buf] = nil
    end,
  })
end

function M.open_for_item(conn, item)
  if not ensure_dependency(usql_bin(), "usql nao encontrado no PATH") then
    return
  end
  if not item or not item.schema or not item.name then
    notify("objeto SQL invalido para visualizacao", vim.log.levels.ERROR)
    return
  end

  local columns, err = discover_columns(conn, item.schema, item.name)
  if not columns or vim.tbl_isempty(columns) then
    notify(err or "nao foi possivel descobrir colunas do objeto", vim.log.levels.ERROR)
    return
  end

  local pk = discover_primary_key(conn, item.schema, item.name)
  local order_by = pk[1] or columns[1].name
  open_viewer({
    conn = conn,
    driver = driver_from_dsn(conn.dsn),
    schema_name = item.schema,
    object_name = item.name,
    columns = columns,
    order_by = order_by,
    filter = "",
    page = 1,
    page_size = page_size,
    rows = {},
    has_next = false,
  })
end

function M.view(target)
  if not ensure_dependency(usql_bin(), "usql nao encontrado no PATH") then
    return
  end

  local function with_conn(conn)
    local schema_name, object_name = split_target(target)
    if schema_name and object_name then
      M.open_for_item(conn, {
        schema = schema_name,
        name = object_name,
        type = "TABLE",
      })
      return
    end

    picker.input({ prompt = "Objeto para visualizar (schema.tabela): ", default = target or "" }, function(value)
      local s, o = split_target(value)
      if not s or not o then
        notify("use o formato schema.tabela", vim.log.levels.WARN)
        return
      end
      M.open_for_item(conn, {
        schema = s,
        name = o,
        type = "TABLE",
      })
    end)
  end

  resolve_connection(with_conn)
end

return M
