local M = {}

function M.setup()
  local ok_cmp, cmp = pcall(require, "cmp")
  if not ok_cmp then
    return false
  end

  local source = {}

  function source:new()
    return setmetatable({}, { __index = self })
  end

  function source:is_available()
    return vim.bo.filetype == "sql"
  end

  function source:get_trigger_characters()
    return { ".", "_" }
  end

  function source:complete(params, callback)
    local line = params.context.cursor_before_line or ""
    local prefix = line:match("([%w_.]+)$") or ""
    if prefix == "" then
      callback({ items = {}, isIncomplete = false })
      return
    end

    local items = require("sqlui.schema").get_completion_items(prefix)
    local mapped = {}
    local kinds = {
      tables = cmp.lsp.CompletionItemKind.Struct,
      views = cmp.lsp.CompletionItemKind.Interface,
      functions = cmp.lsp.CompletionItemKind.Function,
      procedures = cmp.lsp.CompletionItemKind.Method,
    }

    for _, item in ipairs(items) do
      table.insert(mapped, {
        label = item.label,
        insertText = item.insert_text,
        kind = kinds[item.kind] or cmp.lsp.CompletionItemKind.Text,
        filterText = item.label,
      })
    end

    callback({ items = mapped, isIncomplete = false })
  end

  cmp.register_source("sqlui_cache", source:new())
  return true
end

return M
