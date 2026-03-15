-- Keymaps migrated from init.vim

local function t(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local function feed(keys, mode)
  vim.api.nvim_feedkeys(t(keys), mode or "n", false)
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

-- Visual indent (kept close to original intent)
vim.keymap.set("x", "<leader>i", ":<C-u>'<,'>s/^/    /<CR>gv", { silent = true })
vim.keymap.set("x", "<leader>a", ":<C-u>'<,'>s/^/    /<CR>", { silent = true })

-- Telescope (if available) / FZF fallback
local has_telescope, telescope_builtin = pcall(require, "telescope.builtin")
if has_telescope then
  vim.keymap.set("n", "<leader>gf", telescope_builtin.git_files, { silent = true })
  vim.keymap.set("n", "<leader>gc", telescope_builtin.git_commits, { silent = true })
  vim.keymap.set("n", "<leader>ff", telescope_builtin.find_files, { silent = true })
  vim.keymap.set("n", "<leader>tt", telescope_builtin.builtin, { silent = true })
else
  vim.keymap.set("n", "<leader>gf", "<cmd>GFiles<CR>", { silent = true })
  vim.keymap.set("n", "<leader>gc", "<cmd>Commits<CR>", { silent = true })
  vim.keymap.set("n", "<leader>ff", "<cmd>Files<CR>", { silent = true })
  vim.keymap.set("n", "<leader>tt", "<cmd>Commands<CR>", { silent = true })
end

-- Quick file finder (Telescope or FZF fallback)
if has_telescope then
  vim.keymap.set("n", "<C-k>f", telescope_builtin.find_files, { silent = true, desc = "Telescope find files" })
else
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

-- Tabs
vim.keymap.set("n", "te", "<cmd>tabnew<CR>", { silent = true })
vim.keymap.set("n", "tx", "<cmd>tabclose<CR>", { silent = true })
vim.keymap.set("n", "tr", "<cmd>tabprevious<CR>", { silent = true })
vim.keymap.set("n", "ty", "<cmd>tabnext<CR>", { silent = true })

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

-- Leader + backslash to escape
vim.keymap.set({ "n", "v" }, "<leader>\\", "<Esc>", { silent = true })
