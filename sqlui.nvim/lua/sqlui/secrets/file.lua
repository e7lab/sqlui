local M = {}

local fs = require("sqlui.util.fs")

local secrets_file = fs.data_path("secrets.json")

local function read_all()
  return fs.read_json(secrets_file) or {}
end

local function write_all(data)
  fs.write_json(secrets_file, data)
end

function M.available()
  return true
end

function M.name()
  return "file"
end

function M.get(alias)
  return read_all()[alias]
end

function M.set(alias, secret)
  local data = read_all()
  data[alias] = secret
  write_all(data)
  return true
end

function M.delete(alias)
  local data = read_all()
  data[alias] = nil
  write_all(data)
  return true
end

return M
