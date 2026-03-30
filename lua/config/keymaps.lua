-- Keymaps migrated from init.vim

local function t(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local function feed(keys, mode)
  vim.api.nvim_feedkeys(t(keys), mode or "n", false)
end

local function trim(str)
  return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_comment_parts()
  local commentstring = vim.bo.commentstring

  if type(commentstring) == "string" and commentstring ~= "" and commentstring:match("%%s") then
    local left, right = commentstring:match("^(.*)%%s(.*)$")
    left = left or "#"
    right = right or ""

    left = trim(left)
    right = trim(right)

    if left == "" then
      left = "#"
    end

    return left, right
  end

  local comments = vim.bo.comments or ""
  for _, part in ipairs(vim.split(comments, ",", { plain = true, trimempty = true })) do
    local marker = part:match("^:%s*(.+)$")
    if marker and marker ~= "" then
      marker = trim(marker)
      if marker ~= "" then
        return marker, ""
      end
    end
  end

  return "#", ""
end

local function is_commented(line, left, right)
  local indent, content = line:match("^(%s*)(.*)$")

  if not content:match("^" .. vim.pesc(left)) then
    return false
  end

  content = content:gsub("^" .. vim.pesc(left), "", 1)

  if right ~= "" then
    content = trim(content)
    return content:match(vim.pesc(right) .. "$") ~= nil
  end

  return true
end

local function toggle_comment(start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
  local left, right = get_comment_parts()
  local should_uncomment = true

  for _, line in ipairs(lines) do
    if trim(line) ~= "" and not is_commented(line, left, right) then
      should_uncomment = false
      break
    end
  end

  for i, line in ipairs(lines) do
    local indent, content = line:match("^(%s*)(.*)$")

    if should_uncomment and trim(line) ~= "" and is_commented(line, left, right) then
      content = content:gsub("^" .. vim.pesc(left), "", 1)
      if right ~= "" then
        local suffix = "%s*" .. vim.pesc(right) .. "$"
        content = content:gsub(suffix, "", 1)
      end
      lines[i] = indent .. content
    elseif not should_uncomment then
      if right ~= "" then
        lines[i] = indent .. left .. " " .. content .. " " .. right
      else
        lines[i] = indent .. left .. " " .. content
      end
    end
  end

  vim.api.nvim_buf_set_lines(0, start_line, end_line, false, lines)
end

local config_dir = vim.fn.stdpath("config")
local git_commit_prompt = require("config.git_commit_prompt")

-- Make a remap to select the word under the cursor
vim.keymap.set("n", "<leader>w", "viw", { silent = true })

-- Edit configs
vim.keymap.set("n", "<leader>ev", "<cmd>edit $MYVIMRC<CR>", { silent = true })
vim.keymap.set("n", "<leader>el", "<cmd>edit " .. config_dir .. "/init.lua<CR>", { silent = true })
vim.keymap.set("n", "<leader>elp", "<cmd>edit " .. config_dir .. "/lua/plugins/init.lua<CR>", { silent = true })

-- Add 4 spaces at start of line/selection
vim.keymap.set("n", "<F3>", function()
  feed("I    <Esc>")
end, { silent = true })

vim.keymap.set("x", "<F3>", ":<C-u>'<,'>s/^/    /<CR>", { silent = true })

-- Add # at start of line/selection
vim.keymap.set("n", "<leader>/", function()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  toggle_comment(line, line + 1)
end, { silent = true, desc = "Toggle line comment" })

vim.keymap.set("v", "<leader>/", function()
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  toggle_comment(start_line - 1, end_line)
end, { silent = true, desc = "Toggle selection comment" })

-- Visual indent (kept close to original intent)
vim.keymap.set("x", "<leader>i", ":<C-u>'<,'>s/^/    /<CR>gv", { silent = true })
vim.keymap.set("x", "<leader>a", ":<C-u>'<,'>s/^/    /<CR>", { silent = true })

-- Telescope / FZF fallback (Telescope keymaps moved to plugins/init.lua lazy keys)
local has_telescope = pcall(require, "telescope")
if not has_telescope then
  vim.keymap.set("n", "<leader>fb", "<cmd>Buffers<CR>", { silent = true })
  vim.keymap.set("n", "<leader>gf", "<cmd>GFiles<CR>", { silent = true })
  vim.keymap.set("n", "<leader>gc", "<cmd>Commits<CR>", { silent = true })
  vim.keymap.set("n", "<leader>ff", "<cmd>Files<CR>", { silent = true })
  vim.keymap.set("n", "<leader>tt", "<cmd>Commands<CR>", { silent = true })
  vim.keymap.set("n", "<C-k>f", "<cmd>Files<CR>", { silent = true, desc = "FZF Files" })
end

-- Git UI (Diffview history)
vim.keymap.set("n", "<C-k>g", function()
  local out = vim.fn.system({ "git", "rev-parse", "--is-inside-work-tree" })
  if vim.v.shell_error ~= 0 or not tostring(out):match("true") then
    vim.notify("nao esta em um repositorio git", vim.log.levels.WARN)
    return
  end
  vim.cmd("DiffviewFileHistory")
end, { silent = true, desc = "DiffviewFileHistory" })
vim.keymap.set("n", "<leader>gm", git_commit_prompt.commit_current_file, {
  silent = true,
  desc = "Git commit current file",
})

-- Terminal
vim.keymap.set("n", "<C-k>t", function()
  vim.cmd("botright 15split | terminal")
  vim.cmd("startinsert")
end, { silent = true, desc = "Open terminal" })
-- SQL keymaps moved to sqlui.nvim lazy spec (plugins/init.lua)

-- Containers
vim.keymap.set({ "n", "t" }, "<leader>ld", function()
  require("lazydocker").toggle({ engine = "docker" })
end, { silent = true, desc = "LazyDocker" })
vim.keymap.set("n", "<leader>ds", "<cmd>DevcontainerStart<CR>", { silent = true, desc = "Devcontainer start" })
vim.keymap.set("n", "<leader>da", "<cmd>DevcontainerAttach<CR>", { silent = true, desc = "Devcontainer attach" })
vim.keymap.set("n", "<leader>de", "<cmd>DevcontainerExec<CR>", { silent = true, desc = "Devcontainer exec" })
vim.keymap.set("n", "<leader>dc", "<cmd>DevcontainerStop<CR>", { silent = true, desc = "Devcontainer stop" })

-- Prevent accidental browser opens (gx)
vim.keymap.set({ "n", "x" }, "gx", "<Nop>", { silent = true, desc = "Disable gx" })

-- Diffview
vim.keymap.set("n", "<leader>dvo", "<cmd>DiffviewOpen<CR>", { silent = true })
vim.keymap.set("n", "<leader>dvc", "<cmd>DiffviewClose<CR>", { silent = true })

-- Jump 5 steps with shift + arrows
vim.keymap.set({ "n", "x", "o" }, "<S-Up>", "5k", { silent = true })
vim.keymap.set({ "n", "x", "o" }, "<S-Down>", "5j", { silent = true })
vim.keymap.set({ "n", "x", "o" }, "<S-Left>", "5h", { silent = true })
vim.keymap.set({ "n", "x", "o" }, "<S-Right>", "5l", { silent = true })


-- Scroll 5 steps with ctrl + arrows
vim.keymap.set("n", "<C-Up>", "<cmd>normal! 5k<CR>", { silent = true })
vim.keymap.set("n", "<C-Down>", "<cmd>normal! 5j<CR>", { silent = true })
vim.keymap.set("n", "<C-Left>", "<cmd>normal! 5h<CR>", { silent = true })
vim.keymap.set("n", "<C-Right>", "<cmd>normal! 5l<CR>", { silent = true })

-- Remove blank lines quickly
vim.keymap.set("n", "<leader>dj", "m`:silent +g/\\m^\\s*$/d<CR>``:noh<CR>", { silent = true })
vim.keymap.set("n", "<leader>dk", "m`:silent -g/\\m^\\s*$/d<CR>``:noh<CR>", { silent = true })

-- Insert blank lines without autoformat (paste mode)
vim.keymap.set("n", "<A-j>", ":set paste<CR>m`o<Esc>``:set nopaste<CR>", { silent = true })
vim.keymap.set("n", "<A-k>", ":set paste<CR>m`O<Esc>``:set nopaste<CR>", { silent = true })

-- Save/quit
vim.keymap.set("n", "<C-s>", "<cmd>write<CR>", { silent = true })
vim.keymap.set("n", "<C-x>", "<cmd>write | quit<CR>", { silent = true })
vim.keymap.set("n", "<C-q>", "<cmd>quit<CR>", { silent = true })

-- Reload config
vim.keymap.set("n", "<C-r>", "<cmd>luafile $MYVIMRC<CR>", { silent = true })

-- File tree
vim.keymap.set("n", "<C-a>", "<cmd>NvimTreeToggle<CR>", { silent = true })

-- Tabs / Bufferline
vim.keymap.set("n", "te", "<cmd>tabnew<CR>", { silent = true })
vim.keymap.set("n", "tx", "<cmd>tabclose<CR>", { silent = true })
vim.keymap.set("n", "tr", "<cmd>tabprevious<CR>", { silent = true })
vim.keymap.set("n", "ty", "<cmd>tabnext<CR>", { silent = true })

-- Bufferline navigation (with icons)
local has_bufferline, bufferline = pcall(require, "bufferline")
if has_bufferline then
  vim.keymap.set("n", "<leader>1", "<cmd>BufferLineGoToBuffer 1<CR>", { silent = true, desc = "Go to buffer 1" })
  vim.keymap.set("n", "<leader>2", "<cmd>BufferLineGoToBuffer 2<CR>", { silent = true, desc = "Go to buffer 2" })
  vim.keymap.set("n", "<leader>3", "<cmd>BufferLineGoToBuffer 3<CR>", { silent = true, desc = "Go to buffer 3" })
  vim.keymap.set("n", "<leader>4", "<cmd>BufferLineGoToBuffer 4<CR>", { silent = true, desc = "Go to buffer 4" })
  vim.keymap.set("n", "<leader>5", "<cmd>BufferLineGoToBuffer 5<CR>", { silent = true, desc = "Go to buffer 5" })
  vim.keymap.set("n", "<leader>6", "<cmd>BufferLineGoToBuffer 6<CR>", { silent = true, desc = "Go to buffer 6" })
  vim.keymap.set("n", "<leader>7", "<cmd>BufferLineGoToBuffer 7<CR>", { silent = true, desc = "Go to buffer 7" })
  vim.keymap.set("n", "<leader>8", "<cmd>BufferLineGoToBuffer 8<CR>", { silent = true, desc = "Go to buffer 8" })
  vim.keymap.set("n", "<leader>9", "<cmd>BufferLineGoToBuffer 9<CR>", { silent = true, desc = "Go to buffer 9" })
  vim.keymap.set("n", "<leader>0", "<cmd>BufferLineGoToBuffer -1<CR>", { silent = true, desc = "Go to last buffer" })
  vim.keymap.set("n", "<leader>bc", "<cmd>BufferLinePickClose<CR>", { silent = true, desc = "Pick buffer to close" })
  vim.keymap.set("n", "<leader>bp", "<cmd>BufferLinePick<CR>", { silent = true, desc = "Pick buffer" })
end

-- Buffers
vim.keymap.set("n", "bd", "<cmd>bdelete<CR>", { silent = true })
vim.keymap.set("n", "bn", "<cmd>bnext<CR>", { silent = true })
vim.keymap.set("n", "bv", "<cmd>bprevious<CR>", { silent = true })

-- Splits
vim.keymap.set("n", "th", "<cmd>split<CR>", { silent = true })
vim.keymap.set("n", "tv", "<cmd>vsplit<CR>", { silent = true })

-- Split navigation
vim.keymap.set("n", "<C-h>", "<C-w>h", { silent = true })
vim.keymap.set("n", "<C-j>", "<C-w>j", { silent = true })
vim.keymap.set("n", "<C-l>", "<C-w>l", { silent = true })

-- Wrap selected lines with single quotes and append comma: word -> 'word',
vim.keymap.set("x", "<leader>'", function()
  if not vim.bo.modifiable then
    vim.notify("Buffer não é editável", vim.log.levels.WARN)
    return
  end

  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  -- Exit visual mode before modifying buffer
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  for i, line in ipairs(lines) do
    local indent, content = line:match("^(%s*)(.-)%s*$")
    if content ~= "" then
      lines[i] = indent .. "'" .. content .. "',"
    end
  end

  vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, lines)
end, { silent = true, desc = "Wrap lines with 'quotes' and trailing comma" })

-- Leader + backslash to escape
vim.keymap.set({ "n", "v" }, "<leader>\\", "<Esc>", { silent = true })
