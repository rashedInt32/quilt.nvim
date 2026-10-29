-- End to end, adversarial: key sequences and situations real users hit that test_e2e.lua does not cover.
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

local function abc()
  return H.setup(child, { ["a.lua"] = H.lines("a", 10), ["b.lua"] = H.lines("b", 10), ["c.lua"] = H.lines("c", 10) })
end

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

local function set(lines, at, value)
  local out = vim.deepcopy(lines)
  out[at] = value
  return out
end

-- a4 a5 a6 | b2 b3 b4: rows 0..2 are a.lua, rows 3..5 are b.lua.
local function two(ctx)
  local fx = abc()
  H.config(child, { context = ctx or 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })
  return fx, a, b, qbuf
end

local A0, B0, C0 = H.lines("a", 10), H.lines("b", 10), H.lines("c", 10)

-- Whole-quilt deletes ----------------------------------------------------------------

T[":%d deletes every excerpt's lines from the sources and leaves no excerpt"] = function()
  local _, a, b, qbuf = two()
  child.cmd("%d")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(A0, 4, 3))
  eq(H.buf_lines(child, b), without(B0, 2, 3))
  eq(#vim.tbl_filter(function(s)
    return s.count > 0
  end, H.spans(child, qbuf)), 0) -- collapsed spans stay so undo can bring them back
  H.check(child, qbuf)
end

T["ggdG deletes every excerpt's lines from the sources and leaves no excerpt"] = function()
  local _, a, b, qbuf = two()
  child.type_keys("gg", "dG")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(A0, 4, 3))
  eq(H.buf_lines(child, b), without(B0, 2, 3))
  eq(#vim.tbl_filter(function(s)
    return s.count > 0
  end, H.spans(child, qbuf)), 0) -- collapsed spans stay so undo can bring them back
  H.check(child, qbuf)
end

T["ggdG then u restores both sources"] = function()
  local _, a, b, qbuf = two()
  child.type_keys("gg", "dG")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["dG from the middle of the last excerpt deletes to its end only"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 4)
  child.type_keys("dG")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), without(B0, 3, 2))
  H.check(child, qbuf)
end

-- Undo across edges ----------------------------------------------------------------

T["dd on the last row of an excerpt then u puts the line back in its own source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("dd")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(A0, 6))
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["dd on the first row of an excerpt, k, then u puts the line back in its own source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 3)
  child.type_keys("dd")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, b), without(B0, 2))
  child.type_keys("k", "u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["dd on a one-row excerpt then u restores that source, not the neighbour"] = function()
  local _, a, b, qbuf = two(0)
  eq(H.quilt_lines(child, qbuf), { "a5", "b3" })
  H.go(child, 0)
  child.type_keys("dd")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(A0, 5))
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  eq(H.quilt_lines(child, qbuf), { "a5", "b3" })
  H.check(child, qbuf)
end

T["J across an edge then u restores both sources"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("J")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 6, "a6 b2"))
  eq(H.buf_lines(child, b), without(B0, 2))
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["Vjd across an edge then u restores both sources"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("V", "j", "d")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(A0, 6))
  eq(H.buf_lines(child, b), without(B0, 2))
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

-- View-only edits and undo -----------------------------------------------------------

T["u after + does not delete lines from the source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 1)
  child.type_keys("+")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 2, 5 } })
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  eq(H.modified(child, H.bufnr(child, a)), false)
  H.check(child, qbuf)
end

T["u after zd does not duplicate lines into a source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 4)
  child.type_keys("zd")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6" })
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  eq(H.modified(child, H.bufnr(child, a)), false)
  eq(H.modified(child, H.bufnr(child, b)), false)
  H.check(child, qbuf)
end

T["u after - does not change the source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 1)
  child.type_keys("-")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 4, 1 } })
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["zd on the only excerpt leaves an empty quilt and the source untouched"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a = fx.paths["a.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 } })
  child.type_keys("zd")
  H.settle(child, qbuf)
  eq(#H.spans(child, qbuf), 0)
  eq(H.buf_lines(child, a), A0)
  H.check(child, qbuf)
end

T["zd on the last excerpt then an edit in the one left"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 5)
  child.type_keys("zd")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6" })
  child.type_keys("o", "tail", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "tail"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["+ at the start and end of a file clamps"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 4), ["b.lua"] = H.lines("b", 4) })
  H.config(child, { context = 2 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 1 }, { b, 4 } })
  eq(H.quilt_lines(child, qbuf), { "a1", "a2", "a3", "b2", "b3", "b4" })
  H.go(child, 0)
  child.type_keys("+")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 0, 4 } })
  H.go(child, 5)
  child.type_keys("+")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, b), { { 0, 4 } })
  eq(H.quilt_lines(child, qbuf), { "a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4" })
  eq(H.modified(child, H.bufnr(child, a)), false)
  H.check(child, qbuf)
end

T["+ merges two excerpts of one file, then an edit at the old seam"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 20) })
  H.config(child, { context = 1 })
  local a = fx.paths["a.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { a, 9 } })
  eq(H.spans_of(child, qbuf, a), { { 3, 3 }, { 7, 3 } })
  H.go(child, 0)
  child.type_keys("+")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 2, 8 } })
  H.go(child, 3)
  child.type_keys("o", "seam", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(H.lines("a", 20), 7, "seam"))
  H.check(child, qbuf)
end

-- Ex commands over many excerpts -----------------------------------------------------

T[":g/pat/d deletes matching lines in every source"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[g/[45]$/d]])
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), without(without(A0, 5), 4))
  eq(H.buf_lines(child, b), without(B0, 4))
  eq(H.quilt_lines(child, qbuf), { "a6", "b2", "b3" })
  H.check(child, qbuf)
end

T[":g/pat/normal Ax appends in every source"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[g/[26]$/normal Ax]])
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 6, "a6x"))
  eq(H.buf_lines(child, b), set(B0, 2, "b2x"))
  H.check(child, qbuf)
end

T[":g/^b2/normal Onew prepends to the excerpt the cursor is on"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 0)
  child.cmd([[g/^b2$/normal Onew]])
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), with(B0, 2, "new"))
  H.check(child, qbuf)
end

T["a macro that moves to the first row of the next excerpt and does O prepends to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 0)
  child.cmd([[let @q = "3jOnew\<Esc>"]])
  child.type_keys("@q")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), with(B0, 2, "new"))
  H.check(child, qbuf)
end

T["a macro that moves up to the last row of an excerpt and does o appends to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 5)
  child.cmd([[let @q = "3konew\<Esc>"]])
  child.type_keys("@q")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "new"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T[":3normal o from another row appends to the excerpt of row 3"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 5)
  child.cmd("3normal onew")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "new"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T[":sort over a range across excerpts keeps line counts per source"] = function()
  local fx = H.setup(child, { ["a.lua"] = { "x", "z", "y", "x" }, ["b.lua"] = { "x", "c", "a", "b", "x" } })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 2 }, { a, 3 }, { b, 2 }, { b, 3 }, { b, 4 } })
  eq(H.quilt_lines(child, qbuf), { "z", "y", "c", "a", "b" })
  child.cmd("%sort")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a", "b", "c", "y", "z" })
  eq(H.buf_lines(child, a), { "x", "a", "b", "x" })
  eq(H.buf_lines(child, b), { "x", "c", "y", "z", "x" })
  H.check(child, qbuf)
end

T[">G over the whole quilt indents every excerpt row in place"] = function()
  local _, a, b, qbuf = two()
  child.bo.shiftwidth, child.bo.expandtab = 2, true
  child.type_keys("gg", ">G")
  H.settle(child, qbuf)
  local wa, wb = vim.deepcopy(A0), vim.deepcopy(B0)
  for i = 4, 6 do
    wa[i] = "  " .. wa[i]
  end
  for i = 2, 4 do
    wb[i] = "  " .. wb[i]
  end
  eq(H.buf_lines(child, a), wa)
  eq(H.buf_lines(child, b), wb)
  H.check(child, qbuf)
end

T["gqj across an edge joins into the first source like J"] = function()
  local _, a, b, qbuf = two()
  child.bo.textwidth = 70
  H.go(child, 2)
  child.type_keys("gqj")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 6, "a6 b2"))
  eq(H.buf_lines(child, b), without(B0, 2))
  H.check(child, qbuf)
end

T["visual block insert across an edge changes each row in its own source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 1)
  child.type_keys("0", "<C-v>", "jjj", "I", "> ", "<Esc>")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "> a5", "> a6", "> b2", "> b3", "b4" })
  eq(H.buf_lines(child, a), set(set(A0, 5, "> a5"), 6, "> a6"))
  eq(H.buf_lines(child, b), set(set(B0, 2, "> b2"), 3, "> b3"))
  H.check(child, qbuf)
end

T[". repeat of A across excerpts"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("A;<Esc>", "j", ".", "j", ".")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 6, "a6;"))
  eq(H.buf_lines(child, b), set(set(B0, 2, "b2;"), 3, "b3;"))
  H.check(child, qbuf)
end

T[". repeat of o across an edge appends each line to the excerpt it was typed under"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("o", "x", "<Esc>", ".")
  H.go(child, 5)
  child.type_keys("O", "y", "<Esc>", ".")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6", "x", "x", "y", "y", "b2", "b3", "b4" })
  eq(H.buf_lines(child, a), with(A0, 7, "x", "x"))
  eq(H.buf_lines(child, b), with(B0, 2, "y", "y"))
  H.check(child, qbuf)
end

-- Paste at edges -------------------------------------------------------------------

T["multi-line p on the last row of an excerpt appends both lines to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 4)
  child.type_keys("yj")
  H.go(child, 2)
  child.type_keys("p")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "b3", "b4"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["multi-line P on the first row of an excerpt prepends both lines to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 0)
  child.type_keys("yj")
  H.go(child, 3)
  child.type_keys("P")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), with(B0, 2, "a4", "a5"))
  H.check(child, qbuf)
end

T["]p on the last row of an excerpt appends to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 4)
  child.type_keys("yy")
  H.go(child, 2)
  child.type_keys("]p")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "b3"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T[":put on the last row of an excerpt appends to it"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.cmd("put ='put1'")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "put1"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T[":read a file on the last row of an excerpt appends it to that source"] = function()
  local fx, a, b, qbuf = two()
  H.go(child, 2)
  child.cmd("read " .. vim.fn.fnameescape(fx.paths["c.lua"]))
  H.settle(child, qbuf)
  local want = vim.deepcopy(A0)
  for i = 10, 1, -1 do
    table.insert(want, 7, C0[i])
  end
  eq(H.buf_lines(child, a), want)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["o / O / p at the very first and last row of the quilt"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 0)
  child.type_keys("O", "top", "<Esc>")
  H.settle(child, qbuf)
  child.type_keys("G", "o", "bottom", "<Esc>")
  H.settle(child, qbuf)
  child.type_keys("gg", "yy", "G", "p")
  H.settle(child, qbuf)
  child.type_keys("gg", "P")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 4, "top", "top"))
  eq(H.buf_lines(child, b), with(B0, 5, "bottom", "top"))
  H.check(child, qbuf)
end

-- Many edits without settling -------------------------------------------------------

T["a 50-step macro with @@ and one settle"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 40), ["b.lua"] = H.lines("b", 40) })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local hits = {}
  for i = 1, 40, 2 do
    hits[#hits + 1] = { a, i }
    hits[#hits + 1] = { b, i }
  end
  local qbuf = H.quilt_qf(child, hits)
  eq(#H.quilt_lines(child, qbuf), 40)
  H.go(child, 0)
  -- Each step: append, duplicate the line, delete the duplicate, go down.
  child.cmd([[let @q = "A.\<Esc>yyp\"_dd"]])
  child.type_keys("@q")
  for _ = 1, 39 do
    child.type_keys("@@")
  end
  H.settle(child, qbuf)
  local wa, wb = H.lines("a", 40), H.lines("b", 40)
  for i = 1, 40, 2 do
    wa[i] = wa[i] .. "."
    wb[i] = wb[i] .. "."
  end
  eq(H.buf_lines(child, a), wa)
  eq(H.buf_lines(child, b), wb)
  H.check(child, qbuf)
end

T["50 :normal edits in one command line then one settle"] = function()
  local _, a, b, qbuf = two()
  local cmds = {}
  for i = 1, 50 do
    cmds[#cmds + 1] = ("%dnormal! A%d"):format((i % 6) + 1, i % 10)
  end
  child.cmd(table.concat(cmds, " | "))
  H.settle(child, qbuf)
  local q = H.quilt_lines(child, qbuf)
  eq(H.buf_lines(child, a), { "a1", "a2", "a3", q[1], q[2], q[3], "a7", "a8", "a9", "a10" })
  eq(H.buf_lines(child, b), { "b1", q[4], q[5], q[6], "b5", "b6", "b7", "b8", "b9", "b10" })
  H.check(child, qbuf)
end

-- Quilt and source both change in one tick ------------------------------------------

T[":windo %s over a source window and the quilt keeps every substitution"] = function()
  local fx = H.setup(child, {
    ["a.lua"] = { "x", "foo a", "x" },
    ["b.lua"] = { "x", "foo b", "x" },
  })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 2 }, { b, 2 } })
  child.cmd("split " .. vim.fn.fnameescape(a))
  -- Source window on top, quilt below: windo visits the source first.
  child.cmd([[windo %s/foo/bar/ge]])
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), { "x", "bar a", "x" })
  eq(H.buf_lines(child, b), { "x", "bar b", "x" })
  eq(H.quilt_lines(child, qbuf), { "bar a", "bar b" })
  H.check(child, qbuf)
end

T["a quilt edit then a source insert above it in the same tick both land in the right rows"] = function()
  local fx, a, b, qbuf = two()
  local _ = fx
  child.cmd("botright split " .. vim.fn.fnameescape(a))
  -- Quilt window on top, source window below: windo visits the quilt first.
  child.cmd([[windo if &ft ==# 'quilt' | exe "normal! 2GA!" | else | exe "normal! ggOtop" | endif]])
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(set(A0, 5, "a5!"), 1, "top"))
  eq(H.buf_lines(child, b), B0)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "a6", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

T["a source change and a quilt edit in one lua call both land"] = function()
  local _, a, b, qbuf = two()
  child.lua(
    [[
    local qbuf, abuf = ...
    vim.api.nvim_buf_set_lines(abuf, 4, 5, true, { "A5" })
    vim.api.nvim_buf_set_lines(qbuf, 4, 5, true, { "B3" })
  ]],
    { qbuf, H.bufnr(child, a) }
  )
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 5, "A5"))
  eq(H.buf_lines(child, b), set(B0, 3, "B3"))
  H.check(child, qbuf)
end

T["editing a source in another window while the quilt has unsettled edits"] = function()
  local _, a, b, qbuf = two()
  child.lua(
    [[
    local qbuf, abuf = ...
    vim.api.nvim_buf_set_lines(qbuf, 1, 2, true, { "a5!" })
    vim.api.nvim_buf_set_lines(abuf, 0, 0, true, { "top" })
  ]],
    { qbuf, H.bufnr(child, a) }
  )
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(set(A0, 5, "a5!"), 1, "top"))
  eq(H.buf_lines(child, b), B0)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "a6", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

-- Two quilts over one file ---------------------------------------------------------

T["two quilts over the same file: an edit in one shows in the other"] = function()
  local _, a, b, q1 = two()
  child.cmd("split")
  local q2 = H.quilt_qf(child, { { a, 5 }, { a, 2 } })
  eq(H.quilt_lines(child, q2), { "a1", "a2", "a3", "a4", "a5", "a6" })
  H.go(child, 4)
  child.type_keys("A!<Esc>", "gg", "Otop<Esc>")
  H.settle(child, q2)
  H.settle(child, q1)
  eq(H.buf_lines(child, a), with(set(A0, 5, "a5!"), 1, "top"))
  eq(H.quilt_lines(child, q1), { "a4", "a5!", "a6", "b2", "b3", "b4" })
  H.check(child, q1)
  H.check(child, q2)
  eq(H.buf_lines(child, b), B0)
end

T["two quilts over the same file edited in one tick by :windo"] = function()
  -- Both quilts change the same excerpt of a.lua in one tick. Merging that needs a three-way line merge. v1
  -- keeps the file's version in the second quilt and says so. See SPEC "How sync works" 9.
  MiniTest.skip("known v1 limit: one excerpt edited by two quilts in the same tick")
  local _, a, b, q1 = two()
  child.cmd("split")
  local q2 = H.quilt_qf(child, { { a, 5 } })
  eq(H.quilt_lines(child, q2), { "a4", "a5", "a6" })
  -- q2 (top) inserts above a4, q1 (bottom) appends to a6.
  child.cmd([[windo exe "normal! ggOtop" | exe "normal! GA!"]])
  H.settle(child, q1)
  H.settle(child, q2)
  -- Both quilts insert "top" above a4. q2 appends "!" to a6, q1 to b4.
  eq(H.buf_lines(child, a), { "a1", "a2", "a3", "top", "top", "a4", "a5", "a6!", "a7", "a8", "a9", "a10" })
  eq(H.buf_lines(child, b), set(B0, 4, "b4!"))
  eq(H.quilt_lines(child, q1), { "top", "a4", "a5", "a6!", "b2", "b3", "b4!" })
  eq(H.quilt_lines(child, q2), { "top", "a4", "a5", "a6!" })
  H.check(child, q1)
  H.check(child, q2)
end

-- LSP style workspace edits ----------------------------------------------------------

T["apply_text_edits over several rows of two sources at once"] = function()
  local _, a, b, qbuf = two()
  child.lua(
    [[
    local abuf, bbuf = ...
    local function e(l1, c1, l2, c2, t)
      return { range = { start = { line = l1, character = c1 }, ["end"] = { line = l2, character = c2 } }, newText = t }
    end
    -- a: rename on rows 0, 4, 5 and insert two lines after row 5; b: join rows 2..3, edit outside the excerpt.
    vim.lsp.util.apply_text_edits({ e(0, 0, 0, 1, "A"), e(4, 0, 4, 1, "A"), e(5, 2, 5, 2, "\nn1\nn2"), e(9, 0, 9, 1, "A") }, abuf, "utf-16")
    vim.lsp.util.apply_text_edits({ e(2, 2, 3, 0, " "), e(8, 0, 8, 0, "z") }, bbuf, "utf-16")
  ]],
    { H.bufnr(child, a), H.bufnr(child, b) }
  )
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), { "A1", "a2", "a3", "a4", "A5", "a6", "n1", "n2", "a7", "a8", "a9", "A10" })
  eq(H.buf_lines(child, b), { "b1", "b2", "b3 b4", "b5", "b6", "b7", "b8", "zb9", "b10" })
  H.check(child, qbuf)
end

-- Writing --------------------------------------------------------------------------

T[":w in the same tick as an edit writes the edit"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[exe "normal! 2GA!" | write]])
  H.settle(child, qbuf)
  eq(H.disk(a), set(A0, 5, "a5!"))
  eq(H.disk(b), B0)
  eq(H.modified(child, qbuf), false)
  H.check(child, qbuf)
end

T["BufWritePre that rewrites the whole file writes it and keeps the quilt in sync"] = function()
  local _, a, b, qbuf = two()
  child.lua([[
    vim.api.nvim_create_autocmd("BufWritePre", {
      pattern = "*/a.lua",
      callback = function(ev)
        local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        for i, l in ipairs(lines) do lines[i] = l:upper() end
        vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, lines)
      end,
    })
  ]])
  H.go(child, 1)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  child.cmd("write")
  H.settle(child, qbuf)
  local want = {}
  for i, l in ipairs(set(A0, 5, "a5!")) do
    want[i] = l:upper()
  end
  eq(H.disk(a), want)
  eq(H.modified(child, H.bufnr(child, a)), false)
  eq(H.modified(child, qbuf), false)
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T[":w with a BufWritePre that deletes lines above an excerpt"] = function()
  local _, a, _, qbuf = two()
  child.lua([[
    vim.api.nvim_create_autocmd("BufWritePre", {
      pattern = "*/a.lua",
      callback = function(ev) vim.api.nvim_buf_set_lines(ev.buf, 0, 2, false, {}) end,
    })
  ]])
  H.go(child, 1)
  child.type_keys("A!<Esc>")
  child.cmd("write")
  H.settle(child, qbuf)
  eq(H.disk(a), without(set(A0, 5, "a5!"), 1, 2))
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "a6", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

-- Sources going away ----------------------------------------------------------------

T[":bd on a source removes its excerpts and leaves the rest working"] = function()
  local _, a, b, qbuf = two()
  child.cmd("bdelete " .. H.bufnr(child, b))
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6" })
  H.go(child, 2)
  child.type_keys("o", "x", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "x"))
  H.check(child, qbuf)
end

T[":bd on a source then u in the quilt does not push its lines into another source"] = function()
  local _, a, b, qbuf = two()
  child.cmd("bdelete " .. H.bufnr(child, b))
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6" })
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  H.check(child, qbuf)
end

T[":bw on a source removes its excerpts"] = function()
  local _, a, b, qbuf = two()
  child.cmd("bwipeout " .. H.bufnr(child, b))
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6" })
  H.check(child, qbuf)
  eq(H.buf_lines(child, a), A0)
end

T[":e! on a source with a shorter file on disk while the quilt has unsettled edits"] = function()
  local fx, a, b, qbuf = two()
  local _ = fx
  vim.fn.writefile(H.lines("A", 3), a)
  child.cmd("botright split " .. vim.fn.fnameescape(b))
  child.cmd("wincmd t")
  child.cmd([[exe "normal! 5GA!" | exe "sbuffer " .. ]] .. H.bufnr(child, a) .. [[ | edit! | close]])
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, b), set(B0, 3, "b3!"))
  eq(H.buf_lines(child, a), H.lines("A", 3))
  H.check(child, qbuf)
end

T[":e! on a source after it grew on disk rereads the excerpt"] = function()
  local _, a, _, qbuf = two()
  vim.fn.writefile(vim.list_extend(H.lines("A", 10), H.lines("Z", 5)), a)
  child.cmd("split " .. vim.fn.fnameescape(a))
  child.cmd("edit!")
  child.cmd("close")
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "A4", "A5", "A6", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

-- Odd files ------------------------------------------------------------------------

T["a CRLF file keeps its line endings on :w"] = function()
  local dir = H.setup(child, { ["b.lua"] = H.lines("b", 3) })
  local a = dir.dir .. "/a.lua"
  local f = assert(io.open(a, "wb"))
  f:write("a1\r\na2\r\na3\r\n")
  f:close()
  H.config(child, { context = 0 })
  local qbuf = H.quilt_qf(child, { { a, 2 }, { dir.paths["b.lua"], 2 } })
  eq(H.quilt_lines(child, qbuf), { "a2", "b2" })
  H.go(child, 0)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  child.cmd("write")
  local fh = assert(io.open(a, "rb"))
  local data = fh:read("*a")
  fh:close()
  eq(data, "a1\r\na2!\r\na3\r\n")
  H.check(child, qbuf)
end

T["a file with no trailing newline round-trips through the quilt"] = function()
  local dir = H.setup(child, { ["b.lua"] = H.lines("b", 3) })
  local a = dir.dir .. "/a.lua"
  local f = assert(io.open(a, "wb"))
  f:write("a1\na2\na3")
  f:close()
  H.config(child, { context = 0 })
  local qbuf = H.quilt_qf(child, { { a, 3 }, { dir.paths["b.lua"], 2 } })
  eq(H.quilt_lines(child, qbuf), { "a3", "b2" })
  H.go(child, 0)
  child.type_keys("o", "a4", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), { "a1", "a2", "a3", "a4" })
  H.check(child, qbuf)
end

T["an empty file in the quickfix list"] = function()
  local fx = H.setup(child, { ["e.lua"] = {}, ["b.lua"] = H.lines("b", 3) })
  H.config(child, { context = 1 })
  local e, b = fx.paths["e.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { e, 1 }, { b, 2 } })
  eq(H.quilt_lines(child, qbuf), { "", "b1", "b2", "b3" })
  H.go(child, 0)
  child.type_keys("i", "hello", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, e), { "hello" })
  eq(H.buf_lines(child, b), H.lines("b", 3))
  H.check(child, qbuf)
end

T["a very long line and multibyte text"] = function()
  local long = string.rep("é字🙂x", 3000)
  local fx = H.setup(child, { ["a.lua"] = { "α", long, "ω" }, ["b.lua"] = { "ü1", "ü2" } })
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 2 }, { b, 1 } })
  eq(H.quilt_lines(child, qbuf), { "α", long, "ω", "ü1", "ü2" })
  H.go(child, 1)
  child.type_keys("$", "a", "末", "<Esc>", "0", "x")
  H.go(child, 3)
  child.type_keys("A", "字<CR>新", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), { "α", long:sub(#"é" + 1) .. "末", "ω" })
  eq(H.buf_lines(child, b), { "ü1字", "新", "ü2" })
  H.check(child, qbuf)
end

T["zd on the only excerpt then u keeps quilt and model in sync without touching the source"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a = fx.paths["a.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 } })
  child.type_keys("zd")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  H.check(child, qbuf)
end

-- More undo / redo and cursor-preference cases -------------------------------------

T["o on the last row of an excerpt, u, <C-r> appends to that source again"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("o", "new", "<Esc>")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  child.type_keys("<C-r>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "new"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["O on the first row of an excerpt, u, <C-r> prepends to that source again"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 3)
  child.type_keys("O", "new", "<Esc>")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, b), B0)
  child.type_keys("<C-r>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), with(B0, 2, "new"))
  H.check(child, qbuf)
end

T["o in one window of a quilt shown in two windows uses that window's cursor"] = function()
  local _, a, b, qbuf = two()
  child.cmd("split")
  H.go(child, 2)
  child.cmd("wincmd j")
  H.go(child, 4)
  child.cmd("wincmd k")
  eq(H.cursor_row(child), 2)
  child.type_keys("o", "new", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "new"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["A<CR> at the end of an excerpt's last row adds lines to that source"] = function()
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.type_keys("A", "<CR>", "n1", "<CR>", "n2", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(A0, 7, "n1", "n2"))
  eq(H.buf_lines(child, b), B0)
  H.check(child, qbuf)
end

T["<BS> at the start of an excerpt joins into the source above like J"] = function()
  local _, a, b, qbuf = two()
  child.o.backspace = "indent,eol,start"
  H.go(child, 3)
  child.type_keys("I", "<BS>", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(A0, 6, "a6b2"))
  eq(H.buf_lines(child, b), without(B0, 2))
  H.check(child, qbuf)
end

T[":m +1 on the last row of an excerpt moves the line into the next excerpt's source"] = function()
  -- Neovim moves extmarks along with the text `:m` moves, so the excerpt edge travels with the line. The quilt
  -- shows that honestly and `:w` writes what it shows. See README "Edits at excerpt edges".
  MiniTest.skip("known v1 limit: :m across an excerpt edge carries the edge with the line")
  local _, a, b, qbuf = two()
  H.go(child, 2)
  child.cmd("move +1")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "b2", "a6", "b3", "b4" })
  eq(H.buf_lines(child, a), without(A0, 6))
  eq(H.buf_lines(child, b), with(B0, 3, "a6"))
  H.check(child, qbuf)
end

T[":Quilt refresh then u does not touch the sources"] = function()
  local _, a, b, qbuf = two()
  child.cmd("Quilt refresh")
  H.settle(child, qbuf)
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), A0)
  eq(H.buf_lines(child, b), B0)
  eq(H.modified(child, H.bufnr(child, a)), false)
  eq(H.modified(child, H.bufnr(child, b)), false)
  H.check(child, qbuf)
end

T["a change in another window's source then u in the quilt"] = function()
  local _, a, _, qbuf = two()
  H.go(child, 1)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  child.api.nvim_buf_set_lines(H.bufnr(child, a), 4, 5, true, { "outside" })
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf)[2], "outside")
  child.type_keys("u")
  H.settle(child, qbuf)
  H.check(child, qbuf)
end

T["ggVGJ over the whole quilt joins into the first source and removes the rest"] = function()
  local _, a, b, qbuf = two()
  child.type_keys("gg", "V", "G", "J")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4 a5 a6 b2 b3 b4" })
  eq(H.buf_lines(child, a), { "a1", "a2", "a3", "a4 a5 a6 b2 b3 b4", "a7", "a8", "a9", "a10" })
  eq(H.buf_lines(child, b), without(B0, 2, 3))
  H.check(child, qbuf)
end

T[":%s/\\n// over the whole quilt joins into the first source and removes the rest"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[%s/\n//]])
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4a5a6b2b3b4" })
  eq(H.buf_lines(child, a), { "a1", "a2", "a3", "a4a5a6b2b3b4", "a7", "a8", "a9", "a10" })
  eq(H.buf_lines(child, b), without(B0, 2, 3))
  H.check(child, qbuf)
end

T[":g/^/m0 reverses the quilt and keeps it in sync"] = function()
  local _, a, b, qbuf = two()
  child.cmd([[g/^/m0]])
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "b4", "b3", "b2", "a6", "a5", "a4" })
  eq(#H.buf_lines(child, a) + #H.buf_lines(child, b), 20)
  H.check(child, qbuf)
end

return T
