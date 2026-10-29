-- End to end: the second code review's repro cases, kept so they stay fixed.
-- luacheck: no unused (ported repro cases keep their fixture names)
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
local A0, B0 = H.lines("a", 10), H.lines("b", 10)
local function with(lines, at, ...)
  local out = vim.deepcopy(lines)
  for i, l in ipairs({ ... }) do
    table.insert(out, at + i - 1, l)
  end
  return out
end
local function without(lines, at, n)
  local out = vim.deepcopy(lines)
  for _ = 1, n or 1 do
    table.remove(out, at)
  end
  return out
end
local function set(lines, at, v)
  local out = vim.deepcopy(lines)
  out[at] = v
  return out
end
local function two(files)
  local fx = H.setup(child, files or { ["a.lua"] = A0, ["b.lua"] = B0 })
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  return a, b, H.quilt_qf(child, { { a, 5 }, { b, 3 } })
end

local function msgs()
  return child.cmd_capture("messages")
end

T["C1 collapsed last span then o on last row"] = function()
  local a, b, q = two()
  H.go(child, 3)
  child.type_keys("3dd")
  H.settle(child, q)
  eq(H.quilt_lines(child, q), { "a4", "a5", "a6" })
  H.go(child, 2)
  child.type_keys("o", "new", "<Esc>")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = with(A0, 7, "new"), b = without(B0, 2, 3) })
end

T["C2 collapsed last span then A<CR> on last row"] = function()
  local a, b, q = two()
  H.go(child, 3)
  child.type_keys("3dd")
  H.settle(child, q)
  H.go(child, 2)
  child.type_keys("A", "<CR>", "new", "<Esc>")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = with(A0, 7, "new"), b = without(B0, 2, 3) })
end

T["C3 collapsed last span, empty last row, type on it"] = function()
  local A = set(A0, 6, "")
  local a, b, q = two({ ["a.lua"] = A, ["b.lua"] = B0 })
  H.go(child, 3)
  child.type_keys("3dd")
  H.settle(child, q)
  eq(H.quilt_lines(child, q), { "a4", "a5", "" })
  H.go(child, 2)
  child.type_keys("i", "x", "<Esc>")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = set(A0, 6, "x"), b = without(B0, 2, 3) })
end

T["C4 last real line is empty: dd the other one"] = function()
  local fx = H.setup(child, { ["a.lua"] = { "a1", "a2", "a3" }, ["b.lua"] = { "b1", "", "b3" } })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local q = H.quilt_qf(child, { { a, 2 }, { b, 2 } })
  eq(H.quilt_lines(child, q), { "a2", "" })
  H.go(child, 0)
  child.type_keys("dd")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = { "a1", "a3" }, b = { "b1", "", "b3" } })
end

T["C5 source inserts 5 lines above an excerpt, then quilt edit"] = function()
  local a, b, q = two()
  local abuf = H.bufnr(child, a)
  child.api.nvim_buf_set_lines(abuf, 0, 0, true, { "n1", "n2", "n3", "n4", "n5" })
  H.settle(child, q)
  eq(H.spans_of(child, q, a), { { 8, 3 } })
  H.go(child, 1)
  child.type_keys("A", "!", "<Esc>")
  H.settle(child, q)
  eq(H.buf_lines(child, a), vim.list_extend({ "n1", "n2", "n3", "n4", "n5" }, set(A0, 5, "a5!")))
end

T["C6 source deletes 6 lines incl. a blank above an excerpt"] = function()
  local fx = H.setup(child, { ["a.lua"] = set(A0, 2, ""), ["b.lua"] = B0 })
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local q = H.quilt_qf(child, { { a, 9 }, { b, 3 } })
  child.api.nvim_buf_set_lines(H.bufnr(child, a), 0, 6, true, {})
  H.settle(child, q)
  eq(H.spans_of(child, q, a), { { 1, 3 } })
end

T["C7 external change inside excerpt then u in quilt"] = function()
  -- `u` in the quilt undoes the latest change it shows, like two windows on one buffer. SPEC "Known limits".
  MiniTest.skip("decided: u in the quilt also undoes a change made to the file elsewhere")
  local a, b, q = two()
  H.go(child, 1)
  child.type_keys("A!<Esc>")
  H.settle(child, q)
  child.api.nvim_buf_set_lines(H.bufnr(child, a), 3, 4, true, { "EXT" })
  H.settle(child, q)
  child.type_keys("u")
  H.settle(child, q)
  eq(H.buf_lines(child, a), set(A0, 4, "EXT"))
end

T["C8 :normal 4GP with stale cursor row"] = function()
  local a, b, q = two()
  H.go(child, 0)
  child.fn.setreg('"', { "P1" }, "l")
  child.cmd("normal 4GP")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = A0, b = with(B0, 2, "P1") })
end

T["C9 :e! in quilt then p on last row of A"] = function()
  local a, b, q = two()
  child.cmd("edit!")
  H.settle(child, q)
  child.fn.setreg('"', { "P1" }, "l")
  H.go(child, 2)
  child.type_keys("p")
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = with(A0, 7, "P1"), b = B0 })
  H.check(child, q)
end

T["C10 :e! in quilt then typing"] = function()
  local a, b, q = two()
  child.cmd("edit!")
  H.settle(child, q)
  H.go(child, 1)
  child.type_keys("A!<Esc>")
  H.settle(child, q)
  eq(H.buf_lines(child, a), set(A0, 5, "a5!"))
  H.check(child, q)
end
T["C11 intent from o leaks into later P in same :normal"] = function()
  local a, b, q = two()
  child.fn.setreg("r", { "P1" }, "l")
  child.cmd([[exe "normal 3GoX\<Esc>5G\"rP"]])
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = with(A0, 7, "X"), b = with(B0, 2, "P1") })
end

T["C12 undo_kind from u leaks into later p in same :normal"] = function()
  local a, b, q = two()
  child.fn.setreg("r", { "P1" }, "l")
  child.cmd([[exe "normal 2GA!\<Esc>u3G\"rp"]])
  H.settle(child, q)
  eq({ a = H.buf_lines(child, a), b = H.buf_lines(child, b) }, { a = with(A0, 7, "P1"), b = B0 })
end

T["C15 5-line insert with a blank inside an excerpt"] = function()
  local a, b, q = two()
  child.api.nvim_buf_set_lines(H.bufnr(child, a), 4, 4, true, { "n1", "", "n3", "n4", "n5" })
  H.settle(child, q)
  H.check(child, q)
end

T["C17 :bd! on quilt in the same command as an edit"] = function()
  local a, b, q = two()
  child.cmd([[exe "normal! 2GA!" | bdelete!]])
  child.lua("vim.wait(50)")
  eq(H.buf_lines(child, a), set(A0, 5, "a5!"))
end

return T
