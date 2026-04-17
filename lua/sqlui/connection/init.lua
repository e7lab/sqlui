local secrets = require("sqlui.secrets")
local state = require("sqlui.state")
local picker = require("sqlui.ui.picker")
local rpc = require("sqlui.rpc")

local M = {}

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

-- usql_bin() removed — now using RPC sidecar (easysql)

-- Helper to extract first non-nil value from row keys
-- RPC responses are now strongly typed, so this is simpler
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

--- Detect database driver from DSN scheme.
--- @param dsn string
--- @return string driver one of "mssql", "postgres", "mysql", "sqlite", or "unknown"
local function detect_driver(dsn)
  local scheme = (dsn or ""):match("^([%w]+)://")
  if not scheme then
    -- sqlite3:/path/to/db also valid (single slash)
    if (dsn or ""):match("^sqlite") then
      return "sqlite"
    end
    return "unknown"
  end
  scheme = scheme:lower()
  if scheme == "mssql" or scheme == "sqlserver" then
    return "mssql"
  end
  if scheme == "postgres" or scheme == "postgresql" or scheme == "pg" then
    return "postgres"
  end
  if scheme == "mysql" or scheme == "mariadb" then
    return "mysql"
  end
  if scheme == "sqlite3" or scheme == "sqlite" or scheme == "file" then
    return "sqlite"
  end
  return "unknown"
end

-- Schema queries removed — now delegated to easysql RPC server (Go)
-- RPC method: schema.listSchemas(connection_id)

--- Fetch schemas from the database using RPC.
--- Now async: requires a callback(schemas, error)
--- @param conn_id string RPC connection ID (assigned by easysql on connection.open)
--- @param callback fun(schemas: table|nil, error: string|nil)
local function fetch_schemas_async(conn_id, callback)
  rpc.list_schemas(conn_id, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    if not result or not result.schemas then
      callback({}, nil)
      return
    end

    local items = {}
    for _, schema in ipairs(result.schemas) do
      table.insert(items, {
        name = schema.name or "<schema>",
        tables_count = tonumber(schema.tables_count or 0) or 0,
        views_count = tonumber(schema.views_count or 0) or 0,
        functions_count = tonumber(schema.functions_count or 0) or 0,
        procedures_count = tonumber(schema.procedures_count or 0) or 0,
      })
    end

    callback(items, nil)
  end)
end

--- Filter out empty system schemas, keep only those with objects.
local function relevant_schemas(schemas)
  local relevant = {}
  for _, s in ipairs(schemas or {}) do
    local total = (s.tables_count or 0) + (s.views_count or 0) + (s.functions_count or 0) + (s.procedures_count or 0)
    if total > 0 then
      table.insert(relevant, s)
    end
  end
  return relevant
end

local function set_active_connection(conn)
  state.set_current_connection(conn)

  local config = state.get_config() or {}
  local lsp_opts = config.sqls or {}
  if lsp_opts.enabled then
    local ok, lsp = pcall(require, "sqlui.lsp")
    if ok and type(lsp.sync_connection) == "function" then
      lsp.sync_connection(conn)
    end
  end
end

--- After a connection is selected, prompt schema selection.
--- If only 1 relevant schema exists, auto-select it.
--- If no relevant schemas or usql fails, skip silently (set schema = nil).
--- For SQLite, always auto-select "main" (single implicit schema).
--- Open a connection via RPC, then proceed to schema selection.
--- @param conn table {alias, dsn, ...}
--- @param on_done fun(conn: table) callback after connection and schema are ready
local function open_connection_and_select_schema(conn, on_done)
  -- Generate a unique connection ID for this session
  local conn_uuid = vim.fn.system("uuidgen"):gsub("\n", "")
  if conn_uuid == "" then
    conn_uuid = tostring(os.time()) .. tostring(math.random())
  end

  rpc.connect(conn_uuid, conn.dsn, function(result, err)
    if err then
      notify("falha ao abrir conexao: " .. err, vim.log.levels.ERROR)
      if on_done then
        on_done(conn)
      end
      return
    end

    -- Store RPC metadata in connection
    conn.rpc_id = result.id or conn_uuid
    conn.driver = result.driver or detect_driver(conn.dsn)

    -- Now proceed to schema selection with the opened connection
    prompt_schema_selection_with_rpc(conn, on_done)
  end)
end

--- After a connection is opened via RPC, prompt schema selection asynchronously.
--- Uses the stored rpc_id to fetch schemas.
--- @param conn table {alias, dsn, rpc_id, driver, ...}
--- @param on_done fun(conn: table) callback
local function prompt_schema_selection_with_rpc(conn, on_done)
  if conn.driver == "sqlite" then
    conn.schema = "main"
    set_active_connection(conn)
    notify("sqlui conectado em '" .. conn.alias .. "/main'")
    if on_done then
      on_done(conn)
    end
    return
  end

  fetch_schemas_async(conn.rpc_id, function(schemas, err)
    if not schemas then
      notify("schemas nao carregados: " .. (err or "erro desconhecido"), vim.log.levels.WARN)
      if on_done then
        on_done(conn)
      end
      return
    end

    local filtered = relevant_schemas(schemas)

    -- No relevant schemas: skip
    if #filtered == 0 then
      if on_done then
        on_done(conn)
      end
      return
    end

    -- Single relevant schema: auto-select
    if #filtered == 1 then
      conn.schema = filtered[1].name
      set_active_connection(conn)
      notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
      if on_done then
        on_done(conn)
      end
      return
    end

    -- Multiple schemas: present picker
    local has_telescope, tel_pickers = pcall(require, "telescope.pickers")
    if has_telescope then
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      tel_pickers
        .new(require("telescope.themes").get_dropdown({
          prompt_title = string.format("Schema (%s)", conn.alias),
          layout_config = { width = 0.5, height = 0.4 },
        }), {
          finder = finders.new_table({
            results = filtered,
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
                ordinal = item.name,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry and entry.item then
                conn.schema = entry.item.name
                set_active_connection(conn)
                notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
                if on_done then
                  vim.schedule(function()
                    on_done(conn)
                  end)
                end
              end
            end)
            return true
          end,
        })
        :find()
    else
      -- Native fallback
      picker.select(filtered, {
        prompt = string.format("Schema (%s)", conn.alias),
        format_item = function(item)
          return string.format(
            "%s  T:%d V:%d F:%d P:%d",
            item.name,
            item.tables_count or 0,
            item.views_count or 0,
            item.functions_count or 0,
            item.procedures_count or 0
          )
        end,
      }, function(choice)
        if choice then
          conn.schema = choice.name
          set_active_connection(conn)
          notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
        end
        if on_done then
          on_done(conn)
        end
      end)
    end
  end)
end    return
  end

  local schemas, err = fetch_schemas(conn.dsn)
  if not schemas then
    notify("schemas nao carregados: " .. (err or "erro desconhecido"), vim.log.levels.WARN)
    if on_done then
      on_done(conn)
    end
    return
  end

  local filtered = relevant_schemas(schemas)

  -- No relevant schemas: skip
  if #filtered == 0 then
    if on_done then
      on_done(conn)
    end
    return
  end

  -- Single relevant schema: auto-select
  if #filtered == 1 then
    conn.schema = filtered[1].name
    set_active_connection(conn)
    notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
    if on_done then
      on_done(conn)
    end
    return
  end

  -- Multiple schemas: present picker
  local has_telescope, tel_pickers = pcall(require, "telescope.pickers")
  if has_telescope then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    tel_pickers
      .new(require("telescope.themes").get_dropdown({
        prompt_title = string.format("Schema (%s)", conn.alias),
        layout_config = { width = 0.5, height = 0.4 },
      }), {
        finder = finders.new_table({
          results = filtered,
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
              ordinal = item.name,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry and entry.item then
              conn.schema = entry.item.name
              set_active_connection(conn)
              notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
              if on_done then
                vim.schedule(function()
                  on_done(conn)
                end)
              end
            end
          end)
          return true
        end,
      })
      :find()
  else
    -- Native fallback
    picker.select(filtered, {
      prompt = string.format("Schema (%s)", conn.alias),
      format_item = function(item)
        return string.format(
          "%s  T:%d V:%d F:%d P:%d",
          item.name,
          item.tables_count or 0,
          item.views_count or 0,
          item.functions_count or 0,
          item.procedures_count or 0
        )
      end,
    }, function(choice)
      if choice then
        conn.schema = choice.name
        set_active_connection(conn)
        notify("sqlui conectado em '" .. conn.alias .. "/" .. conn.schema .. "'")
      end
      if on_done then
        on_done(conn)
      end
    end)
  end
end

--- Expose driver detection for other modules.
M.detect_driver = detect_driver

function M.backend()
  local config = state.get_config() or {}
  local opts = config.secrets or {}
  return secrets.resolve(opts.backend)
end

function M.list()
  return state.list_aliases()
end

function M.load(alias)
  local secret = M.backend().get(alias)
  if not secret or trim(secret) == "" then
    return nil
  end
  return {
    alias = alias,
    dsn = secret,
  }
end

-- Runner selection removed (Phase 2)
-- With easysql RPC, all connections use the same backend (no usql/sqlcmd choice)

function M.save(alias, dsn)
  local clean_alias = trim(alias)
  local clean_dsn = trim(dsn)
  if clean_alias == "" or clean_dsn == "" then
    return false, "alias e DSN nao podem ficar vazios"
  end

  if not M.backend().set(clean_alias, clean_dsn) then
    return false, "nao foi possivel salvar a conexao"
  end

  state.save_alias(clean_alias)
  return true, nil
end

function M.delete(alias)
  local ok = M.backend().delete(alias)
  if not ok then
    return false, "o backend atual nao suporta remocao segura automatica"
  end
  state.delete_alias(alias)
  return true, nil
end

function M.rename(old_alias, new_alias)
  local conn = M.load(old_alias)
  if not conn then
    return false, "conexao original nao encontrada"
  end

  local save_ok, save_err = M.save(new_alias, conn.dsn)
  if not save_ok then
    return false, save_err
  end

  local delete_ok = M.backend().delete(old_alias)
  if delete_ok then
    state.rename_alias(old_alias, new_alias)
  else
    state.delete_alias(old_alias)
    state.save_alias(new_alias)
  end

  return true, nil
end

function M.select_existing(on_confirm)
  local aliases = M.list()
  if vim.tbl_isempty(aliases) then
    notify("nenhuma conexao salva", vim.log.levels.WARN)
    return
  end

  picker.select(aliases, {
    prompt = "Conexao SQL",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then
      return
    end

    local conn = M.load(choice)
    if not conn then
      notify("nao foi possivel carregar a conexao '" .. choice .. "'", vim.log.levels.ERROR)
      return
    end

    open_connection_and_select_schema(conn, function(resolved)
      if on_confirm then
        on_confirm(resolved)
      end
    end)
  end)
end

-- prompt_runner_for_mssql removed (Phase 2)
-- No runner selection needed with easysql RPC

local function prompt_new_connection(on_confirm)
  picker.input({ prompt = "Apelido da conexao: " }, function(alias)
    local clean_alias = trim(alias)
    if clean_alias == "" then
      return
    end

    picker.input({ prompt = "DSN/URL do banco: " }, function(dsn)
      local ok, err = M.save(clean_alias, dsn)
      if not ok then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local conn = { alias = clean_alias, dsn = trim(dsn) }
      open_connection_and_select_schema(conn, function(resolved)
        if on_confirm then
          on_confirm(resolved)
        end
      end)
    end)
  end)
end

--- Validate and canonicalize a local file path for SQLite DSN.
--- Rejects non-existent files and returns only canonical absolute paths.
--- @param raw_path string
--- @return string|nil canonical_path
--- @return string|nil error
local function validate_sqlite_path(raw_path)
  if not raw_path or trim(raw_path) == "" then
    return nil, "caminho vazio"
  end
  local expanded = vim.fn.expand(raw_path)
  local canonical = vim.fn.resolve(expanded)
  if vim.fn.filereadable(canonical) ~= 1 then
    return nil, "arquivo nao encontrado"
  end
  return canonical, nil
end

--- Build a safe SQLite DSN from a canonical absolute path.
--- @param canonical_path string Must be an absolute, canonicalized path
--- @return string dsn
local function build_sqlite_dsn(canonical_path)
  return "sqlite3://" .. canonical_path
end

--- Save a validated SQLite connection and proceed to schema selection.
local function save_sqlite_and_connect(filepath, on_confirm)
  local canonical, path_err = validate_sqlite_path(filepath)
  if not canonical then
    notify(path_err, vim.log.levels.ERROR)
    return
  end
  picker.input({ prompt = "Apelido da conexao: ", default = vim.fn.fnamemodify(canonical, ":t:r") }, function(alias)
    alias = trim(alias)
    if alias == "" then
      return
    end
    local dsn = build_sqlite_dsn(canonical)
    local ok, err = M.save(alias, dsn)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local conn = { alias = alias, dsn = dsn }
    open_connection_and_select_schema(conn, on_confirm)
  end)
end

local function prompt_sqlite_connection(on_confirm)
  local has_telescope, tel_pickers = pcall(require, "telescope.pickers")
  if has_telescope then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local has_async, async_scan = pcall(require, "plenary.async")
    local scan = require("plenary.scandir")

    -- Workspace-scoped only: scan cwd with capped depth, off main thread
    local cwd = vim.fn.getcwd()
    notify("buscando arquivos .db em " .. vim.fn.fnamemodify(cwd, ":~") .. "...")

    local function show_picker_or_fallback(db_files)
      -- Deduplicate via canonical paths
      local seen = {}
      local unique = {}
      for _, f in ipairs(db_files) do
        local canonical = vim.fn.resolve(f)
        if not seen[canonical] then
          seen[canonical] = true
          table.insert(unique, canonical)
        end
      end

      if #unique == 0 then
        picker.input({ prompt = "Caminho do arquivo .db: " }, function(path)
          path = trim(path)
          if path == "" then
            return
          end
          save_sqlite_and_connect(path, on_confirm)
        end)
        return
      end

      tel_pickers
        .new(require("telescope.themes").get_dropdown({
          prompt_title = "Selecionar arquivo SQLite (.db)",
          layout_config = { width = 0.7, height = 0.5 },
        }), {
          finder = finders.new_table({
            results = unique,
            entry_maker = function(filepath)
              local rel = vim.fn.fnamemodify(filepath, ":~:.")
              return {
                value = filepath,
                display = rel,
                ordinal = filepath,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if not entry then
                return
              end
              vim.schedule(function()
                save_sqlite_and_connect(entry.value, on_confirm)
              end)
            end)
            return true
          end,
        })
        :find()
    end

    -- Run scan in a separate coroutine via plenary.async if available,
    -- otherwise fallback to vim.schedule (deferred but still main thread)
    if has_async and async_scan then
      local ok_wrap = pcall(function()
        async_scan.run(function()
          local db_files = scan.scan_dir(cwd, {
            search_pattern = "%.db$",
            hidden = false,
            depth = 5,
            silent = true,
          }) or {}
          vim.schedule(function()
            show_picker_or_fallback(db_files)
          end)
        end)
      end)
      if not ok_wrap then
        -- plenary.async not usable, fallback
        vim.schedule(function()
          local db_files = scan.scan_dir(cwd, {
            search_pattern = "%.db$",
            hidden = false,
            depth = 5,
            silent = true,
          }) or {}
          show_picker_or_fallback(db_files)
        end)
      end
    else
      vim.schedule(function()
        local db_files = scan.scan_dir(cwd, {
          search_pattern = "%.db$",
          hidden = false,
          depth = 5,
          silent = true,
        }) or {}
        show_picker_or_fallback(db_files)
      end)
    end
  else
    -- Native fallback: prompt for file path
    picker.input({ prompt = "Caminho do arquivo .db: " }, function(path)
      path = trim(path)
      if path == "" then
        return
      end
      save_sqlite_and_connect(path, on_confirm)
    end)
  end
end

local function prompt_temporary_connection(on_confirm)
  picker.input({ prompt = "DSN/URL temporaria: " }, function(dsn)
    local conn = { alias = "temporaria", dsn = trim(dsn) }
    if conn.dsn == "" then
      return
    end
    open_connection_and_select_schema(conn, function(resolved)
      if on_confirm then
        on_confirm(resolved)
      end
    end)
  end)
end

local function prompt_edit_connection()
  M.select_existing(function(conn)
    picker.input({ prompt = "Nova DSN para " .. conn.alias .. ": ", default = conn.dsn }, function(dsn)
      local ok, err = M.save(conn.alias, dsn)
      if not ok then
        notify(err, vim.log.levels.ERROR)
        return
      end
      local updated = { alias = conn.alias, dsn = trim(dsn) }
      open_connection_and_select_schema(updated, function()
        notify("conexao '" .. conn.alias .. "' atualizada")
      end)
    end)
  end)
end

local function prompt_rename_connection()
  M.select_existing(function(conn)
    picker.input({ prompt = "Novo alias para " .. conn.alias .. ": ", default = conn.alias }, function(new_alias)
      new_alias = trim(new_alias)
      if new_alias == "" or new_alias == conn.alias then
        return
      end
      local ok, err = M.rename(conn.alias, new_alias)
      if not ok then
        notify(err, vim.log.levels.ERROR)
        return
      end
      conn.alias = new_alias
      set_active_connection(conn)
      notify("conexao renomeada para '" .. new_alias .. "'")
    end)
  end)
end

local function prompt_duplicate_connection(on_confirm)
  M.select_existing(function(conn)
    picker.input({ prompt = "Alias da copia de " .. conn.alias .. ": ", default = conn.alias .. "_copy" }, function(new_alias)
      new_alias = trim(new_alias)
      if new_alias == "" then
        return
      end
      if new_alias == conn.alias then
        notify("alias deve ser diferente do original", vim.log.levels.WARN)
        return
      end
      local ok, err = M.save(new_alias, conn.dsn)
      if not ok then
        notify(err, vim.log.levels.ERROR)
        return
      end
      local dup = { alias = new_alias, dsn = conn.dsn }
      open_connection_and_select_schema(dup, function(resolved)
        notify("conexao '" .. conn.alias .. "' duplicada como '" .. new_alias .. "'")
        if on_confirm then
          on_confirm(resolved)
        end
      end)
    end)
  end)
end

local function prompt_delete_connection()
  M.select_existing(function(conn)
    local ok, err = M.delete(conn.alias)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify("conexao '" .. conn.alias .. "' removida")
  end)
end

function M.select(on_confirm)
  local items = {}
  for _, alias in ipairs(M.list()) do
    table.insert(items, { label = alias, kind = "saved", alias = alias })
  end
  table.insert(items, { label = "+ Nova conexao salva", kind = "new" })
  table.insert(items, { label = "+ Conexao SQLite", kind = "sqlite" })
  table.insert(items, { label = "+ Editar conexao salva", kind = "edit" })
  table.insert(items, { label = "+ Renomear conexao salva", kind = "rename" })
  table.insert(items, { label = "+ Duplicar conexao salva", kind = "duplicate" })
  table.insert(items, { label = "+ Remover conexao salva", kind = "delete" })
  table.insert(items, { label = "+ Conexao temporaria", kind = "temp" })

  picker.select(items, {
    prompt = "Conexao SQL",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice.kind == "saved" then
      local conn = M.load(choice.alias)
      if not conn then
        notify("nao foi possivel carregar a conexao '" .. choice.alias .. "'", vim.log.levels.ERROR)
        return
      end
      open_connection_and_select_schema(conn, function(resolved)
        if on_confirm then
          on_confirm(resolved)
        end
      end)
      return
    end

    if choice.kind == "new" then
      prompt_new_connection(on_confirm)
      return
    end
    if choice.kind == "sqlite" then
      prompt_sqlite_connection(on_confirm)
      return
    end
    if choice.kind == "edit" then
      prompt_edit_connection()
      return
    end
    if choice.kind == "rename" then
      prompt_rename_connection()
      return
    end
    if choice.kind == "duplicate" then
      prompt_duplicate_connection(on_confirm)
      return
    end
    if choice.kind == "delete" then
      prompt_delete_connection()
      return
    end

    prompt_temporary_connection(on_confirm)
  end)
end

return M
