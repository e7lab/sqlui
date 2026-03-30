local M = {}

function M.data_path(...)
  local parts = { vim.fn.stdpath("data"), "sqlui" }
  vim.list_extend(parts, { ... })
  return table.concat(parts, "/")
end

function M.ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, "p")
  end
end

function M.parent_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

function M.read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end

  local raw = table.concat(lines, "\n")
  if raw == "" then
    return nil
  end

  local decode_ok, decoded = pcall(vim.json.decode, raw)
  if not decode_ok or type(decoded) ~= "table" then
    return nil
  end

  return decoded
end

function M.write_json(path, data)
  M.ensure_dir(M.parent_dir(path))
  vim.fn.writefile(vim.split(vim.json.encode(data), "\n", { plain = true }), path)
end

function M.file_exists(path)
  return vim.fn.filereadable(path) == 1
end

function M.delete(path)
  if M.file_exists(path) then
    vim.fn.delete(path)
  end
end

function M.tempname(ext)
  local name = vim.fn.tempname()
  if ext and ext ~= "" then
    return name .. ext
  end
  return name
end

return M
