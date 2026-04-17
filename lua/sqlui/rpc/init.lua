-- lua/sqlui/rpc/init.lua
-- JSON-RPC 2.0 client para comunicação com easysql --rpc (sidecar)

local state = require("sqlui.state")

local M = {}

-- Estado interno do sidecar
local runtime = {
  handle = nil,           -- vim.SystemObj
  next_id = 0,            -- request ID counter
  pending = {},           -- { [id] = { callback, timer } }
  buffer = "",            -- stdout buffer parcial (linhas incompletas)
  alive = false,
  restart_count = 0,
  restart_timer = nil,
}

-- Config
local function easysql_bin()
  local config = state.get_config() or {}
  return ((config.easysql or {}).bin) or "easysql"
end

local function request_timeout_ms()
  local config = state.get_config() or {}
  return ((config.easysql or {}).request_timeout_ms) or 30000
end

local function max_restarts()
  return 5
end

-- ============================================================
-- Notify helper
-- ============================================================

local function notify(msg, level)
  local safe = tostring(msg or "sqlui/rpc: erro")
  pcall(vim.notify, safe, level or vim.log.levels.INFO, { title = "sqlui/rpc" })
end

-- ============================================================
-- Response handling
-- ============================================================

local function process_line(line)
  if line == "" then return end

  local ok, resp = pcall(vim.json.decode, line)
  if not ok or type(resp) ~= "table" then
    notify("resposta JSON invalida do sidecar", vim.log.levels.WARN)
    return
  end

  local id = resp.id
  if id == nil then return end -- notification (sem ID)

  local entry = runtime.pending[id]
  if not entry then return end -- response sem request pendente
  runtime.pending[id] = nil

  -- Cancelar timeout timer
  if entry.timer then
    pcall(vim.fn.timer_stop, entry.timer)
  end

  -- Chamar callback
  if resp.error then
    entry.callback(nil, resp.error.message or "erro RPC desconhecido")
  else
    entry.callback(resp.result, nil)
  end
end

local function on_stdout(err, data)
  if err or not data then return end

  -- Acumular dados parciais (stdout pode chegar em chunks)
  runtime.buffer = runtime.buffer .. data

  -- Processar linhas completas
  while true do
    local newline_pos = runtime.buffer:find("\n")
    if not newline_pos then break end

    local line = runtime.buffer:sub(1, newline_pos - 1)
    runtime.buffer = runtime.buffer:sub(newline_pos + 1)

    vim.schedule(function()
      process_line(line)
    end)
  end
end

local function on_stderr(err, data)
  if data and data ~= "" then
    -- Log stderr para debugging
    vim.schedule(function()
      notify("easysql stderr: " .. vim.trim(data), vim.log.levels.DEBUG)
    end)
  end
end

local function on_exit(obj)
  vim.schedule(function()
    runtime.alive = false
    runtime.handle = nil

    -- Fail todos os requests pendentes
    for id, entry in pairs(runtime.pending) do
      if entry.timer then
        pcall(vim.fn.timer_stop, entry.timer)
      end
      pcall(entry.callback, nil, "sidecar encerrou inesperadamente")
    end
    runtime.pending = {}

    -- Auto-restart
    local config = state.get_config() or {}
    local auto = ((config.easysql or {}).restart_on_crash)
    if auto ~= false and runtime.restart_count < max_restarts() then
      runtime.restart_count = runtime.restart_count + 1
      local delay = math.min(100 * (2 ^ runtime.restart_count), 5000)
      notify(string.format("easysql crashed, restarting in %dms...", delay), vim.log.levels.WARN)
      runtime.restart_timer = vim.defer_fn(function()
        M.start()
      end, delay)
    end
  end)
end

-- ============================================================
-- Lifecycle
-- ============================================================

function M.start()
  if runtime.alive and runtime.handle then
    return true
  end

  local bin = easysql_bin()
  if vim.fn.executable(bin) ~= 1 then
    notify("easysql nao encontrado no PATH: " .. bin, vim.log.levels.ERROR)
    return false
  end

  runtime.buffer = ""
  runtime.pending = {}
  runtime.next_id = 0

  runtime.handle = vim.system(
    { bin, "--rpc" },
    {
      stdin = true,
      stdout = on_stdout,
      stderr = on_stderr,
    },
    on_exit -- on_exit callback
  )

  runtime.alive = true
  runtime.restart_count = 0
  return true
end

function M.stop()
  if runtime.restart_timer then
    pcall(vim.fn.timer_stop, runtime.restart_timer)
    runtime.restart_timer = nil
  end

  if runtime.handle then
    -- Fechar stdin para sinalizar EOF ao sidecar
    pcall(function()
      runtime.handle:write(nil) -- close stdin
    end)
    -- Kill após 2s se não saiu
    vim.defer_fn(function()
      if runtime.handle then
        pcall(function() runtime.handle:kill(9) end)
      end
    end, 2000)
  end

  runtime.alive = false
end

function M.is_alive()
  return runtime.alive and runtime.handle ~= nil
end

-- ============================================================
-- Request dispatch
-- ============================================================

function M.request(method, params, callback)
  if not M.is_alive() then
    if not M.start() then
      if callback then
        callback(nil, "sidecar nao esta rodando")
      end
      return
    end
  end

  runtime.next_id = runtime.next_id + 1
  local id = runtime.next_id

  local payload = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  })

  -- Registrar callback com timeout
  local timer = vim.fn.timer_start(request_timeout_ms(), function()
    local entry = runtime.pending[id]
    if entry then
      runtime.pending[id] = nil
      pcall(entry.callback, nil, "timeout aguardando resposta do sidecar")
    end
  end)

  runtime.pending[id] = {
    callback = callback or function() end,
    timer = timer,
  }

  -- Enviar request (newline-delimited)
  runtime.handle:write(payload .. "\n")
end

--- Wrapper síncrono para compatibilidade durante migração.
--- CUIDADO: bloqueia o event loop do Neovim.
function M.request_sync(method, params, timeout_ms)
  local done = false
  local result, error_msg

  M.request(method, params, function(r, e)
    result, error_msg = r, e
    done = true
  end)

  vim.wait(timeout_ms or 30000, function() return done end, 10)

  if not done then
    return nil, "timeout (sync)"
  end

  return result, error_msg
end

-- ============================================================
-- Convenience methods
-- ============================================================

-- Connection
function M.connect(id, dsn, cb)
  M.request("connection.open", { id = id, dsn = dsn }, cb)
end

function M.disconnect(id, cb)
  M.request("connection.close", { id = id }, cb)
end

function M.connections(cb)
  M.request("connection.list", nil, cb)
end

function M.switch_database(conn_id, database, cb)
  M.request("connection.switchDatabase", {
    connection_id = conn_id,
    database = database,
  }, cb)
end

-- Query
function M.execute(conn_id, sql, cb)
  M.request("query.execute", {
    connection_id = conn_id,
    sql = sql,
  }, cb)
end

function M.cancel(conn_id, cb)
  M.request("query.cancel", { connection_id = conn_id }, cb)
end

-- Schema
function M.list_databases(conn_id, cb)
  M.request("schema.listDatabases", { connection_id = conn_id }, cb)
end

function M.list_schemas(conn_id, cb)
  M.request("schema.listSchemas", { connection_id = conn_id }, cb)
end

function M.list_objects(conn_id, params, cb)
  params.connection_id = conn_id
  M.request("schema.listObjects", params, cb)
end

function M.columns(conn_id, schema_name, object_name, cb)
  M.request("schema.columns", {
    connection_id = conn_id,
    schema_name = schema_name,
    object_name = object_name,
  }, cb)
end

function M.primary_key(conn_id, schema_name, object_name, cb)
  M.request("schema.primaryKey", {
    connection_id = conn_id,
    schema_name = schema_name,
    object_name = object_name,
  }, cb)
end

function M.routine_definition(conn_id, schema_name, routine_name, cb)
  M.request("schema.routineDefinition", {
    connection_id = conn_id,
    schema_name = schema_name,
    routine_name = routine_name,
  }, cb)
end

-- Export
function M.export_csv(conn_id, sql, output_path, cb)
  M.request("export.csv", {
    connection_id = conn_id,
    sql = sql,
    output_path = output_path,
  }, cb)
end

function M.export_xlsx(conn_id, sql, output_path, cb)
  M.request("export.xlsx", {
    connection_id = conn_id,
    sql = sql,
    output_path = output_path,
  }, cb)
end

-- Ping
function M.ping(cb)
  M.request("ping", nil, cb)
end

-- ============================================================
-- Auto-start e cleanup
-- ============================================================

-- Auto-cleanup ao sair do Neovim
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop()
  end,
})

return M
