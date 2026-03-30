-- Autocommands migrated from init.vim

-- Colors (apply on any colorscheme)
vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = function()
    -- Let the terminal/GUI provide the background.
    -- Set your terminal background to black + the desired opacity to get "black + translucent".
    vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "NormalNC", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "FoldColumn", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "EndOfBuffer", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "LineNr", { bg = "NONE", fg = "#d3d3d3" })
    vim.api.nvim_set_hl(0, "CursorLineNr", { bg = "NONE" })
    -- Floats/popup menu: draw black + apply winblend/pumblend from options.
    vim.api.nvim_set_hl(0, "NormalFloat", { bg = "black" })
    vim.api.nvim_set_hl(0, "FloatBorder", { bg = "black" })
    vim.api.nvim_set_hl(0, "Pmenu", { bg = "black" })

    vim.api.nvim_set_hl(0, "TabLineSel", { bg = "#808080", fg = "black", bold = true })
    vim.api.nvim_set_hl(0, "TabLine", { bg = "NONE", fg = "white" })
    vim.api.nvim_set_hl(0, "TabLineFill", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "StatusLine", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "StatusLineNC", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "Comment", { fg = "#8e8e8e" })
    vim.api.nvim_set_hl(0, "SpellRare", { fg = "#AF9B87" })
    vim.api.nvim_set_hl(0, "Special", { fg = "#AF9B87" })
    vim.api.nvim_set_hl(0, "SpecialComment", { fg = "#AF9B87" })
    vim.api.nvim_set_hl(0, "MoreMsg", { fg = "#AD9985" })
    vim.api.nvim_set_hl(0, "String", { fg = "#85AD99" })

    -- nvim-tree git highlights
    -- Dirty = modified but not staged ("git add") and not ignored.
    vim.api.nvim_set_hl(0, "NvimTreeGitDirtyIcon", { fg = "#ff5f5f", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "NvimTreeGitFileDirtyHL", { fg = "#ff5f5f", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "NvimTreeGitFolderDirtyHL", { fg = "#ff5f5f", bg = "NONE", bold = true })

    -- Staged = changes added to index.
    vim.api.nvim_set_hl(0, "NvimTreeGitStagedIcon", { fg = "#ffd75f", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "NvimTreeGitFileStagedHL", { fg = "#ffd75f", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "NvimTreeGitFolderStagedHL", { fg = "#ffd75f", bg = "NONE", bold = true })

    -- Ignored = matches .gitignore
    vim.api.nvim_set_hl(0, "NvimTreeGitIgnoredIcon", { fg = "#ff5f5f", bg = "NONE" })
    vim.api.nvim_set_hl(0, "NvimTreeGitFileIgnoredHL", { fg = "#ff5f5f", bg = "NONE" })
    vim.api.nvim_set_hl(0, "NvimTreeGitFolderIgnoredHL", { fg = "#ff5f5f", bg = "NONE" })
  end,
})

-- Markdown/TXT keymaps
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "txt" },
  callback = function(ev)
    local opts = { silent = true, buffer = ev.buf }
    -- Alt+2 -> wrap with **
    vim.keymap.set("n", "<M-2>", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("I**<Esc>A**<Esc>", true, false, true), "n", false)
    end, opts)
    -- Alt+1 -> add two spaces at EOL (Markdown line break)
    vim.keymap.set("n", "<M-1>", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A  <Esc>", true, false, true), "n", false)
    end, opts)
    -- Alt+3 -> wrap with quotes
    vim.keymap.set("n", "<M-3>", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('I"<Esc>A"<Esc>', true, false, true), "n", false)
    end, opts)
  end,
})

local large_csv_bytes = 5 * 1024 * 1024

vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
  pattern = "*.csv",
  callback = function(ev)
    local path = vim.api.nvim_buf_get_name(ev.buf)
    if path == "" then
      return
    end

    local size = vim.fn.getfsize(path)
    if size > large_csv_bytes then
      vim.b[ev.buf].large_csv = true
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "csv",
  callback = function(ev)
    if not vim.b[ev.buf].large_csv then
      return
    end

    vim.bo[ev.buf].syntax = "OFF"
    vim.bo[ev.buf].swapfile = false
    vim.bo[ev.buf].undofile = false
    vim.wo[0].wrap = false
    vim.wo[0].cursorline = false
    vim.wo[0].number = false
    vim.wo[0].relativenumber = false
    vim.wo[0].signcolumn = "no"
    vim.wo[0].foldmethod = "manual"

    vim.schedule(function()
      vim.notify("CSV grande detectado: syntax/recursos pesados desativados para melhor desempenho", vim.log.levels.INFO)
    end)
  end,
})
