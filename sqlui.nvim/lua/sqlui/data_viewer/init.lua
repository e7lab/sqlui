local connection = require("sqlui.connection")
local picker = require("sqlui.ui.picker")
local state = require("sqlui.state")

local M = {}

local viewers = {}
local default_page_size = 100
local max_col_width = 40
local page_size_options = { 25, 50, 100, 250, 500 }

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
  if scheme == "sqlite3" or scheme == "sqlite" or scheme == "file" then
    return "sqlite"
  end
  return scheme ~= "" and scheme or "mssql"
end

local function quote_ident(driver, value)
  if driver == "mysql" then
    return "`" .. tostring(value):gsub("`", "``") .. "`"
  end
  if driver == "mssql" then
    return "[" .. tostring(value):gsub("]", "]]") .. "]"
  end
  -- postgres, sqlite, and others use double-quote
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function escape_sql_string(value)
  return tostring(value or ""):gsub("'", "''")
end

local function object_ref(driver, schema_name, object_name)
  if driver == "sqlite" then
    -- SQLite: just table name is sufficient; "main"."table" also works but is unnecessary
    return quote_ident(driver, object_name)
  end
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
  if driver == "sqlite" then
    return string.format("PRAGMA table_info('%s')", escape_sql_string(object_name))
  end
  local where = string.format(
    "TABLE_SCHEMA = '%s' and TABLE_NAME = '%s'",
    escape_sql_string(schema_name),
    escape_sql_string(object_name)
  )
  return "select COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION from INFORMATION_SCHEMA.COLUMNS where " .. where .. " order by ORDINAL_POSITION"
end

local function primary_key_query(driver, schema_name, object_name)
  if driver == "sqlite" then
    -- PRAGMA table_info returns `pk` field (> 0 for PK columns)
    -- We can't filter PRAGMAs with WHERE, so we'll handle filtering in Lua
    return string.format("PRAGMA table_info('%s')", escape_sql_string(object_name))
  end
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
  local driver = driver_from_dsn(conn.dsn)
  local rows, err = run_usql_json(conn, column_query(driver, schema_name, object_name))
  if not rows then
    return nil, err
  end

  local columns = {}
  if driver == "sqlite" then
    for _, row in ipairs(rows) do
      table.insert(columns, {
        name = row.name or row.NAME,
        data_type = row.type or row.TYPE or "TEXT",
        ordinal = row.cid or row.CID,
      })
    end
  else
    for _, row in ipairs(rows) do
      table.insert(columns, {
        name = row.COLUMN_NAME or row.column_name,
        data_type = row.DATA_TYPE or row.data_type,
        ordinal = row.ORDINAL_POSITION or row.ordinal_position,
      })
    end
  end
  return columns, nil
end

local function discover_primary_key(conn, schema_name, object_name)
  local driver = driver_from_dsn(conn.dsn)
  local rows = run_usql_json(conn, primary_key_query(driver, schema_name, object_name))
  if type(rows) ~= "table" then
    return {}
  end

  local columns = {}
  if driver == "sqlite" then
    -- PRAGMA table_info returns all columns; filter where pk > 0
    for _, row in ipairs(rows) do
      local pk = tonumber(row.pk or row.PK or 0) or 0
      if pk > 0 then
        table.insert(columns, row.name or row.NAME)
      end
    end
  else
    for _, row in ipairs(rows) do
      table.insert(columns, row.COLUMN_NAME or row.column_name)
    end
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
      local like_target = driver == "postgres"
        and string.format("CAST(%s AS text)", quoted)
        or quoted
      local like_op = driver == "postgres" and "ILIKE" or "LIKE"
      table.insert(clauses, string.format("%s %s '%%%s%%'", like_target, like_op, escape_sql_string(value)))
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
    return nil, nil, err
  end

  local rows, query_err = run_usql_json(ctx.conn, sql)
  if not rows then
    return nil, nil, query_err
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

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function format_cell(value, width)
  local text
  if value == nil then
    text = "NULL"
  else
    text = tostring(value):gsub("\r\n", " "):gsub("\n", " ")
  end
  if #text > width then
    return text:sub(1, width - 3) .. "..."
  end
  return text
end

local function compute_widths(columns, rows)
  local widths = {}
  for _, col in ipairs(columns) do
    widths[col.name] = math.max(#tostring(col.name), 4)
  end
  for _, row in ipairs(rows or {}) do
    for _, col in ipairs(columns) do
      local raw = row[col.name]
      local len
      if raw == nil then
        len = 4 -- "NULL"
      else
        len = #tostring(raw):gsub("\r\n", " "):gsub("\n", " ")
      end
      widths[col.name] = math.max(widths[col.name], len)
    end
  end
  -- cap each column to max_col_width
  for name, w in pairs(widths) do
    widths[name] = math.min(w, max_col_width)
  end
  return widths
end

local function line_from_row(columns, widths, map)
  local parts = {}
  for _, col in ipairs(columns) do
    local w = widths[col.name]
    local text = format_cell(map[col.name], w)
    table.insert(parts, string.format("%-" .. w .. "s", text))
  end
  return table.concat(parts, " | ")
end

local function build_header_lines(ctx, widths)
  local header_map = {}
  for _, col in ipairs(ctx.columns) do
    header_map[col.name] = col.name
  end

  local header = line_from_row(ctx.columns, widths, header_map)
  local separator = string.rep("-", #header)

  return {
    string.format(
      "%s.%s  |  Pag: %d  |  Linhas/pag: %d  |  Ordem: %s  |  Filtro: %s",
      ctx.schema_name,
      ctx.object_name,
      ctx.page,
      ctx.page_size,
      ctx.order_by,
      trim(ctx.filter) ~= "" and ctx.filter or "<nenhum>"
    ),
    "Atalhos: ]p prox | [p ant | ff filtro | fc limpar | fo ordenar | fp linhas/pag | r recarregar | q fechar",
    header,
    separator,
  }
end

local function build_data_lines(ctx, widths)
  local lines = {}
  for _, row in ipairs(ctx.rows or {}) do
    table.insert(lines, line_from_row(ctx.columns, widths, row))
  end
  if vim.tbl_isempty(ctx.rows or {}) then
    table.insert(lines, "<sem linhas nesta pagina>")
  end
  if ctx.has_next then
    table.insert(lines, "")
    table.insert(lines, "-- proxima pagina disponivel (]p) --")
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Split-window viewer (fixed header)
-- ---------------------------------------------------------------------------

local function set_buf_opts(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "sqlui_viewer"
end

local function set_win_opts(winid)
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].cursorline = false
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].winfixheight = true
end

local function write_buf(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function sync_header_scroll(header_win, data_win)
  if not vim.api.nvim_win_is_valid(header_win) or not vim.api.nvim_win_is_valid(data_win) then
    return
  end
  local data_view = vim.api.nvim_win_call(data_win, function()
    return vim.fn.winsaveview()
  end)
  vim.api.nvim_win_call(header_win, function()
    vim.fn.winrestview({ leftcol = data_view.leftcol })
  end)
end

--- Create a per-viewer throttled scroll sync (50ms debounce).
--- Each viewer gets its own timer to avoid cross-view contention.
local function make_throttled_scroll_sync(data_bufnr)
  local timer = nil
  return function(header_win, data_win)
    if timer then
      timer:stop()
    end
    timer = vim.defer_fn(function()
      timer = nil
      -- Guard: viewer may have been closed during debounce
      if viewers[data_bufnr] then
        sync_header_scroll(header_win, data_win)
      end
    end, 50)
  end
end

local function refresh_viewer(data_bufnr)
  local ctx = viewers[data_bufnr]
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

  local widths = compute_widths(ctx.columns, ctx.rows)
  ctx._widths = widths

  write_buf(ctx.header_buf, build_header_lines(ctx, widths))
  write_buf(data_bufnr, build_data_lines(ctx, widths))

  -- resize header window to exactly 4 lines (info + shortcuts + header + separator)
  if vim.api.nvim_win_is_valid(ctx.header_win) then
    vim.api.nvim_win_set_height(ctx.header_win, 4)
  end
end

local function close_viewer(data_bufnr)
  local ctx = viewers[data_bufnr]
  if not ctx then
    return
  end
  -- close the whole tab
  local tab = ctx.tab
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    -- delete both buffers, tab will close
    local bufs = { ctx.header_buf, data_bufnr }
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
  end
  viewers[data_bufnr] = nil
end

local function set_viewer_maps(data_bufnr)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = data_bufnr, silent = true, desc = desc })
  end

  map("]p", function()
    local ctx = viewers[data_bufnr]
    if not ctx or not ctx.has_next then
      notify("nao ha proxima pagina", vim.log.levels.WARN)
      return
    end
    ctx.page = ctx.page + 1
    refresh_viewer(data_bufnr)
  end, "sqlui next page")

  map("[p", function()
    local ctx = viewers[data_bufnr]
    if not ctx or ctx.page <= 1 then
      notify("ja esta na primeira pagina", vim.log.levels.WARN)
      return
    end
    ctx.page = ctx.page - 1
    refresh_viewer(data_bufnr)
  end, "sqlui previous page")

  map("ff", function()
    local ctx = viewers[data_bufnr]
    if not ctx then
      return
    end
    picker.input({ prompt = "Filtro (coluna=valor;coluna2~valor): ", default = ctx.filter or "" }, function(value)
      ctx.filter = trim(value)
      ctx.page = 1
      refresh_viewer(data_bufnr)
    end)
  end, "sqlui set filter")

  map("fc", function()
    local ctx = viewers[data_bufnr]
    if not ctx then
      return
    end
    ctx.filter = ""
    ctx.page = 1
    refresh_viewer(data_bufnr)
  end, "sqlui clear filter")

  map("fo", function()
    local ctx = viewers[data_bufnr]
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
      refresh_viewer(data_bufnr)
    end)
  end, "sqlui change order")

  map("fp", function()
    local ctx = viewers[data_bufnr]
    if not ctx then
      return
    end
    local items = {}
    for _, size in ipairs(page_size_options) do
      local label = tostring(size)
      if size == ctx.page_size then
        label = label .. " (atual)"
      end
      table.insert(items, { label = label, value = size })
    end
    picker.select(items, {
      prompt = "Linhas por pagina",
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      ctx.page_size = choice.value
      ctx.page = 1
      refresh_viewer(data_bufnr)
    end)
  end, "sqlui change page size")

  map("r", function()
    refresh_viewer(data_bufnr)
  end, "sqlui refresh")

  map("q", function()
    close_viewer(data_bufnr)
  end, "sqlui close viewer")
end

local function open_viewer(ctx)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()

  -- The tabnew created one window; we'll use it for the header
  local header_win = vim.api.nvim_get_current_win()
  local header_buf = vim.api.nvim_get_current_buf()

  set_buf_opts(header_buf)

  -- Create the data buffer + window below the header
  vim.cmd("belowright new")
  local data_win = vim.api.nvim_get_current_win()
  local data_buf = vim.api.nvim_get_current_buf()
  set_buf_opts(data_buf)

  -- Configure windows
  set_win_opts(header_win)
  set_win_opts(data_win)
  vim.wo[data_win].cursorline = true

  -- Header is fixed height (4 lines)
  vim.api.nvim_win_set_height(header_win, 4)

  -- Store context keyed by data buffer
  ctx.header_buf = header_buf
  ctx.header_win = header_win
  ctx.data_win = data_win
  ctx.tab = tab
  viewers[data_buf] = ctx

  -- Focus the data window
  vim.api.nvim_set_current_win(data_win)

  set_viewer_maps(data_buf)
  refresh_viewer(data_buf)

  -- Per-viewer throttled scroll sync (avoids cross-view timer contention)
  local throttled_scroll = make_throttled_scroll_sync(data_buf)

  -- Sync horizontal scroll: when cursor moves in data, update header leftcol (throttled)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    buffer = data_buf,
    callback = function()
      local c = viewers[data_buf]
      if c then
        throttled_scroll(c.header_win, c.data_win)
      end
    end,
  })

  -- Cleanup on data buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = data_buf,
    callback = function()
      local c = viewers[data_buf]
      if c and vim.api.nvim_buf_is_valid(c.header_buf) then
        pcall(vim.api.nvim_buf_delete, c.header_buf, { force = true })
      end
      viewers[data_buf] = nil
    end,
  })

  -- Cleanup on header buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = header_buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(data_buf) then
        pcall(vim.api.nvim_buf_delete, data_buf, { force = true })
      end
      viewers[data_buf] = nil
    end,
  })

  -- Prevent focus on the header window — redirect to data window
  vim.api.nvim_create_autocmd("WinEnter", {
    callback = function()
      local c = viewers[data_buf]
      if not c then
        return true -- remove autocmd
      end
      if vim.api.nvim_get_current_win() == c.header_win and vim.api.nvim_win_is_valid(c.data_win) then
        vim.api.nvim_set_current_win(c.data_win)
      end
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
    page_size = default_page_size,
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
