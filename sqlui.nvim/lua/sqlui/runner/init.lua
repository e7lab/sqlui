local connection = require("sqlui.connection")
local picker = require("sqlui.ui.picker")
local state = require("sqlui.state")
local fs = require("sqlui.util.fs")

local M = {}

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

local function sqlcmd_bin()
  local config = state.get_config() or {}
  return ((config.sqlcmd or {}).bin) or "sqlcmd"
end

local function history_limit()
  local config = state.get_config() or {}
  return ((config.history or {}).limit) or 20
end

local function ensure_dependency(bin, help)
  if vim.fn.executable(bin) == 1 then
    return true
  end
  notify(help or (bin .. " nao encontrado no PATH"), vim.log.levels.ERROR)
  return false
end

--- Parse a sqlserver:// or mssql:// DSN into its components.
--- Handles optional port and strips query-string parameters.
--- Returns nil when mandatory fields (host, db) cannot be extracted.
--- @param dsn string
--- @return table|nil  { host, port, db, user, pass, trusted }
local function parse_mssql_dsn(dsn)
  local rest = dsn:match("^%a[%w+%-%.]*://(.+)$")
  if not rest then
    return nil
  end

  local lower_rest = rest:lower()
  local trusted = lower_rest:find("trusted_connection=yes")
    or lower_rest:find("integrated%%20security=sspi")
    or lower_rest:find("integrated security=sspi")

  -- Strip query string before parsing structural parts
  local without_qs = rest:match("^([^?]+)") or rest

  -- user:pass@host:port/db
  local user, pass, host, port, db =
    without_qs:match("^([^:@]+):([^@]*)@([^:/]+):(%d+)/(.+)$")
  -- user:pass@host/db
  if not user then
    user, pass, host, db =
      without_qs:match("^([^:@]+):([^@]*)@([^/]+)/(.+)$")
  end
  -- host:port/db  (Windows Auth — no credentials in DSN)
  if not host then
    host, port, db = without_qs:match("^([^:/]+):(%d+)/(.+)$")
  end
  -- host/db
  if not host then
    host, db = without_qs:match("^([^/]+)/(.+)$")
  end

  if not host or not db then
    return nil
  end

  return {
    host    = host,
    port    = (port and port ~= "") and port or "1433",
    db      = db,
    user    = user,
    pass    = pass,
    trusted = trusted and true or false,
  }
end

--- Execute a SQL file via sqlcmd and write stdout to output_path.
--- Returns (ok: bool, raw_result: table) mirroring vim.system shape.
--- @param conn table   connection object (needs .dsn)
--- @param input_file string
--- @param output_path string
--- @return boolean, table
local function execute_with_sqlcmd(conn, input_file, output_path)
  if not ensure_dependency(sqlcmd_bin(), "sqlcmd nao encontrado. Instale via: brew install sqlcmd") then
    return false, { code = 1, stdout = "", stderr = "sqlcmd nao encontrado no PATH" }
  end

  local p = parse_mssql_dsn(conn.dsn)
  if not p then
    -- Do NOT include DSN in messages; credentials live in the DSN.
    -- Sanitize alias: strip control chars before logging.
    local safe_alias = tostring(conn.alias or "?"):gsub("[%c]", "")
    local err = "nao foi possivel parsear a DSN MSSQL para sqlcmd (alias: " .. safe_alias .. ")"
    notify(err, vim.log.levels.ERROR)
    return false, { code = 1, stdout = "", stderr = err }
  end

  -- sqlcmd server string: host  or  host,port
  local server = p.port ~= "1433" and (p.host .. "," .. p.port) or p.host

  local args = {
    sqlcmd_bin(),
    "-S", server,
    "-d", p.db,
    "-i", input_file,
    "-o", output_path,
    "-s", "|",  -- column separator (pipe)
    "-W",       -- strip trailing whitespace from columns
    "-b",       -- exit with non-zero code on SQL error
  }

  if p.trusted then
    table.insert(args, "-E")
  else
    if p.user and p.user ~= "" then
      vim.list_extend(args, { "-U", p.user })
    end
    -- Pass password via env var to avoid argv exposure in process list.
    -- sqlcmd reads SQLCMDPASSWORD automatically; we never pass -P.
  end

  local env = {}
  if not p.trusted and p.pass and p.pass ~= "" then
    env.SQLCMDPASSWORD = p.pass
  end

  local result = vim.system(args, { text = true, env = env }):wait()
  return result.code == 0, result
end

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

--- Allowed runner identifiers. Any unrecognised value falls back to "usql".
local ALLOWED_RUNNERS = { usql = true, sqlcmd = true }

--- Resolve the effective runner for a connection (allowlist, fail-closed).
--- Reads from conn.runner first (set at load time from persisted meta),
--- then falls back to "usql" for any unknown or empty value.
--- @param conn table
--- @return string  "usql" | "sqlcmd"
local function resolve_runner(conn)
  local r = trim(conn.runner or ""):lower()
  return ALLOWED_RUNNERS[r] and r or "usql"
end

--- Core execution: dispatches to usql or sqlcmd based on connection runner.
---
--- DESIGN DECISIONS (aprovadas pelo mantenedor):
---   1. output_path: o arquivo temporário de resultado é mantido em disco
---      intencionalmente — ele é aberto como buffer read-only no Neovim para
---      exibir os resultados ao usuário. O arquivo reside no diretório temp
---      do OS (de propriedade do usuário atual) e é removido no reboot.
---      Não registramos BufWipeout para deletá-lo; documentamos a semântica.
---   2. vim.system():wait() síncrono: a execução bloqueia o loop principal
---      do Neovim durante a query. Isso é consistente com todas as outras
---      chamadas usql no arquivo e mantém o fluxo simples e previsível.
---      Queries longas bloquearão o editor temporariamente — comportamento
---      esperado e aceito.
---
--- temp_input é limpo em todos os caminhos via cleanup_temp().
--- @param conn table
--- @param payload table
--- @return boolean
local function execute_payload(conn, payload)
  local output_path = fs.tempname(".txt")

  -- Para seleções visuais, materializa o SQL em arquivo temporário.
  -- Ambos os runners aceitam caminho de arquivo; mantém o dispatch uniforme.
  local input_file = payload.sql_file
  local temp_input = nil

  -- Guaranteed cleanup helper — called on every exit path.
  local function cleanup_temp()
    if temp_input then
      pcall(fs.delete, temp_input)
      temp_input = nil
    end
  end

  if payload.sql_text and payload.source_name and payload.source_name:match(":selection$") then
    temp_input = fs.tempname(".sql")
    local write_ok = pcall(vim.fn.writefile, vim.split(payload.sql_text, "\n", { plain = true }), temp_input)
    if not write_ok then
      cleanup_temp()
      notify("nao foi possivel escrever o arquivo SQL temporario", vim.log.levels.ERROR)
      return false
    end
    input_file = temp_input
  end

  local runner = resolve_runner(conn)
  local result
  local ok_exec

  local dispatch_ok, dispatch_err = pcall(function()
    if runner == "sqlcmd" then
      ok_exec, result = execute_with_sqlcmd(conn, input_file, output_path)
    else
      -- usql: -f envia o arquivo diretamente; suporta múltiplos statements via GO
      -- em drivers que o processam (postgres, mysql). Para MSSQL sem sqlcmd,
      -- o usuário deve trocar o runner da conexão para "sqlcmd".
      -- NOTA: vim.system():wait() é síncrono por decisão de design aprovada —
      -- mantém o fluxo simples e consistente com as demais chamadas usql no arquivo.
      result = vim.system(
        { usql_bin(), "-f", input_file, "-o", output_path, conn.dsn },
        { text = true }
      ):wait()
      ok_exec = result.code == 0
    end
  end)

  cleanup_temp()

  if not dispatch_ok then
    notify("erro interno ao despachar consulta: " .. tostring(dispatch_err), vim.log.levels.ERROR)
    return false
  end

  local content = ""
  if fs.file_exists(output_path) then
    content = table.concat(vim.fn.readfile(output_path), "\n")
  end

  if not ok_exec then
    local err = trim(result.stderr or "")
    if err == "" then
      err = trim(result.stdout or "")
    end
    if err ~= "" then
      content = err
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), output_path)
    end
    open_result_file(output_path, "txt")
    notify("consulta executada com erro", vim.log.levels.ERROR)
    push_history(conn, payload, output_path)
    state.set_current_connection(conn)
    return false
  end

  if trim(content) == "" then
    content = table.concat({
      "Sem saida retornada pelo " .. runner .. ".",
      "",
      "Arquivo: " .. payload.source_name,
      "Conexao: " .. conn.alias,
      "Runner:  " .. runner,
      "Exit code: " .. tostring(result.code),
    }, "\n")
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), output_path)
  end

  open_result_file(output_path, "txt")
  push_history(conn, payload, output_path)
  state.set_current_connection(conn)
  return true
end

local function choose_connection(on_confirm)
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
  local parent = vim.fn.fnamemodify(output_path, ":h")
  fs.ensure_dir(parent)
  local loading = loading_panel("Gerando CSV em " .. vim.fn.fnamemodify(output_path, ":t"))
  vim.schedule(function()
    vim.defer_fn(function()
      vim.system({ usql_bin(), "-C", "-A", "-q", "-c", payload.sql_text, "-o", output_path, conn.dsn }, { text = true }, function(result)
        vim.schedule(function()
          close_loading_panel(loading)
          if result.code ~= 0 then
            local err = trim(result.stderr)
            if err == "" then
              err = trim(result.stdout)
            end
            notify(err ~= "" and err or "falha ao exportar CSV", vim.log.levels.ERROR)
            return
          end
          state.set_current_connection(conn)
          notify("CSV exportado para " .. output_path)
          open_result_file(output_path, "csv")
        end)
      end)
    end, 30)
  end)
end

local function csv_to_xlsx(csv_path, xlsx_path)
  local py = [[
import csv
import sys
import zipfile
from xml.sax.saxutils import escape

csv_path, xlsx_path = sys.argv[1], sys.argv[2]

def col_name(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s

with open(csv_path, newline='', encoding='utf-8-sig') as f:
    rows = list(csv.reader(f))

sheet_rows = []
for r_idx, row in enumerate(rows, 1):
    cells = []
    for c_idx, value in enumerate(row, 1):
        ref = f"{col_name(c_idx)}{r_idx}"
        cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{escape(value)}</t></is></c>')
    sheet_rows.append(f'<row r="{r_idx}">' + ''.join(cells) + '</row>')

sheet_xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + ''.join(sheet_rows) + '</sheetData></worksheet>'
content_types = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'
workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Query" sheetId="1" r:id="rId1"/></sheets></workbook>'
workbook_rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
core = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Query Export</dc:title><dc:creator>sqlui.nvim</dc:creator></cp:coreProperties>'
app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>sqlui.nvim</Application></Properties>'
with zipfile.ZipFile(xlsx_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    zf.writestr('[Content_Types].xml', content_types)
    zf.writestr('_rels/.rels', rels)
    zf.writestr('xl/workbook.xml', workbook)
    zf.writestr('xl/_rels/workbook.xml.rels', workbook_rels)
    zf.writestr('xl/worksheets/sheet1.xml', sheet_xml)
    zf.writestr('docProps/core.xml', core)
    zf.writestr('docProps/app.xml', app)
]]

  local result = vim.system({ "python3", "-c", py, csv_path, xlsx_path }, { text = true }):wait()
  if result.code ~= 0 then
    local err = trim(result.stderr)
    if err == "" then
      err = trim(result.stdout)
    end
    return false, err ~= "" and err or "falha ao converter CSV para XLSX"
  end
  return true, nil
end

local function export_xlsx(conn, payload, output_path)
  local parent = vim.fn.fnamemodify(output_path, ":h")
  fs.ensure_dir(parent)
  local temp_csv = fs.tempname(".csv")
  local loading = loading_panel("Gerando XLSX em " .. vim.fn.fnamemodify(output_path, ":t"))
  vim.schedule(function()
    vim.defer_fn(function()
      vim.system({ usql_bin(), "-C", "-A", "-q", "-c", payload.sql_text, "-o", temp_csv, conn.dsn }, { text = true }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            close_loading_panel(loading)
            local err = trim(result.stderr)
            if err == "" then
              err = trim(result.stdout)
            end
            fs.delete(temp_csv)
            notify(err ~= "" and err or "falha ao exportar XLSX", vim.log.levels.ERROR)
            return
          end

          local ok, err = csv_to_xlsx(temp_csv, output_path)
          fs.delete(temp_csv)
          close_loading_panel(loading)
          if not ok then
            notify(err, vim.log.levels.ERROR)
            return
          end
          state.set_current_connection(conn)
          notify("XLSX exportado para " .. output_path)
          open_result_file(output_path, "txt")
        end)
      end)
    end, 30)
  end)
end

local function show_menu(use_selection)
  local payload = get_payload(use_selection)
  if not payload then
    return
  end

  local items = {
    { label = "Executar consulta", kind = "run" },
    { label = "Executar na ultima conexao", kind = "run_last" },
    { label = "Exportar CSV", kind = "csv" },
    { label = "Exportar XLSX", kind = "xlsx" },
  }

  picker.select(items, {
    prompt = use_selection and "SQL selecao" or "SQL arquivo",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.kind == "run_last" then
      run_with_last_connection(payload)
      return
    end

    choose_connection(function(conn)
      if choice.kind == "run" then
        execute_payload(conn, payload)
        return
      end
      if choice.kind == "csv" then
        choose_export_path(payload.source_name, "csv", function(path)
          export_csv(conn, payload, path)
        end)
        return
      end
      choose_export_path(payload.source_name, "xlsx", function(path)
        export_xlsx(conn, payload, path)
      end)
    end)
  end)
end

function M.menu()
  show_menu(false)
end

function M.menu_selection()
  show_menu(true)
end

function M.run()
  local payload = get_payload(false)
  if not payload then
    return
  end
  choose_connection(function(conn)
    execute_payload(conn, payload)
  end)
end

function M.run_selection()
  local payload = get_payload(true)
  if not payload then
    return
  end
  choose_connection(function(conn)
    execute_payload(conn, payload)
  end)
end

function M.run_last_connection()
  local payload = get_payload(false)
  if not payload then
    return
  end
  run_with_last_connection(payload)
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
  if not ensure_dependency("python3", "python3 nao encontrado no PATH") then
    return
  end
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
  if not ensure_dependency("python3", "python3 nao encontrado no PATH") then
    return
  end
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
