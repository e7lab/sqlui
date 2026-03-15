local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function system(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  result.stdout = result.stdout or ""
  result.stderr = result.stderr or ""
  return result
end

local function git_root_for_file(file)
  local dir = vim.fn.fnamemodify(file, ":h")
  local result = system({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "nao esta em um repositorio git"
  end
  return trim(result.stdout), nil
end

local function relative_to(root, file)
  return vim.fs.relpath(root, file) or vim.fn.fnamemodify(file, ":t")
end

local function file_has_changes(root, relpath)
  local result = system({ "git", "-C", root, "status", "--short", "--", relpath })
  if result.code ~= 0 then
    return false, trim(result.stderr)
  end
  return trim(result.stdout) ~= "", nil
end

local function commit_file(root, relpath, message)
  local add_result = system({ "git", "-C", root, "add", "--", relpath })
  if add_result.code ~= 0 then
    return false, trim(add_result.stderr) ~= "" and trim(add_result.stderr) or "falha ao adicionar arquivo ao stage"
  end

  local commit_result = system({ "git", "-C", root, "commit", "-m", message, "--", relpath })
  if commit_result.code ~= 0 then
    local err = trim(commit_result.stderr)
    if err == "" then
      err = trim(commit_result.stdout)
    end
    if err == "" then
      err = "falha ao criar commit"
    end
    return false, err
  end

  local output = trim(commit_result.stdout)
  if output == "" then
    output = trim(commit_result.stderr)
  end
  return true, output
end

local function open_prompt(opts)
  local width = math.min(72, math.max(40, vim.o.columns - 10))
  local height = 1
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(row, 0),
    col = math.max(col, 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "center",
  })

  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.fn.prompt_setprompt(buf, "> ")
  vim.fn.prompt_setcallback(buf, function(text)
    close()
    opts.on_submit(trim(text))
  end)

  vim.keymap.set("n", "q", function()
    close()
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    close()
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("i", "<Esc>", function()
    close()
  end, { buffer = buf, silent = true, nowait = true })

  vim.cmd.startinsert()
end

function M.commit_current_file()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("nenhum arquivo aberto para commitar", vim.log.levels.WARN)
    return
  end

  if vim.bo.modified then
    vim.cmd.write()
  end

  local root, root_err = git_root_for_file(file)
  if not root then
    vim.notify(root_err, vim.log.levels.WARN)
    return
  end

  local relpath = relative_to(root, file)
  local has_changes, status_err = file_has_changes(root, relpath)
  if status_err then
    vim.notify(status_err, vim.log.levels.ERROR)
    return
  end
  if not has_changes then
    vim.notify("o arquivo atual nao possui alteracoes para commit", vim.log.levels.INFO)
    return
  end

  open_prompt({
    title = "Git commit: " .. vim.fn.fnamemodify(file, ":t"),
    on_submit = function(message)
      if message == "" then
        vim.notify("commit cancelado: mensagem vazia", vim.log.levels.WARN)
        return
      end

      local ok, output = commit_file(root, relpath, message)
      if not ok then
        vim.notify(output, vim.log.levels.ERROR)
        return
      end

      vim.notify(output, vim.log.levels.INFO)
      vim.cmd.checktime()
    end,
  })
end

return M
