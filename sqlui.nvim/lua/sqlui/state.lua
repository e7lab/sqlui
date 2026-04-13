local fs = require("sqlui.util.fs")

local state_file = fs.data_path("state.json")

local M = {
  config = nil,
  current_connection = nil,
  last_connection = nil,
  history = {},
  schema_cache = {},
  visual_payload = nil,
}

local function persisted_defaults()
  return {
    aliases = {},
    history = {},
    last_connection_alias = nil,
    connections_meta = {},
  }
end

local function load_persisted()
  local data = fs.read_json(state_file)
  if not data then
    return persisted_defaults()
  end

  if type(data.aliases) ~= "table" then
    data.aliases = {}
  end
  if type(data.history) ~= "table" then
    data.history = {}
  end
  if type(data.connections_meta) ~= "table" then
    data.connections_meta = {}
  end

  return data
end

local function save_persisted(data)
  fs.write_json(state_file, data)
end

function M.set_config(config)
  M.config = config
end

function M.get_config()
  return M.config
end

function M.set_current_connection(connection)
  M.current_connection = connection
  M.last_connection = connection

  local data = load_persisted()
  data.last_connection_alias = connection and connection.alias or nil
  data.last_connection_schema = connection and connection.schema or nil
  save_persisted(data)
end

function M.get_current_connection()
  return M.current_connection
end

function M.get_last_connection()
  return M.last_connection
end

function M.get_last_connection_alias()
  local data = load_persisted()
  return data.last_connection_alias
end

function M.get_last_connection_schema()
  local data = load_persisted()
  return data.last_connection_schema
end

function M.list_aliases()
  local data = load_persisted()
  local aliases = vim.deepcopy(data.aliases)
  table.sort(aliases)
  return aliases
end

function M.save_alias(alias)
  local data = load_persisted()
  for _, existing in ipairs(data.aliases) do
    if existing == alias then
      save_persisted(data)
      return
    end
  end

  table.insert(data.aliases, alias)
  table.sort(data.aliases)
  save_persisted(data)
end

function M.delete_alias(alias)
  local data = load_persisted()
  local next_aliases = {}
  for _, existing in ipairs(data.aliases) do
    if existing ~= alias then
      table.insert(next_aliases, existing)
    end
  end
  data.aliases = next_aliases
  if data.last_connection_alias == alias then
    data.last_connection_alias = nil
  end
  data.connections_meta[alias] = nil
  save_persisted(data)
end

function M.rename_alias(old_alias, new_alias)
  local data = load_persisted()
  for i, existing in ipairs(data.aliases) do
    if existing == old_alias then
      data.aliases[i] = new_alias
    end
  end
  table.sort(data.aliases)
  if data.last_connection_alias == old_alias then
    data.last_connection_alias = new_alias
  end
  if data.connections_meta[old_alias] then
    data.connections_meta[new_alias] = data.connections_meta[old_alias]
    data.connections_meta[old_alias] = nil
  end
  save_persisted(data)
end

function M.add_history(entry, limit)
  local data = load_persisted()
  table.insert(data.history, 1, entry)
  while #data.history > (limit or 20) do
    table.remove(data.history)
  end
  save_persisted(data)
  M.history = data.history
end

function M.get_history()
  local data = load_persisted()
  M.history = data.history
  return vim.deepcopy(data.history)
end

function M.set_visual_payload(payload)
  M.visual_payload = payload
end

function M.consume_visual_payload()
  local payload = M.visual_payload and vim.deepcopy(M.visual_payload) or nil
  M.visual_payload = nil
  return payload
end

--- Retrieve metadata for a named connection (e.g., runner choice).
--- @param alias string
--- @return table metadata (empty table if not found)
function M.get_connection_meta(alias)
  local data = load_persisted()
  return vim.deepcopy(data.connections_meta[alias] or {})
end

--- Store metadata for a named connection.
--- @param alias string
--- @param meta table
function M.set_connection_meta(alias, meta)
  local data = load_persisted()
  data.connections_meta[alias] = vim.deepcopy(meta or {})
  save_persisted(data)
end

function M.reset_runtime()
  M.current_connection = nil
  M.last_connection = nil
  M.history = {}
  M.schema_cache = {}
  M.visual_payload = nil
end

return M
