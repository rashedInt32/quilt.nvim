-- Entry points: config, the :Quilt subcommands, and building a quilt from hits.
local M = {}

local defaults = {
  context = 3,
  max_excerpts = 200,
  keys = {
    open = "<CR>",
    next = "]]",
    prev = "[[",
    expand = "+",
    shrink = "-",
    drop = "zd",
    hover = "K",
    definition = "gd",
    rename = "grn",
    code_action = "gra",
    references = "grr",
    implementation = "gri",
  },
}

M.config = vim.deepcopy(defaults)

local function notify(msg, level)
  vim.notify("quilt: " .. msg, level or vim.log.levels.INFO)
end

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

---Build a quilt from hits and show it in the current window.
---@param hits quilt.Hit[]
---@param title string
---@return integer? qbuf
function M.open_hits(hits, title)
  if not hits or #hits == 0 then
    notify("nothing to show for " .. title)
    return
  end
  local ranges, created = require("quilt.sources").to_ranges(hits, M.config.context)
  local count = #require("quilt.model").new(ranges):spans()
  if count == 0 then
    notify("nothing to show for " .. title)
    return
  end
  if count > M.config.max_excerpts then
    notify(("%d excerpts is over max_excerpts (%d)"):format(count, M.config.max_excerpts), vim.log.levels.WARN)
    return
  end
  return require("quilt.buffer").open(ranges, {
    title = title,
    created = created,
    keys = M.config.keys,
    context = M.config.context,
  })
end

local function async_cb(title)
  return function(hits, err)
    if not hits then
      notify(err or "failed", vim.log.levels.ERROR)
      return
    end
    M.open_hits(hits, title)
  end
end

-- The cursor as a source position. Inside a quilt it maps through the model.
local function cursor_pos()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local st = require("quilt.buffer").get(buf)
  if st then
    local span, src_row = st.model:locate(pos[1] - 1)
    if not span then
      return
    end
    return { src = span.src, row = src_row, col = pos[2] }
  end
  return { src = buf, row = pos[1] - 1, col = pos[2] }
end

M.subcommands = {
  qf = function()
    M.open_hits(require("quilt.sources").from_qf(), "quickfix")
  end,
  refs = function()
    local pos = cursor_pos()
    if pos then
      require("quilt.lsp").references(pos, async_cb("refs"))
    end
  end,
  grep = function(args)
    local pattern = table.concat(args, " ")
    if pattern == "" then
      notify("usage: :Quilt grep {pattern}", vim.log.levels.WARN)
      return
    end
    require("quilt.sources").grep(pattern, {}, async_cb("grep " .. pattern))
  end,
  diagnostics = function(args)
    M.open_hits(require("quilt.sources").from_diagnostics(args[1]), "diagnostics")
  end,
  git = function(args)
    require("quilt.sources").git(args[1], {}, async_cb("git " .. (args[1] or "")))
  end,
  refresh = function()
    local buf = vim.api.nvim_get_current_buf()
    if not require("quilt.buffer").get(buf) then
      notify("not a quilt buffer", vim.log.levels.WARN)
      return
    end
    require("quilt.buffer").resync(buf)
  end,
}

---Run a :Quilt subcommand.
---@param fargs string[]
function M.command(fargs)
  local name = fargs[1] or "qf"
  local fn = M.subcommands[name]
  if not fn then
    notify("unknown subcommand: " .. name, vim.log.levels.ERROR)
    return
  end
  fn(vim.list_slice(fargs, 2))
end

return M
