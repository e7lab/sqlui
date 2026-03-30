if vim.g.loaded_sqlui == 1 then
  return
end

vim.g.loaded_sqlui = 1

local function call(name)
  return function()
    require("sqlui")[name]()
  end
end

vim.api.nvim_create_user_command("SqlUiMenu", call("menu"), { desc = "Open sqlui main menu" })
vim.api.nvim_create_user_command("SqlUiRun", call("run"), { desc = "Run current SQL" })
vim.api.nvim_create_user_command("SqlUiRunSelection", call("run_selection"), { desc = "Run selected SQL" })
vim.api.nvim_create_user_command("SqlUiRunLastConnection", call("run_last_connection"), {
  desc = "Run current SQL with last connection",
})
vim.api.nvim_create_user_command("SqlUiSelectConnection", call("select_connection"), {
  desc = "Select sqlui connection",
})
vim.api.nvim_create_user_command("SqlUiBrowser", call("browser"), { desc = "Open sqlui browser" })
vim.api.nvim_create_user_command("SqlUiViewData", function(opts)
  require("sqlui").view_data(opts.args ~= "" and opts.args or nil)
end, {
  desc = "Open sqlui table/view data viewer",
  nargs = "?",
})
vim.api.nvim_create_user_command("SqlUiHistory", call("history"), { desc = "Open sqlui history" })
vim.api.nvim_create_user_command("SqlUiExportCsv", call("export_csv"), { desc = "Export SQL to CSV" })
vim.api.nvim_create_user_command("SqlUiExportXlsx", call("export_xlsx"), { desc = "Export SQL to XLSX" })
vim.api.nvim_create_user_command("SqlUiBuildCache", call("build_cache"), {
  desc = "Build sqlui schema cache",
})
vim.api.nvim_create_user_command("SqlUiClearCache", call("clear_cache"), {
  desc = "Clear sqlui schema cache",
})
vim.api.nvim_create_user_command("SqlUiHelp", call("help"), { desc = "Open sqlui help" })
