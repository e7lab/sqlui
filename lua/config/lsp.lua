local M = {}

local function map(bufnr, mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
end

local function buf_root(bufnr, markers)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == nil or name == "" then
    return vim.fn.getcwd()
  end
  return vim.fs.root(name, markers) or vim.fn.getcwd()
end

local function resolve_cmd(preferred_cmd, fallback_exe)
  if type(preferred_cmd) == "table" and preferred_cmd[1] and vim.fn.executable(preferred_cmd[1]) == 1 then
    return preferred_cmd
  end
  if fallback_exe and vim.fn.executable(fallback_exe) == 1 then
    return { fallback_exe }
  end
  return nil
end

function M.set_sql_connection(alias, dsn)
  require("sqlui.lsp").sync_connection({ alias = alias, dsn = dsn })
end

function M.get_sql_connection()
  return require("sqlui.lsp").get_connection()
end

function M.setup()
  if type(vim.lsp) ~= "table" or type(vim.lsp.config) ~= "table" or type(vim.lsp.enable) ~= "function" then
    vim.schedule(function()
      vim.notify("Neovim LSP config API nao disponivel (requer nvim >= 0.11)", vim.log.levels.WARN)
    end)
    return
  end

  vim.diagnostic.config({
    virtual_text = true,
    signs = true,
    underline = true,
    update_in_insert = false,
    severity_sort = true,
  })

  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok_cmp, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
  if ok_cmp then
    capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local bufnr = args.buf

      map(bufnr, "n", "gd", vim.lsp.buf.definition, "LSP: definition")
      map(bufnr, "n", "gD", vim.lsp.buf.declaration, "LSP: declaration")
      map(bufnr, "n", "gi", vim.lsp.buf.implementation, "LSP: implementation")
      map(bufnr, "n", "gr", vim.lsp.buf.references, "LSP: references")
      map(bufnr, "n", "K", vim.lsp.buf.hover, "LSP: hover")
      map(bufnr, "n", "<leader>rn", vim.lsp.buf.rename, "LSP: rename")
      map(bufnr, { "n", "x" }, "<leader>ca", vim.lsp.buf.code_action, "LSP: code action")

      map(bufnr, "n", "[d", vim.diagnostic.goto_prev, "Diag: prev")
      map(bufnr, "n", "]d", vim.diagnostic.goto_next, "Diag: next")
      map(bufnr, "n", "<leader>e", vim.diagnostic.open_float, "Diag: float")

      map(bufnr, "n", "<leader>f", function()
        vim.lsp.buf.format({ async = true })
      end, "LSP: format")
    end,
  })

  -- Minimal replacement for the old :LspInfo from nvim-lspconfig.
  vim.api.nvim_create_user_command("LspInfo", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local name = vim.api.nvim_buf_get_name(bufnr)

    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    local lines = {}
    table.insert(lines, "Buffer: " .. bufnr)
    table.insert(lines, "Filetype: " .. (ft ~= "" and ft or "<none>"))
    table.insert(lines, "Path: " .. (name ~= "" and name or "<none>"))
    table.insert(lines, "")

    if #clients == 0 then
      table.insert(lines, "Active LSP clients: none")
    else
      table.insert(lines, "Active LSP clients (buffer):")
      for _, c in ipairs(clients) do
        local cmd = c.config and c.config.cmd
        local cmd_str = "<none>"
        if type(cmd) == "table" then
          cmd_str = table.concat(cmd, " ")
        elseif type(cmd) == "string" then
          cmd_str = cmd
        end

        local root = (c.config and (c.config.root_dir or c.root_dir)) or c.root_dir
        if type(root) ~= "string" or root == "" then
          root = "<none>"
        end

        table.insert(lines, string.format("- %s (id=%s)", c.name or "<unnamed>", tostring(c.id)))
        table.insert(lines, "  root: " .. root)
        table.insert(lines, "  cmd:  " .. cmd_str)
      end
    end

    local log_path = vim.lsp.get_log_path and vim.lsp.get_log_path() or "<unknown>"
    table.insert(lines, "")
    table.insert(lines, "Log: " .. log_path)

    local out = vim.api.nvim_create_buf(false, true)
    vim.bo[out].buftype = "nofile"
    vim.bo[out].bufhidden = "wipe"
    vim.bo[out].swapfile = false
    vim.bo[out].modifiable = true
    vim.api.nvim_buf_set_lines(out, 0, -1, false, lines)
    vim.bo[out].modifiable = false

    vim.cmd("botright 12new")
    vim.api.nvim_win_set_buf(0, out)
    vim.bo[out].filetype = "lspinfo"
    vim.cmd("setlocal nobuflisted nospell nowrap")
  end, { desc = "Show active LSP clients (core)" })

  vim.api.nvim_create_user_command("LspLog", function()
    if not vim.lsp.get_log_path then
      vim.notify("vim.lsp.get_log_path() nao disponivel", vim.log.levels.WARN)
      return
    end
    vim.cmd.edit(vim.lsp.get_log_path())
  end, { desc = "Open LSP log file" })

  local home = vim.env.HOME or "/home/phell"

  local vtsls_cmd = nil
  do
    local preferred = { home .. "/.nvm/versions/node/v20.20.0/bin/vtsls", "--stdio" }
    if vim.fn.executable(preferred[1]) == 1 then
      vtsls_cmd = preferred
    elseif vim.fn.executable("vtsls") == 1 then
      vtsls_cmd = { "vtsls", "--stdio" }
    end
  end

  local gopls_cmd = resolve_cmd({ home .. "/.local/bin/gopls" }, "gopls")

  local sqls_cmd = nil
  do
    local mason_sqls = vim.fn.stdpath("data") .. "/mason/bin/sqls"
    if vim.fn.executable(mason_sqls) == 1 then
      sqls_cmd = { mason_sqls }
    elseif vim.fn.executable("sqls") == 1 then
      sqls_cmd = { "sqls" }
    end
  end
  if vtsls_cmd then
    vim.lsp.config("vtsls", {
      cmd = vtsls_cmd,
      capabilities = capabilities,
      filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
      root_dir = function(bufnr)
        return buf_root(bufnr, { "package.json", "tsconfig.json", "jsconfig.json", ".git" })
      end,
      settings = {
        typescript = {
          suggest = { completeFunctionCalls = true },
          inlayHints = { parameterNames = { enabled = "all" } },
        },
        vtsls = {
          experimental = { completion = { enableServerSideFuzzyMatch = true } },
        },
      },
    })
    vim.lsp.enable("vtsls")
  end

  if gopls_cmd then
    vim.lsp.config("gopls", {
      cmd = gopls_cmd,
      capabilities = capabilities,
      filetypes = { "go", "gomod", "gowork", "gotmpl" },
      root_dir = function(bufnr)
        return buf_root(bufnr, { "go.work", "go.mod", ".git" })
      end,
      settings = {
        gopls = {
          analyses = { unusedparams = true },
          staticcheck = true,
        },
      },
    })
    vim.lsp.enable("gopls")
  end

  if sqls_cmd then
    local mssql_dsn = vim.env.MSSQL_DSN or vim.env.SQLS_MSSQL_DSN
    local initial_connection = nil
    if mssql_dsn and mssql_dsn ~= "" then
      initial_connection = {
        alias = "env",
        dsn = mssql_dsn,
      }
    end

    require("sqlui.lsp").setup({
      capabilities = capabilities,
      sqls_cmd = sqls_cmd,
      root_dir_fn = function(bufnr)
        return buf_root(bufnr, { ".git" })
      end,
      initial_connection = initial_connection,
    })
  end
end

return M
