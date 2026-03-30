local config = require("sqlui.config")
local state = require("sqlui.state")

local M = {}

local function notify_stub(action)
  vim.notify("sqlui scaffold: " .. action .. " is ready for migration", vim.log.levels.INFO)
end

function M.setup(opts)
  local merged = config.merge(opts)
  state.set_config(merged)
  pcall(require("sqlui.completion").setup)
  return merged
end

function M.menu()
  require("sqlui.runner").menu()
end

function M.menu_selection()
  require("sqlui.runner").menu_selection()
end

function M.menu_selection_from_visual()
  require("sqlui.runner").capture_visual_menu()
end

function M.run()
  require("sqlui.runner").run()
end

function M.run_selection()
  require("sqlui.runner").run_selection()
end

function M.run_last_connection()
  require("sqlui.runner").run_last_connection()
end

function M.run_last_connection_selection()
  require("sqlui.runner").run_last_connection_selection()
end

function M.run_last_connection_selection_from_visual()
  require("sqlui.runner").capture_visual_run_last_connection()
end

function M.select_connection()
  require("sqlui.connection").select()
end

function M.browser()
  require("sqlui.schema").browser()
end

function M.view_data(target)
  require("sqlui.data_viewer").view(target)
end

function M.history()
  require("sqlui.runner").history()
end

function M.export_csv()
  require("sqlui.runner").export_csv()
end

function M.export_csv_selection()
  require("sqlui.runner").export_csv_selection()
end

function M.export_csv_selection_from_visual()
  require("sqlui.runner").capture_visual_export_csv()
end

function M.export_xlsx()
  require("sqlui.runner").export_xlsx()
end

function M.export_xlsx_selection()
  require("sqlui.runner").export_xlsx_selection()
end

function M.export_xlsx_selection_from_visual()
  require("sqlui.runner").capture_visual_export_xlsx()
end

function M.build_cache()
  require("sqlui.schema").build_cache()
end

function M.clear_cache()
  require("sqlui.schema").clear_cache()
end

function M.help()
  require("sqlui.help").open()
end

function M.health()
  require("sqlui.health").check()
end

function M.version()
  return "0.1.0-dev"
end

function M.todo()
  notify_stub("migration")
end

return M
