-- The :Quilt command and default highlight links.
if vim.g.loaded_quilt then
  return
end
vim.g.loaded_quilt = true

vim.api.nvim_create_user_command("Quilt", function(o)
  require("quilt").command(o.fargs)
end, {
  nargs = "*",
  desc = "Edit many excerpts in one buffer",
  complete = function(arglead, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    if #words > 2 or (#words == 2 and arglead == "") then
      if words[2] == "diagnostics" then
        return vim.tbl_filter(function(s)
          return vim.startswith(s, arglead)
        end, { "error", "warn", "info", "hint" })
      end
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, vim.tbl_keys(require("quilt").subcommands))
  end,
})

require("quilt.decor").setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("quilt_highlights", { clear = true }),
  callback = function()
    require("quilt.decor").setup_highlights()
  end,
})
