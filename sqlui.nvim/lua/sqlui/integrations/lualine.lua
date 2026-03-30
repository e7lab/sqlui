--- sqlui.nvim lualine component
--- Shows the active database connection alias in the statusline.
---
--- Usage in lualine config:
---   lualine_x = { require("sqlui.integrations.lualine") }

local M = {}

local defaults = {
  icon = "󰆼",
  color = { fg = "#b4a1db" },
}

--- Returns a lualine component table.
--- @param opts? { icon?: string, color?: table }
--- @return table lualine_component
function M.component(opts)
  opts = vim.tbl_deep_extend("force", {}, defaults, opts or {})

  return {
    function()
      local ok, state = pcall(require, "sqlui.state")
      if not ok then
        return ""
      end

      local conn = state.get_current_connection()
      if not conn or not conn.alias or conn.alias == "" then
        return ""
      end

      local label = conn.alias
      if conn.schema and conn.schema ~= "" then
        label = label .. "/" .. conn.schema
      end

      return opts.icon .. " " .. label
    end,

    cond = function()
      local ok, state = pcall(require, "sqlui.state")
      if not ok then
        return false
      end

      local conn = state.get_current_connection()
      return conn ~= nil and conn.alias ~= nil and conn.alias ~= ""
    end,

    color = opts.color,
  }
end

--- Shortcut: calling the module directly returns a component with defaults.
--- This allows:  lualine_x = { require("sqlui.integrations.lualine") }
return setmetatable(M, {
  __call = function(_, opts)
    return M.component(opts)
  end,
})
