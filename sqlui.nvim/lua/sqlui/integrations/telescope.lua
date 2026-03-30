local M = {}

function M.available()
  return pcall(require, "telescope")
end

function M.select(items, opts, on_choice)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local themes = require("telescope.themes")

  local format_item = (opts or {}).format_item or function(item)
    return type(item) == "string" and item or vim.inspect(item)
  end

  local picker_opts = themes.get_dropdown({
    prompt_title = (opts or {}).prompt or "Select",
    layout_strategy = (opts or {}).layout_strategy or "horizontal",
    layout_config = (opts or {}).layout_config or {
      width = 0.8,
      height = 0.6,
      preview_width = 0.5,
    },
    previewer = (opts or {}).preview_item ~= nil,
  })

  local picker_previewer = nil
  if (opts or {}).preview_item then
    picker_previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local preview = opts.preview_item(entry.item)
        local lines
        if type(preview) == "table" then
          lines = preview
        else
          lines = vim.split(tostring(preview or ""), "\n", { plain = true })
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "txt"
      end,
    })
  end

  pickers
    .new(picker_opts, {
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local display = format_item(item)
          return {
            value = display,
            item = item,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = picker_previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          on_choice(entry and entry.item or nil)
        end)
        return true
      end,
    })
    :find()
end

function M.input(opts, on_confirm)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local themes = require("telescope.themes")

  local default = (opts or {}).default or ""
  local prompt_title = (opts or {}).prompt or "Input"

  pickers
    .new(themes.get_dropdown({
      prompt_title = prompt_title,
      layout_config = {
        width = 0.6,
        height = 0.2,
      },
      previewer = false,
    }), {
      finder = finders.new_table({
        results = {},
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        vim.schedule(function()
          if default ~= "" then
            vim.api.nvim_buf_set_lines(prompt_bufnr, 0, -1, false, {})
            vim.api.nvim_feedkeys(default, "n", false)
          end
        end)

        actions.select_default:replace(function()
          local value = action_state.get_current_line()
          actions.close(prompt_bufnr)
          on_confirm(value)
        end)

        return true
      end,
    })
    :find()
end

return M
