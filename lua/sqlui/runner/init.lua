local connection = require("sqlui.connection")
local picker = require("sqlui.ui.picker")
local state = require("sqlui.state")
local fs = require("sqlui.util.fs")
local rpc = require("sqlui.rpc")

local M = {}

local function trim(value)
  return vim.trim(value or "")
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "sqlui" })
end

-- usql_bin() removed (Phase 4) — now using RPC sidecar
-- sqlcmd_bin() removed (Phase 4) — no runner selection needed with RPC

local function history_limit()
  local config = state.get_config() or {}
  return ((config.history or {}).limit) or 20
end

-- ensure_dependency removed (Phase 4) — RPC eliminates external binary dependencies

-- parse_mssql_dsn removed (Phase 4) — sqlcmd not used with RPC

-- execute_with_sqlcmd removed (Phase 4) — replaced by RPC query.execute

local function current_sql_file()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("salve o arquivo SQL antes de executar", vim.log.levels.WARN)
    return nil
  end
  if vim.bo.filetype ~= "sql" and not path:match("%.sql$") then
    notify("o comando so funciona em buffers SQL", vim.log.levels.WARN)
    return nil
  end
  if vim.bo.modified then
    vim.cmd("write")
  end
  return path
end

local function current_sql_selection()
  local visual_mode = vim.fn.visualmode()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  if start_line == 0 or end_line == 0 then
    notify("selecione um trecho SQL em modo visual", vim.log.levels.WARN)
    return nil
  end

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local is_linewise = visual_mode == "V" or end_col >= 2147483647
  local lines
  if is_linewise then
    lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  else
    lines = vim.api.nvim_buf_get_text(0, start_line - 1, math.max(start_col - 1, 0), end_line - 1, end_col, {})
  end

  if vim.tbl_isempty(lines) then
    return nil
  end

  local sql = table.concat(lines, "\n")
  if trim(sql) == "" then
    notify("a selecao visual esta vazia", vim.log.levels.WARN)
    return nil
  end

  return sql
end

local function get_payload(use_selection)
  local sql_file = current_sql_file()
  if not sql_file then
    return nil
  end

  if use_selection then
    local pending = state.consume_visual_payload()
    if pending and pending.sql_file == sql_file then
      return pending
    end

    local sql_text = current_sql_selection()
    if not sql_text then
      return nil
    end
    return {
      sql_file = sql_file,
      sql_text = sql_text,
      source_name = sql_file .. ":selection",
    }
  end

  local lines = vim.fn.readfile(sql_file)
  return {
    sql_file = sql_file,
    sql_text = table.concat(lines, "\n"),
    source_name = sql_file,
  }
end

local function capture_visual_payload()
  local sql_file = current_sql_file()
  if not sql_file then
    return nil
  end

  local visual_mode = vim.fn.mode()
  if visual_mode ~= "v" and visual_mode ~= "V" and visual_mode ~= "\22" then
    return nil
  end

  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  if start_line == 0 or end_line == 0 then
    return nil
  end

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local lines
  if visual_mode == "V" then
    lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  else
    lines = vim.api.nvim_buf_get_text(0, start_line - 1, math.max(start_col - 1, 0), end_line - 1, end_col, {})
  end

  if vim.tbl_isempty(lines) then
    return nil
  end

  local sql_text = table.concat(lines, "\n")
  if trim(sql_text) == "" then
    return nil
  end

  return {
    sql_file = sql_file,
    sql_text = sql_text,
    source_name = sql_file .. ":selection",
  }
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
    "Exportando consulta...",
    message,
    "",
    "Fechando automaticamente ao concluir.",
  })
  vim.cmd("redraw!")
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return { win = win, buf = buf }
end

local function close_loading_panel(handle)
  if not handle then
    return
  end
  if handle.win and vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  elseif handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
    vim.api.nvim_buf_delete(handle.buf, { force = true })
  end
end

local function open_result_file(path, filetype)
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = filetype or "txt"
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.bo[buf].buflisted = false
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
end

local function push_history(conn, payload, result_path)
  local query = payload.sql_text:match("([^\n]+)") or payload.sql_text
  state.add_history({
    alias = conn.alias,
    sql_file = payload.sql_file,
    sql_text = payload.sql_text,
    query = trim(query),
    result_path = result_path,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
  }, history_limit())
end

-- Phase 4: Unified RPC runner (no runner selection needed)
local function execute_payload(conn, payload)
  -- Phase 4: Use RPC to execute queries
  if not conn or not conn.rpc_id then
    notify("conexao nao aberta", vim.log.levels.ERROR)
    return false
  end

  local output_path = fs.tempname(".txt")

  -- Extract SQL: either from file or payload text
  local sql_text
  if payload.sql_file then
    local ok, content = pcall(vim.fn.readfile, payload.sql_file)
    if ok then
      sql_text = table.concat(content, "\n")
    else
      notify("nao foi possivel ler o arquivo SQL", vim.log.levels.ERROR)
      return false
    end
  elseif payload.sql_text then
    sql_text = payload.sql_text
  else
    notify("nenhum SQL para executar", vim.log.levels.WARN)
    return false
  end

  -- Execute via RPC (async)
  rpc.execute(conn.rpc_id, sql_text, function(result, err)
    if err then
      local content = "Erro ao executar query:\n" .. err
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), output_path)
      vim.schedule(function()
        open_result_file(output_path, "txt")
        notify("consulta executada com erro", vim.log.levels.ERROR)
        push_history(conn, payload, output_path)
        state.set_current_connection(conn)
      end)
      return
    end

    -- Format result: rows + columns
    local lines_out = {}
    if result and result.columns and result.rows then
      -- Header: column names
      local header = {}
      for _, col in ipairs(result.columns) do
        table.insert(header, tostring(col.name or "?"))
      end
      table.insert(lines_out, table.concat(header, "\t"))

      -- Rows: values tab-separated
      for _, row in ipairs(result.rows) do
        local row_vals = {}
        for _, col in ipairs(result.columns) do
          local val = row[col.name] or ""
          table.insert(row_vals, tostring(val))
        end
        table.insert(lines_out, table.concat(row_vals, "\t"))
      end
    end

    local content = table.concat(lines_out, "\n")
    if content == "" then
      content = table.concat({
        "Sem linhas retornadas.",
        "",
        "Arquivo: " .. payload.source_name,
        "Conexao: " .. conn.alias,
      }, "\n")
    end

    vim.fn.writefile(vim.split(content, "\n", { plain = true }), output_path)

    vim.schedule(function()
      open_result_file(output_path, "txt")
      notify("consulta executada com sucesso")
      push_history(conn, payload, output_path)
      state.set_current_connection(conn)
    end)
  end)

  return true
end

  connection.select(function(conn)
    on_confirm(conn)
  end)
end

local function resolve_last_connection()
  local conn = state.get_last_connection()
  if conn and trim(conn.dsn) ~= "" then
    return conn
  end

  local alias = state.get_last_connection_alias()
  if alias then
    return connection.load(alias)
  end

  return nil
end

local function run_with_last_connection(payload)
  local conn = resolve_last_connection()
  if not conn then
    notify("nenhuma ultima conexao disponivel", vim.log.levels.WARN)
    return
  end
  execute_payload(conn, payload)
end

local function default_export_path(source_name, ext)
  local base = source_name:gsub(":selection$", "")
  local dir = vim.fn.fnamemodify(base, ":p:h")
  local stem = vim.fn.fnamemodify(base, ":t:r")
  if stem == "" then
    stem = "query"
  end
  local suffix = source_name:match(":selection$") and "_selection" or ""
  return string.format("%s/%s%s.%s", dir, stem, suffix, ext)
end

local function choose_export_path(source_name, ext, on_confirm)
  local default_path = default_export_path(source_name, ext)
  local dir = vim.fn.fnamemodify(default_path, ":h")
  local stem = vim.fn.fnamemodify(default_path, ":t:r")
  local timestamped = string.format("%s/%s_%s.%s", dir, stem, os.date("%Y%m%d_%H%M%S"), ext)
  local items = {
    { label = "Salvar ao lado do SQL", path = default_path },
    { label = "Salvar com timestamp", path = timestamped },
    { label = "Informar caminho manualmente", kind = "custom", path = default_path },
  }

  picker.select(items, {
    prompt = "Escolha o destino do arquivo",
    format_item = function(item)
      return string.format("%s -> %s", item.label, item.path)
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.kind == "custom" then
      picker.input({ prompt = "Salvar em: ", default = choice.path }, function(value)
        on_confirm(vim.fn.fnamemodify(value, ":p"))
      end)
      return
    end
    on_confirm(vim.fn.fnamemodify(choice.path, ":p"))
  end)
end

local function export_csv(conn, payload, output_path)
  -- Phase 4: Use RPC for CSV export
  if not conn or not conn.rpc_id then
    notify("conexao nao aberta", vim.log.levels.ERROR)
    return
  end

  local parent = vim.fn.fnamemodify(output_path, ":h")
  fs.ensure_dir(parent)
  
  local loading = loading_panel("Gerando CSV em " .. vim.fn.fnamemodify(output_path, ":t"))
  
  rpc.export_csv(conn.rpc_id, payload.sql_text, output_path, function(result, err)
    vim.schedule(function()
      close_loading_panel(loading)
      if err then
        notify("Erro ao exportar CSV: " .. err, vim.log.levels.ERROR)
        return
      end
      state.set_current_connection(conn)
      notify("CSV exportado para " .. output_path)
      open_result_file(output_path, "csv")
    end)
  end)
end


local function export_xlsx(conn, payload, output_path)
  -- Phase 4: Use RPC for direct XLSX export (no CSV intermediary)
  if not conn or not conn.rpc_id then
    notify("conexao nao aberta", vim.log.levels.ERROR)
    return
  end

  local parent = vim.fn.fnamemodify(output_path, ":h")
  fs.ensure_dir(parent)
  
  local loading = loading_panel("Gerando XLSX em " .. vim.fn.fnamemodify(output_path, ":t"))
  
  rpc.export_xlsx(conn.rpc_id, payload.sql_text, output_path, function(result, err)
    vim.schedule(function()
      close_loading_panel(loading)
      if err then
        notify("Erro ao exportar XLSX: " .. err, vim.log.levels.ERROR)
        return
      end
      state.set_current_connection(conn)
      notify("XLSX exportado para " .. output_path)
      open_result_file(output_path, "xlsx")
    end)
  end)
end


function M.run_last_connection_selection()
  local payload = get_payload(true)
  if not payload then
    return
  end
  run_with_last_connection(payload)
end

function M.history()
  local entries = state.get_history()
  if vim.tbl_isempty(entries) then
    notify("nenhum historico SQL disponivel", vim.log.levels.WARN)
    return
  end

  picker.select(entries, {
    prompt = "Historico SQL",
    format_item = function(item)
      return string.format("%s | %s | %s", item.timestamp or "sem data", item.alias or "?", item.query or "[sem query]")
    end,
  }, function(choice)
    if not choice then
      return
    end
    local conn = connection.load(choice.alias)
    if not conn then
      notify("nao foi possivel carregar a conexao do historico", vim.log.levels.ERROR)
      return
    end
    execute_payload(conn, {
      sql_file = choice.sql_file,
      sql_text = choice.sql_text,
      source_name = choice.sql_file or "historico.sql",
    })
  end)
end

function M.export_csv()
  local payload = get_payload(false)
  if not payload then
    return
  end
  choose_connection(function(conn)
    choose_export_path(payload.source_name, "csv", function(path)
      export_csv(conn, payload, path)
    end)
  end)
end

function M.export_csv_selection()
  local payload = get_payload(true)
  if not payload then
    return
  end
  choose_connection(function(conn)
    choose_export_path(payload.source_name, "csv", function(path)
      export_csv(conn, payload, path)
    end)
  end)
end

function M.export_xlsx()
  -- Phase 4: XLSX export now via RPC (no python3 needed)
  local payload = get_payload(false)
  if not payload then
    return
  end
  choose_connection(function(conn)
    choose_export_path(payload.source_name, "xlsx", function(path)
      export_xlsx(conn, payload, path)
    end)
  end)
end

function M.export_xlsx_selection()
  -- Phase 4: XLSX export now via RPC (no python3 needed)
  local payload = get_payload(true)
  if not payload then
    return
  end
  choose_connection(function(conn)
    choose_export_path(payload.source_name, "xlsx", function(path)
      export_xlsx(conn, payload, path)
    end)
  end)
end

function M.capture_visual_menu()
  local payload = capture_visual_payload()
  if not payload then
    notify("selecione um trecho SQL em modo visual", vim.log.levels.WARN)
    return
  end
  state.set_visual_payload(payload)
  M.menu_selection()
end

function M.capture_visual_run_last_connection()
  local payload = capture_visual_payload()
  if not payload then
    notify("selecione um trecho SQL em modo visual", vim.log.levels.WARN)
    return
  end
  state.set_visual_payload(payload)
  M.run_last_connection_selection()
end

function M.capture_visual_export_csv()
  local payload = capture_visual_payload()
  if not payload then
    notify("selecione um trecho SQL em modo visual", vim.log.levels.WARN)
    return
  end
  state.set_visual_payload(payload)
  M.export_csv_selection()
end

function M.capture_visual_export_xlsx()
  local payload = capture_visual_payload()
  if not payload then
    notify("selecione um trecho SQL em modo visual", vim.log.levels.WARN)
    return
  end
  state.set_visual_payload(payload)
  M.export_xlsx_selection()
end

return M
