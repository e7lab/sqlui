local function has_nvim(min_major, min_minor, min_patch)
  local v = vim.version()
  if v.major ~= min_major then
    return v.major > min_major
  end
  if v.minor ~= min_minor then
    return v.minor > min_minor
  end
  return (v.patch or 0) >= (min_patch or 0)
end

return {
  -- Themes
  { "dylanaraps/crayon", lazy = true, priority = 900 },
  { "rebelot/kanagawa.nvim", lazy = true, priority = 1000 },
  {
    "projekt0n/github-nvim-theme",
    lazy = false,
    priority = 1000,
    config = function()
      require("github-theme").setup({
        options = {
          transparent = false,
        },
      })
      vim.cmd.colorscheme("github_dark")
    end,
  },
  { "dracula/vim", name = "dracula", lazy = true },
  { "sainnhe/gruvbox-material", lazy = true },
  { "AlexvZyl/nordic.nvim", lazy = true },

  -- File tree + icons
  { "nvim-tree/nvim-web-devicons", lazy = true },
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      -- recommended for nvim-tree
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1

      local function cmd_exists(cmd)
        return vim.fn.exists(":" .. cmd) == 2
      end

      require("nvim-tree").setup({
        tab = {
          sync = {
            open = true,
            close = true,
          },
        },
        view = { width = 35 },
        renderer = {
          group_empty = true,
          highlight_git = "all",
          icons = {
            show = {
              git = true,
            },
            glyphs = {
              git = {
                unstaged = "M",
                staged = "S",
                unmerged = "U",
                renamed = "R",
                untracked = "?",
                deleted = "D",
                ignored = "-",
              },
            },
          },
        },
        filters = {
          dotfiles = false,
          git_ignored = false,
          exclude = { ".env" },
        },
        git = {
          enable = true,
          show_on_dirs = true,
          show_on_open_dirs = true,
          timeout = 400,
        },
        update_focused_file = {
          enable = true,
          update_root = true,
        },
        on_attach = function(bufnr)
          local api = require("nvim-tree.api")
          api.config.mappings.default_on_attach(bufnr)

          local function map(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, {
              buffer = bufnr,
              noremap = true,
              silent = true,
              nowait = true,
              desc = "nvim-tree: " .. desc,
            })
          end

          local function node_dir()
            local node = api.tree.get_node_under_cursor()
            if not node then
              return vim.fn.getcwd()
            end

            local path = node.absolute_path or node.link_to
            if not path then
              return vim.fn.getcwd()
            end

            if node.type == "directory" then
              return path
            end
            return vim.fn.fnamemodify(path, ":h")
          end

          local function git_dir(dir)
            local result = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
            if result.code ~= 0 then
              local msg = vim.trim(result.stderr or "")
              if msg == "" then
                msg = "Nao foi possivel acessar o repositorio git desta pasta"
              end
              vim.notify(msg, vim.log.levels.WARN)
              return nil
            end
            return vim.trim(result.stdout)
          end

          -- Disable system open mapping (prevents launching browser/file manager)
          pcall(vim.keymap.del, "n", "s", { buffer = bufnr })

          -- FZF integration (fzf.vim)
          map("<C-f>", function()
            if not cmd_exists("Files") then
              vim.notify("fzf.vim nao encontrado (:Files)", vim.log.levels.WARN)
              return
            end
            vim.cmd("Files " .. vim.fn.fnameescape(node_dir()))
          end, "FZF files (dir)")

          map("<C-p>", function()
            if not cmd_exists("Files") then
              vim.notify("fzf.vim nao encontrado (:Files)", vim.log.levels.WARN)
              return
            end
            vim.cmd("Files")
          end, "FZF files (cwd)")

          map("<C-g>", function()
            if not cmd_exists("GFiles") then
              vim.notify("fzf.vim nao encontrado (:GFiles)", vim.log.levels.WARN)
              return
            end
            vim.cmd("GFiles?")
          end, "FZF git files")

          -- Telescope integration (scoped to node dir)
          local has_telescope, tbuiltin = pcall(require, "telescope.builtin")
          if has_telescope then
            map("<leader>gf", function()
              local dir = git_dir(node_dir())
              if dir then
                tbuiltin.git_files({ cwd = dir })
              end
            end, "Telescope git files (dir)")

            map("<leader>gc", function()
              local dir = git_dir(node_dir())
              if dir then
                tbuiltin.git_commits({ cwd = dir })
              end
            end, "Telescope git commits (dir)")

            map("<leader>ff", function()
              tbuiltin.find_files({ cwd = node_dir() })
            end, "Telescope find files (dir)")
          end

           map("<C-n>", api.node.open.tab, "Open in new tab")
           
           -- Open file in new tab on Enter
           map("<CR>", function()
             local node = api.tree.get_node_under_cursor()
             if node and node.type == "file" then
               api.node.open.tab(node)
             elseif node and node.type == "directory" then
               api.node.open.edit(node)
             end
           end, "Open file in new tab or expand directory")
         end,
       })
     end,
   },

  -- Git
  { "tpope/vim-fugitive" },
  {
    "crnvl96/lazydocker.nvim",
    config = function()
      require("lazydocker").setup({})
    end,
  },
  {
    "lewis6991/gitsigns.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("gitsigns").setup({
        signs = {
          add = { text = "+" },
          change = { text = "~" },
          delete = { text = "_" },
          topdelete = { text = "^" },
          changedelete = { text = "~" },
        },
        current_line_blame = false,
      })
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local function current_branch()
        local status_dict = vim.b.gitsigns_status_dict
        if type(status_dict) == "table" and status_dict.head and status_dict.head ~= "" then
          return status_dict.head
        end

        local branch = vim.b.gitsigns_head
        if branch and branch ~= "" then
          return branch
        end

        local fugitive_head = vim.b.fugitive_head
        if fugitive_head and fugitive_head ~= "" then
          return fugitive_head
        end

        local ok, head = pcall(vim.fn.FugitiveHead)
        if ok and head and head ~= "" then
          return head
        end

        return ""
      end

      local function branch_colors()
        local branch = current_branch()
        if branch == "main" or branch == "master" then
          return { fg = "#ffffff", bg = "#444444", gui = "bold" }
        end
        return { fg = "#000000", bg = "#999999" }
      end

      local gray_theme = {
        normal = {
          a = { bg = '#89b4fa', fg = '#0d1117', gui = 'bold' },
          b = { bg = '#1e2a3a', fg = '#b8c9e3' },
          c = { bg = '#141b2d', fg = '#7a8da6' }
        },
        insert = {
          a = { bg = '#74c7ec', fg = '#0d1117', gui = 'bold' },
          b = { bg = '#1e2a3a', fg = '#b8c9e3' },
          c = { bg = '#141b2d', fg = '#7a8da6' }
        },
        visual = {
          a = { bg = '#b4befe', fg = '#0d1117', gui = 'bold' },
          b = { bg = '#1e2a3a', fg = '#b8c9e3' },
          c = { bg = '#141b2d', fg = '#7a8da6' }
        },
        replace = {
          a = { bg = '#94e2d5', fg = '#0d1117', gui = 'bold' },
          b = { bg = '#1e2a3a', fg = '#b8c9e3' },
          c = { bg = '#141b2d', fg = '#7a8da6' }
        },
        command = {
          a = { bg = '#a6d1e6', fg = '#0d1117', gui = 'bold' },
          b = { bg = '#1e2a3a', fg = '#b8c9e3' },
          c = { bg = '#141b2d', fg = '#7a8da6' }
        },
        inactive = {
          a = { bg = '#141b2d', fg = '#4a5568', gui = 'bold' },
          b = { bg = '#141b2d', fg = '#4a5568' },
          c = { bg = '#141b2d', fg = '#4a5568' }
        }
      }

      require("lualine").setup({
        options = {
          theme = gray_theme,
          globalstatus = true,
          section_separators = { left = "", right = "" },
          component_separators = { left = "|", right = "|" },
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = {
            {
              "branch",
              icon = "",
              color = branch_colors,
            },
            "diff",
          },
          lualine_c = {
            {
              "filename",
              path = 1,
            },
          },
          lualine_x = { require("sqlui.integrations.lualine").component(), "diagnostics", "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },
   { "sindrets/diffview.nvim" },

   -- Tabline with icons
   {
     "nvim-lualine/lualine.nvim",
     optional = true,
   },
   {
     "akinsho/bufferline.nvim",
     version = "*",
     dependencies = { "nvim-tree/nvim-web-devicons" },
     config = function()
       require("bufferline").setup({
         options = {
           mode = "tabs",
           separator_style = "slant",
           show_buffer_close_icons = true,
           show_close_icon = true,
           color_icons = true,
           diagnostics = "nvim_lsp",
           diagnostics_indicator = function(count, level, diagnostics_dict, context)
             local icon = level:match("error") and " " or " "
             return " " .. icon .. count
           end,
           offsets = {
             {
               filetype = "NvimTree",
               text = "File Explorer",
               text_align = "left",
             },
           },
         },
         highlights = {
           fill = {
             fg = { attribute = "fg", highlight = "Normal" },
             bg = { attribute = "bg", highlight = "StatusLineNC" },
           },
         },
       })
     end,
   },

   -- Telescope
  { "nvim-lua/plenary.nvim" },
  { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    enabled = function()
      -- telescope.nvim requires >= 0.10.4
      return has_nvim(0, 10, 4)
    end,
    keys = {
      { "<leader>fb", "<cmd>Telescope buffers<CR>", desc = "Telescope buffers" },
      { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Telescope find files" },
      { "<leader>gf", "<cmd>Telescope git_files<CR>", desc = "Telescope git files" },
      { "<leader>gc", "<cmd>Telescope git_commits<CR>", desc = "Telescope git commits" },
      { "<leader>tt", "<cmd>Telescope builtin<CR>", desc = "Telescope builtin" },
      { "<C-k>f", "<cmd>Telescope find_files<CR>", desc = "Telescope find files" },
    },
    config = function()
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local function open_in_diffview(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        -- capture the cwd used by the picker before closing
        local picker = action_state.get_current_picker(prompt_bufnr)
        local cwd = picker.cwd or vim.fn.getcwd()
        actions.close(prompt_bufnr)
        if entry and entry.value then
          vim.cmd("DiffviewOpen " .. entry.value .. "~1.." .. entry.value .. " -C=" .. vim.fn.fnameescape(cwd))
        end
      end

      require("telescope").setup({
        defaults = {
          layout_strategy = "horizontal",
          layout_config = {
            horizontal = {
              width = 0.92,
              height = 0.82,
              preview_width = 0.6,
              prompt_position = "top",
            },
          },
          sorting_strategy = "ascending",
          mappings = {
            i = {
              ["<C-PageUp>"] = actions.preview_scrolling_up,
              ["<C-PageDown>"] = actions.preview_scrolling_down,
            },
            n = {
              ["<C-PageUp>"] = actions.preview_scrolling_up,
              ["<C-PageDown>"] = actions.preview_scrolling_down,
            },
          },
        },
        extensions = {
          fzf = {
            fuzzy = true,
            override_generic_sorter = true,
            override_file_sorter = true,
            case_mode = "smart_case",
          },
        },
        pickers = {
          git_commits = {
            current_previewer_index = 4,
            mappings = {
              i = { ["<CR>"] = open_in_diffview },
              n = { ["<CR>"] = open_in_diffview },
            },
          },
          git_bcommits = {
            current_previewer_index = 4,
            mappings = {
              i = { ["<CR>"] = open_in_diffview },
              n = { ["<CR>"] = open_in_diffview },
            },
          },
        },
      })

      require("telescope").load_extension("fzf")
    end,
  },
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
    },
    config = function()
      local cmp = require("cmp")
      local cmp_types = require("cmp.types")
      require("sqlui.completion").setup()

      vim.o.completeopt = "menu,menuone,noselect"

      cmp.setup({
        snippet = {
          expand = function(args)
            vim.snippet.expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = false }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "path" },
        }, {
          { name = "buffer" },
        }),
      })

      cmp.setup.filetype("sql", {
        sources = cmp.config.sources({
          { name = "sqlui_cache", priority = 1000 },
          { name = "nvim_lsp" },
          { name = "buffer" },
        }),
        completion = {
          autocomplete = {
            cmp_types.cmp.TriggerEvent.TextChanged,
            cmp_types.cmp.TriggerEvent.InsertEnter,
          },
        },
      })
    end,
  },
  {
    dir = vim.fn.stdpath("config") .. "/sqlui.nvim",
    name = "sqlui.nvim",
    lazy = false,
    keys = {
      { "<leader>ss", function() require("sqlui").menu() end, desc = "Open SQL actions menu" },
      { "<leader>ss", function() require("sqlui").menu_selection_from_visual() end, mode = "x", desc = "Open selected SQL actions menu" },
      { "<leader>sr", function() require("sqlui").run_last_connection() end, desc = "Run SQL with last connection" },
      { "<leader>sr", function() require("sqlui").run_last_connection_selection_from_visual() end, mode = "x", desc = "Run selected SQL with last connection" },
      { "<leader>se", function() require("sqlui").export_csv() end, desc = "Export SQL to CSV" },
      { "<leader>se", function() require("sqlui").export_csv_selection_from_visual() end, mode = "x", desc = "Export selected SQL to CSV" },
      { "<leader>sx", function() require("sqlui").export_xlsx() end, desc = "Export SQL to XLSX" },
      { "<leader>sx", function() require("sqlui").export_xlsx_selection_from_visual() end, mode = "x", desc = "Export selected SQL to XLSX" },
      { "<leader>sl", function() require("sqlui").select_connection() end, desc = "Select SQL connection" },
      { "<leader>sb", function() require("sqlui").select_connection() end, desc = "Select SQL database connection" },
      { "<leader>sa", function() require("sqlui").browser() end, desc = "Open SQL schema browser" },
      { "<leader>sc", function() require("sqlui").build_cache() end, desc = "Build SQL cache for current connection" },
      { "<leader>sh", function() require("sqlui").history() end, desc = "Show usql history" },
      { "<leader>s?", function() require("sqlui").help() end, desc = "Show SQL plugin guide" },
    },
    config = function()
      require("sqlui").setup({
        ui = {
          picker = "auto",
        },
        secrets = {
          backend = "auto",
        },
        usql = {
          bin = "usql",
        },
      })
    end,
  },

  -- Syntax
  { "sheerun/vim-polyglot" },
  { "godlygeek/tabular" },
  { "gabrielelana/vim-markdown", ft = { "markdown" } },

  -- FZF (kept from old config)
  { "junegunn/fzf", build = "./install --bin" },
  { "junegunn/fzf.vim" },

  -- Markdown preview (vars must be set before loading)
  {
    "iamcco/markdown-preview.nvim",
    ft = { "markdown" },
    build = "cd app && npm install",
    init = function()
      vim.g.mkdp_auto_start = 0
      vim.g.mkdp_auto_close = 1
      vim.g.mkdp_refresh_slow = 1
      vim.g.mkdp_command_for_global = 0
      vim.g.mkdp_open_to_the_world = 0
      vim.g.mkdp_browser = "firefox"
      vim.g.mkdp_echo_preview_url = 0
      vim.g.mkdp_preview_options = {
        mkit = {
          parser = "gfm",
          gfm_syntax_extensions = 0,
          enable_math = 0,
          enable_html = 1,
          enable_highlight = 1,
          enable_typographer = 0,
          font_size = 0,
          line_height = 0,
          left = 0,
          top = 0,
          theme = "default",
          disabled_syntaxes = {},
          protocol = "http://",
          pandoc_path = "pandoc",
          print_background = 1,
          preview_page = "preview",
          scrollvim = 1,
          sync_scroll_type = "middle",
          line_number = 0,
          max_width = 0,
          tabstop = 2,
          preserve_yaml = 0,
          disable_filename = 0,
          editor_height = 0,
          editor_width = 0,
          hide_yaml_meta = 0,
        },
      }

      vim.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<CR>", { silent = true })
    end,
  },

  -- Copilot
  {
    "github/copilot.vim",
    init = function()
      vim.g.copilot_filetypes = { ["*"] = true }
    end,
  },

  -- Containers
  {
    "esensar/nvim-dev-container",
    branch = "main",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    config = function()
      require("devcontainer").setup({})
    end,
  },

  -- LSP (aligned with OpenCode: vtsls + gopls)
  {
    "williamboman/mason.nvim",
    build = ":MasonUpdate",
    config = function()
      require("mason").setup({})
    end,
  },
}
