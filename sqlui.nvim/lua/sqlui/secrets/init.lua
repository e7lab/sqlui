local platform = require("sqlui.util.platform")

local M = {}

function M.resolve(requested)
  if requested and requested ~= "auto" then
    if requested == "macos" then
      return require("sqlui.secrets.macos")
    end
    if requested == "secret-tool" then
      return require("sqlui.secrets.linux_secret_tool")
    end
    if requested == "kwallet" then
      return require("sqlui.secrets.linux_kwallet")
    end
    if requested == "file" then
      return require("sqlui.secrets.file")
    end
  end

  if platform.is_macos() and require("sqlui.secrets.macos").available() then
    return require("sqlui.secrets.macos")
  end
  if platform.is_linux() and require("sqlui.secrets.linux_secret_tool").available() then
    return require("sqlui.secrets.linux_secret_tool")
  end
  if platform.is_linux() and require("sqlui.secrets.linux_kwallet").available() then
    return require("sqlui.secrets.linux_kwallet")
  end

  return require("sqlui.secrets.file")
end

return M
