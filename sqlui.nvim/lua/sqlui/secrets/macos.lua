local M = {}

local service_name = "sqlui.nvim"

local function run(args)
  local result = vim.system(args, { text = true }):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

function M.available()
  return vim.fn.executable("security") == 1
end

function M.name()
  return "macos-keychain"
end

function M.get(alias)
  local ok, out = run({
    "security",
    "find-generic-password",
    "-a",
    alias,
    "-s",
    service_name,
    "-w",
  })
  return ok and out or nil
end

function M.set(alias, secret)
  local ok = run({
    "security",
    "add-generic-password",
    "-a",
    alias,
    "-s",
    service_name,
    "-w",
    secret,
    "-U",
  })
  return ok
end

function M.delete(alias)
  local ok, _, err = run({
    "security",
    "delete-generic-password",
    "-a",
    alias,
    "-s",
    service_name,
  })
  return ok or err:match("could not be found") ~= nil
end

return M
