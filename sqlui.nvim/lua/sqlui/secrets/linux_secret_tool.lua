local M = {}

local service_name = "sqlui.nvim"

local function run(args, stdin)
  local opts = { text = true }
  if stdin then
    opts.stdin = stdin
  end
  local result = vim.system(args, opts):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

function M.available()
  return vim.fn.executable("secret-tool") == 1
end

function M.name()
  return "linux-secret-tool"
end

function M.get(alias)
  local ok, out = run({ "secret-tool", "lookup", "service", service_name, "alias", alias })
  return ok and out or nil
end

function M.set(alias, secret)
  local ok = run({ "secret-tool", "store", "--label=sqlui.nvim", "service", service_name, "alias", alias }, secret)
  return ok
end

function M.delete(_alias)
  return false
end

return M
