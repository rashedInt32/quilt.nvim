-- End to end: one test per bug found in review and in the real-project session, so none comes back.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers/e2e.lua")
local eq = MiniTest.expect.equality

local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.restart(child)
    end,
    post_case = H.cleanup,
    post_once = child.stop,
  },
})

-- a4 a5 a6 | b2 b3 b4
local function two()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 10), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  return fx, a, b, H.quilt_qf(child, { { a, 5 }, { b, 3 } })
end

local function all_start_with(lines, prefix)
  for _, l in ipairs(lines) do
    if l:sub(1, #prefix) ~= prefix then
      return l
    end
  end
  return true
end

T[":%s that splits lines keeps every new line in its own file"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[%s/\v(\a)(\d+)/\1\2\r\1-new/g]])
  H.settle(child, qbuf)
  local al, bl = H.buf_lines(child, a), H.buf_lines(child, b)
  eq(all_start_with(al, "a"), true)
  eq(all_start_with(bl, "b"), true)
  eq(#al, 13)
  eq(#bl, 13)
  eq({ unpack(al, 4, 9) }, { "a4", "a-new", "a5", "a-new", "a6", "a-new" })
  H.check(child, qbuf)
end

T["a formatter that rewrites the whole file keeps excerpts the same size"] = function()
  local _, a, _, qbuf = two()
  child.lua(
    [[
    local path = ...
    vim.api.nvim_create_autocmd("BufWritePre", { pattern = path, callback = function(ev)
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      lines[1] = "A1"
      vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, lines)
    end })
  ]],
    { a }
  )
  H.go(child, 1)
  child.type_keys("A!", "<Esc>")
  H.settle(child, qbuf)
  child.cmd("write")
  H.settle(child, qbuf)
  eq(H.disk(a)[1], "A1")
  eq(H.disk(a)[5], "a5!")
  eq(H.spans_of(child, qbuf, a), { { 3, 3 } })
  H.check(child, qbuf)
end

T["several LSP text edits in one source, applied bottom-up, land in the right rows"] = function()
  local _, a, _, qbuf = two()
  child.lua(
    [[
    local buf = vim.fn.bufnr(...)
    vim.lsp.util.apply_text_edits({
      { range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } }, newText = "" },
      { range = { start = { line = 4, character = 0 }, ["end"] = { line = 4, character = 2 } }, newText = "A5" },
    }, buf, "utf-8")
  ]],
    { a }
  )
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "A5", "a6", "b2", "b3", "b4" })
  eq(H.spans_of(child, qbuf, a), { { 2, 3 } })
  H.check(child, qbuf)
end

T[":w {file} in a quilt writes nothing"] = function()
  local fx, a, _, qbuf = two()
  H.go(child, 1)
  child.type_keys("A!", "<Esc>")
  H.settle(child, qbuf)
  local other = fx.dir .. "/other.txt"
  child.cmd("silent! write " .. vim.fn.fnameescape(other))
  eq(vim.fn.filereadable(other), 0)
  eq(H.disk(a)[5], "a5")
  eq(H.modified(child, H.bufnr(child, a)), true)
  H.check(child, qbuf)
end

T[":e! in a quilt rereads it and keeps it working"] = function()
  local _, _, b, qbuf = two()
  child.cmd("edit!")
  H.settle(child, qbuf)
  eq(child.api.nvim_get_current_buf(), qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6", "b2", "b3", "b4" })
  child.type_keys("gg", "]]", "A!", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, b)[2], "b2!")
  H.check(child, qbuf)
end

T["max_excerpts refuses before loading any file"] = function()
  local files = {}
  for i = 1, 5 do
    files["f" .. i .. ".lua"] = H.lines("f" .. i, 3)
  end
  local fx = H.setup(child, files)
  H.config(child, { context = 0, max_excerpts = 2 })
  local items = {}
  for i = 1, 5 do
    items[#items + 1] = { filename = fx.paths["f" .. i .. ".lua"], lnum = 1 }
  end
  child.lua("vim.fn.setqflist(...)", { items })
  child.cmd("Quilt")
  eq(child.bo.filetype ~= "quilt", true)
  local loaded = child.lua([[
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b):match("f%d%.lua$") then n = n + 1 end
    end
    return n
  ]])
  eq(loaded, 0)
end

T["dd on a one-row excerpt then u puts the line back in its own file"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 10), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 }, { a, 8 } })
  H.go(child, 2)
  child.type_keys("dd")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), H.lines("a", 10))
  eq(H.buf_lines(child, b), H.lines("b", 10))
  H.check(child, qbuf)
end

return T
