vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

require("sqlui").setup({
  secrets = { backend = "file" },
})

assert(require("sqlui").version() == "0.1.0-dev")
assert(type(require("sqlui.connection").list()) == "table")
