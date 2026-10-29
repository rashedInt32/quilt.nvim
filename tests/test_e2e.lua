-- End to end: a child Neovim drives real quilts over real files with real keys.
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

-- Three files of 10 lines each: a1..a10, b1..b10, c1..c10.
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

local function without(lines, at)
  local out = vim.deepcopy(lines)
  table.remove(out, at)
  return out
end

local function set(lines, at, value)
  local out = vim.deepcopy(lines)
  out[at] = value
  return out
end

T[":Quilt from a quickfix list shows the right lines and headers"] = function()
  local fx = H.setup(child, { ["src/a.lua"] = H.lines("a", 10), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 1 })
  local qbuf = H.quilt_qf(child, { { fx.paths["src/a.lua"], 5 }, { fx.paths["b.lua"], 3 } })

  eq(H.quilt_lines(child, qbuf), { "a4", "a5", "a6", "b2", "b3", "b4" })
  eq(child.api.nvim_buf_get_name(qbuf):match("^quilt://%d+/") ~= nil, true)
  local function opt(name)
    return child.api.nvim_get_option_value(name, { buf = qbuf })
  end
  eq({ opt("buftype"), opt("filetype"), opt("swapfile") }, { "acwrite", "quilt", false })

  child.type_keys("gg")
  local rows = H.screen_rows(child)
  local function find(pat)
    for i, row in ipairs(rows) do
      if row:find(pat) then
        return i
      end
    end
  end
  local a4, a6, b2 = find("a4%s*$"), find("a6%s*$"), find("b2%s*$")
  eq(a4 ~= nil and a6 ~= nil and b2 ~= nil, true)

  local head_a = table.concat(rows, "\n", 1, a4 - 1)
  eq(rows[1]:find("src/a.lua", 1, true) ~= nil, true)
  eq(head_a:find("src/a%.lua.-:4") ~= nil, true)
  eq(head_a:find(fx.dir, 1, true), nil)

  local b_path = find("b%.lua")
  eq(b_path ~= nil and b_path > a6 + 1 and b_path < b2, true)
  eq(table.concat(rows, "\n", b_path, b2 - 1):find("b%.lua.-:2") ~= nil, true)

  eq(rows[a4]:sub(1, rows[a4]:find("a4%s*$") - 1):find("%f[%d]4%f[%D]") ~= nil, true)
  eq(rows[b2]:sub(1, rows[b2]:find("b2%s*$") - 1):find("%f[%d]2%f[%D]") ~= nil, true)
  H.check(child, qbuf)
end

T["typing in an excerpt changes the source buffer, not the file"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 1)
  child.type_keys("A", " one<CR>two", "<Esc>")
  H.settle(child, qbuf)

  local want = with(set(H.lines("a", 10), 5, "a5 one"), 6, "two")
  eq(H.buf_lines(child, a), want)
  eq(H.disk(a), H.lines("a", 10))
  eq(H.modified(child, H.bufnr(child, a)), true)
  eq(H.buf_lines(child, b), H.lines("b", 10))
  eq(H.quilt_lines(child, qbuf), { "a4", "a5 one", "two", "a6", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

T["o on the last row of an excerpt appends to that source"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 2)
  child.type_keys("o", "new", "<Esc>")
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), with(H.lines("a", 10), 7, "new"))
  eq(H.buf_lines(child, b), H.lines("b", 10))
  eq(H.spans_of(child, qbuf, a), { { 3, 4 } })
  eq(H.spans_of(child, qbuf, b), { { 1, 3 } })
  H.check(child, qbuf)
end

T["O on the first row of the next excerpt prepends to that source"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 3)
  child.type_keys("O", "new", "<Esc>")
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), H.lines("a", 10))
  eq(H.buf_lines(child, b), with(H.lines("b", 10), 2, "new"))
  eq(H.spans_of(child, qbuf, a), { { 3, 3 } })
  eq(H.spans_of(child, qbuf, b), { { 1, 4 } })
  H.check(child, qbuf)
end

T["p on the last row of an excerpt appends to that source"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 0)
  child.type_keys("yy")
  H.go(child, 2)
  child.type_keys("p")
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), with(H.lines("a", 10), 7, "a4"))
  eq(H.buf_lines(child, b), H.lines("b", 10))
  eq(H.spans_of(child, qbuf, a), { { 3, 4 } })
  H.check(child, qbuf)
end

T["P on the first row of the next excerpt prepends to that source"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 0)
  child.type_keys("yy")
  H.go(child, 3)
  child.type_keys("P")
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), H.lines("a", 10))
  eq(H.buf_lines(child, b), with(H.lines("b", 10), 2, "a4"))
  eq(H.spans_of(child, qbuf, b), { { 1, 4 } })
  H.check(child, qbuf)
end

T["dd on the only row of an excerpt deletes the source row and the excerpt"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 3 }, { a, 8 }, { b, 2 } })
  eq(H.quilt_lines(child, qbuf), { "a3", "a8", "b2" })

  H.go(child, 0)
  child.type_keys("dd")
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), without(H.lines("a", 10), 3))
  eq(H.disk(a), H.lines("a", 10))
  eq(H.quilt_lines(child, qbuf), { "a8", "b2" })
  eq(H.spans_of(child, qbuf, a), { { 6, 1 } })
  eq(#vim.tbl_filter(function(s)
    return s.count > 0
  end, H.spans(child, qbuf)), 2)
  H.check(child, qbuf)
end

T["J across two excerpts joins into the first source and removes the line from the second"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  H.go(child, 0)
  child.type_keys("J")
  H.settle(child, qbuf)

  eq(H.quilt_lines(child, qbuf), { "a5 b3" })
  eq(H.buf_lines(child, a), set(H.lines("a", 10), 5, "a5 b3"))
  eq(H.buf_lines(child, b), without(H.lines("b", 10), 3))
  eq(H.spans_of(child, qbuf, a), { { 4, 1 } })
  eq(H.spans_of(child, qbuf, b), {})
  H.check(child, qbuf)
end

T[":%s/foo/bar/g changes every excerpt and nothing outside them"] = function()
  local a_lines = { "x", "foo one", "x", "x", "foo outside", "x", "x", "foo two foo", "x" }
  local b_lines = { "x", "x", "x", "y foo foo", "x" }
  local fx = H.setup(child, { ["a.lua"] = a_lines, ["b.lua"] = b_lines })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 2 }, { a, 8 }, { b, 4 } })

  child.cmd("%s/foo/bar/g")
  H.settle(child, qbuf)

  eq(H.quilt_lines(child, qbuf), { "bar one", "bar two bar", "y bar bar" })
  eq(H.buf_lines(child, a), { "x", "bar one", "x", "x", "foo outside", "x", "x", "bar two bar", "x" })
  eq(H.buf_lines(child, b), { "x", "x", "x", "y bar bar", "x" })
  H.check(child, qbuf)
end

T["a macro over several excerpts edits every source"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 3 }, { a, 8 }, { b, 4 } })

  H.go(child, 0)
  child.type_keys("qa", "A;<Esc>j", "q")
  child.type_keys("2@a")
  H.settle(child, qbuf)

  eq(H.quilt_lines(child, qbuf), { "a3;", "a8;", "b4;" })
  eq(H.buf_lines(child, a), set(set(H.lines("a", 10), 3, "a3;"), 8, "a8;"))
  eq(H.buf_lines(child, b), set(H.lines("b", 10), 4, "b4;"))
  H.check(child, qbuf)
end

T["u and <C-r> flow to the sources"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })
  local a0, b0 = H.lines("a", 10), H.lines("b", 10)

  H.go(child, 0)
  child.type_keys("A!<Esc>")
  H.go(child, 1)
  child.type_keys("A?<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(a0, 5, "a5!"))
  eq(H.buf_lines(child, b), set(b0, 3, "b3?"))

  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(a0, 5, "a5!"))
  eq(H.buf_lines(child, b), b0)
  H.check(child, qbuf)

  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), a0)
  eq(H.buf_lines(child, b), b0)
  H.check(child, qbuf)

  child.type_keys("<C-r>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(a0, 5, "a5!"))
  eq(H.buf_lines(child, b), b0)

  child.type_keys("<C-r>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(a0, 5, "a5!"))
  eq(H.buf_lines(child, b), set(b0, 3, "b3?"))
  H.check(child, qbuf)

  H.go(child, 0)
  child.type_keys("o", "extra", "<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), with(set(a0, 5, "a5!"), 6, "extra"))
  child.type_keys("u")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(a0, 5, "a5!"))
  eq(H.spans_of(child, qbuf, a), { { 4, 1 } })
  H.check(child, qbuf)
end

T["editing a source in another window updates the quilt"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  child.cmd("split " .. vim.fn.fnameescape(a))
  eq(child.api.nvim_get_current_buf(), H.bufnr(child, a))

  child.type_keys("5G", "A!<Esc>")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "a6", "b2", "b3", "b4" })

  child.type_keys("gg", "Otop<Esc>")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 4, 3 } })
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "a6", "b2", "b3", "b4" })

  child.type_keys("7G", "dd")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 4, 2 } })
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "b2", "b3", "b4" })

  child.type_keys("10G", "Afar<Esc>")
  H.settle(child, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a4", "a5!", "b2", "b3", "b4" })
  H.check(child, qbuf)
end

T["a source change that touches an excerpt edge grows the excerpt"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 5 } })
  local abuf, bbuf = H.bufnr(child, a), H.bufnr(child, b)

  child.api.nvim_buf_set_lines(abuf, 3, 5, true, { "x", "y", "z" })
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 3, 3 } })
  eq(H.quilt_lines(child, qbuf), { "x", "y", "z", "b5" })

  child.api.nvim_buf_set_lines(bbuf, 4, 6, true, { "p", "q", "r" })
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, b), { { 4, 3 } })
  eq(H.quilt_lines(child, qbuf), { "x", "y", "z", "p", "q", "r" })
  H.check(child, qbuf)
end

T["a source insert at an excerpt's first row shifts it and one after its last row stays outside"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a = fx.paths["a.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { fx.paths["b.lua"], 5 } })
  local abuf = H.bufnr(child, a)

  child.api.nvim_buf_set_lines(abuf, 4, 4, true, { "before" })
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 5, 1 } })

  child.api.nvim_buf_set_lines(abuf, 6, 6, true, { "after" })
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 5, 1 } })
  eq(H.quilt_lines(child, qbuf), { "a5", "b5" })
  H.check(child, qbuf)
end

T[":w writes every changed file to disk and clears modified"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b, c = fx.paths["a.lua"], fx.paths["b.lua"], fx.paths["c.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 }, { c, 2 } })
  child.lua([[
    _G.written = {}
    vim.api.nvim_create_autocmd("BufWritePost", {
      callback = function(ev) table.insert(_G.written, vim.fn.fnamemodify(ev.file, ":t")) end,
    })
  ]])

  H.go(child, 0)
  child.type_keys("A!<Esc>")
  H.go(child, 1)
  child.type_keys("A?<Esc>")
  H.settle(child, qbuf)
  eq(H.modified(child, qbuf), true)

  child.cmd("write")
  H.settle(child, qbuf)

  eq(H.disk(a), set(H.lines("a", 10), 5, "a5!"))
  eq(H.disk(b), set(H.lines("b", 10), 3, "b3?"))
  eq(H.disk(c), H.lines("c", 10))
  eq(
    child.lua_get("(function() local w = vim.deepcopy(_G.written) table.sort(w) return w end)()"),
    { "a.lua", "b.lua" }
  )
  eq(H.modified(child, H.bufnr(child, a)), false)
  eq(H.modified(child, H.bufnr(child, b)), false)
  eq(H.modified(child, qbuf), false)
  H.check(child, qbuf)
end

T["format-on-save style BufWritePre on a source flows back into the quilt"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })
  child.lua([[
    vim.api.nvim_create_autocmd("BufWritePre", {
      pattern = "*/a.lua",
      callback = function(ev)
        for i, l in ipairs(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)) do
          if l:upper() ~= l then vim.api.nvim_buf_set_lines(ev.buf, i - 1, i, true, { l:upper() }) end
        end
      end,
    })
  ]])

  H.go(child, 0)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  child.cmd("write")
  H.settle(child, qbuf)

  local want = {}
  for i, l in ipairs(set(H.lines("a", 10), 5, "a5!")) do
    want[i] = l:upper()
  end
  eq(H.disk(a), want)
  eq(H.buf_lines(child, a), want)
  eq(H.quilt_lines(child, qbuf), { "A5!", "b3" })
  eq(H.modified(child, H.bufnr(child, a)), false)
  H.check(child, qbuf)
end

T["+ / - / zd change the quilt and never the source"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 20), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 1 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 10 }, { b, 5 } })
  eq(H.spans_of(child, qbuf, a), { { 8, 3 } })

  H.go(child, 1)
  child.type_keys("+")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 7, 5 } })
  eq(H.quilt_lines(child, qbuf), { "a8", "a9", "a10", "a11", "a12", "b4", "b5", "b6" })
  H.check(child, qbuf)

  H.go(child, 0)
  child.type_keys("-")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 8, 3 } })

  H.go(child, 0)
  child.type_keys("-")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 9, 1 } })

  H.go(child, 0)
  child.type_keys("-")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), { { 9, 1 } })
  H.check(child, qbuf)

  H.go(child, 0)
  child.type_keys("zd")
  H.settle(child, qbuf)
  eq(H.spans_of(child, qbuf, a), {})
  eq(H.quilt_lines(child, qbuf), { "b4", "b5", "b6" })

  eq(H.buf_lines(child, a), H.lines("a", 20))
  eq(H.buf_lines(child, b), H.lines("b", 10))
  eq(H.modified(child, H.bufnr(child, a)), false)
  eq(H.modified(child, H.bufnr(child, b)), false)
  H.check(child, qbuf)
end

T["]] and [[ move between excerpts"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local qbuf = H.quilt_qf(child, { { fx.paths["a.lua"], 5 }, { fx.paths["b.lua"], 5 }, { fx.paths["c.lua"], 5 } })

  H.go(child, 1)
  child.type_keys("]]")
  eq(H.cursor_row(child), 3)
  child.type_keys("]]")
  eq(H.cursor_row(child), 6)
  child.type_keys("[[")
  eq(H.cursor_row(child), 3)
  child.type_keys("[[")
  eq(H.cursor_row(child), 0)
  H.check(child, qbuf)
end

T["<CR> opens the source at the right line"] = function()
  local fx = abc()
  H.config(child, { context = 1 })
  local b = fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { fx.paths["a.lua"], 5 }, { b, 7 } })

  H.go(child, 4)
  child.type_keys("<CR>")

  eq(child.api.nvim_get_current_buf(), H.bufnr(child, b))
  eq(child.api.nvim_win_get_cursor(0)[1], 7)
  H.check(child, qbuf)
end

T[":e! on a source after an outside change on disk clamps and rereads"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 20), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { a, 18 }, { b, 3 } })
  eq(H.quilt_lines(child, qbuf), { "a5", "a18", "b3" })

  vim.fn.writefile(H.lines("A", 10), a)
  child.cmd("split " .. vim.fn.fnameescape(a))
  child.cmd("edit!")
  child.cmd("close")
  H.settle(child, qbuf)

  eq(H.spans_of(child, qbuf, a), { { 4, 1 } })
  eq(H.quilt_lines(child, qbuf), { "A5", "b3" })
  H.check(child, qbuf)

  H.go(child, 0)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  eq(H.buf_lines(child, a), set(H.lines("A", 10), 5, "A5!"))
  H.check(child, qbuf)
end

T[":checktime reload of a source after an outside change on disk clamps and rereads"] = function()
  local fx = H.setup(child, { ["a.lua"] = H.lines("a", 20), ["b.lua"] = H.lines("b", 10) })
  H.config(child, { context = 0 })
  local a = fx.paths["a.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { a, 18 }, { fx.paths["b.lua"], 3 } })

  vim.fn.writefile(H.lines("A", 10), a)
  local t = os.time() + 10
  vim.uv.fs_utime(a, t, t)
  child.o.autoread = true
  child.cmd("checktime " .. H.bufnr(child, a))
  H.settle(child, qbuf)

  eq(H.buf_lines(child, a), H.lines("A", 10))
  eq(H.spans_of(child, qbuf, a), { { 4, 1 } })
  eq(H.quilt_lines(child, qbuf), { "A5", "b3" })
  H.check(child, qbuf)
end

T["rename through the fake LSP updates the source and the quilt"] = function()
  local a_lines = set(set(H.lines("a", 10), 5, "local foo = 1"), 9, "foo()")
  local b_lines = set(H.lines("b", 10), 3, "print(foo)")
  local fx = H.setup(child, { ["a.lua"] = a_lines, ["b.lua"] = b_lines })
  H.config(child, { context = 0 })
  local a, b = fx.paths["a.lua"], fx.paths["b.lua"]
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 } })

  child.lua(
    [[
    local fake, a, b, abuf = ...
    local function edit(row, col)
      return { range = { start = { line = row, character = col }, ["end"] = { line = row, character = col + 3 } },
        newText = "renamed" }
    end
    _G.server = dofile(fake).start(abuf, {
      handlers = {
        ["textDocument/rename"] = function()
          local changes = {}
          changes[vim.uri_from_fname(a)] = { edit(4, 6), edit(8, 0) }
          changes[vim.uri_from_fname(b)] = { edit(2, 6) }
          return { changes = changes }
        end,
      },
    })
    vim.ui.input = function(_, cb) cb("renamed") end
  ]],
    { H.root .. "/tests/helpers/fake_lsp.lua", a, b, H.bufnr(child, a) }
  )

  H.go(child, 0)
  child.type_keys("06l", "grn")
  child.lua("vim.wait(1000, function() return #_G.server:calls('textDocument/rename') > 0 end, 5)")
  child.lua("vim.wait(50)")
  H.settle(child, qbuf)

  local req = child.lua_get("_G.server:calls('textDocument/rename')[1].params")
  eq(req.textDocument.uri, vim.uri_from_fname(a))
  eq(req.position, { line = 4, character = 6 })
  eq(req.newName, "renamed")
  eq(H.buf_lines(child, a), set(set(H.lines("a", 10), 5, "local renamed = 1"), 9, "renamed()"))
  eq(H.buf_lines(child, b), set(H.lines("b", 10), 3, "print(renamed)"))
  eq(H.quilt_lines(child, qbuf), { "local renamed = 1", "print(renamed)" })
  H.check(child, qbuf)
end

T["wiping the quilt detaches and unloads buffers it loaded"] = function()
  local fx = abc()
  H.config(child, { context = 0 })
  local a, b, c = fx.paths["a.lua"], fx.paths["b.lua"], fx.paths["c.lua"]
  child.cmd("edit " .. vim.fn.fnameescape(b))
  local qbuf = H.quilt_qf(child, { { a, 5 }, { b, 3 }, { c, 2 } })
  local abuf, bbuf, cbuf = H.bufnr(child, a), H.bufnr(child, b), H.bufnr(child, c)
  eq({ child.fn.bufloaded(abuf), child.fn.bufloaded(bbuf), child.fn.bufloaded(cbuf) }, { 1, 1, 1 })

  H.go(child, 2)
  child.type_keys("A!<Esc>")
  H.settle(child, qbuf)
  H.check(child, qbuf)

  child.cmd("bwipeout! " .. qbuf)
  local unloaded =
    child.lua("local buf = ... return vim.wait(1000, function() return vim.fn.bufloaded(buf) == 0 end, 5)", { abuf })
  eq(unloaded, true)
  eq(child.fn.bufloaded(bbuf), 1)
  eq(child.fn.bufloaded(cbuf), 1)
  eq(H.buf_lines(child, c), set(H.lines("c", 10), 2, "c2!"))
  eq(child.lua_get("require('quilt.buffer').get(...) == nil", { qbuf }), true)

  child.v.errmsg = ""
  child.api.nvim_buf_set_lines(bbuf, 0, 1, true, { "changed" })
  child.api.nvim_buf_set_lines(cbuf, 0, 0, true, { "added" })
  child.lua("vim.wait(50)")
  eq(child.v.errmsg, "")
  eq(H.buf_lines(child, b), set(H.lines("b", 10), 1, "changed"))
end

return T
