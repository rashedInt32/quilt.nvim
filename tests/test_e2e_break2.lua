-- End to end, adversarial round 2. Every test checks PROVENANCE as well as the sync oracle: fixture lines name
-- their file ("a:3 l"), the edits keep that tag on every line they make, and every line of file F must still
-- start with "F:". The random walks also replay each step in a plain mirror buffer: a quilt is just a buffer, so
-- its text must match what Neovim does to a plain buffer with the same keys.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers/e2e.lua")
local eq = MiniTest.expect.equality

local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.restart(child)
      child.o.backspace = "indent,eol,start"
      -- Collect notices instead of showing them: a hit-enter prompt would block the child, and a notice in a
      -- plain editing session means the sync gave up somewhere.
      child.lua([[
        _G.notes = {}
        vim.notify = function(msg) table.insert(_G.notes, msg) end
        vim.cmd([=[
          function! Tg(l)
            return matchstr(getline(a:l), '^\a')
          endfunction
        ]=])
      ]])
    end,
    post_case = H.cleanup,
    post_once = child.stop,
  },
})

-- Helpers ----------------------------------------------------------------------------

-- { "a:1 l", "a:2 l", ... }: every line names its file.
local function tagged(tag, n)
  local out = {}
  for i = 1, n do
    out[i] = ("%s:%d l"):format(tag, i)
  end
  return out
end

-- Files named "{tag}.txt" ("{tag}_up.txt" for upper case tags: macOS file names ignore case), n lines each.
-- Returns fx with fx.tags = { tag = path }.
local function fname(tag)
  return tag .. (tag:match("%u") and "_up" or "") .. ".txt"
end

local function files(spec)
  local f = {}
  for tag, n in pairs(spec) do
    f[fname(tag)] = type(n) == "table" and n or tagged(tag, n)
  end
  local fx = H.setup(child, f)
  fx.tags = {}
  for tag in pairs(spec) do
    fx.tags[tag] = fx.paths[fname(tag)]
  end
  return fx
end

-- Every line in file F's buffer starts with "F:".
local function provenance(fx, ctx)
  local errs = {}
  for tag, path in pairs(fx.tags) do
    for i, l in ipairs(H.buf_lines(child, path)) do
      if l:sub(1, #tag + 1) ~= tag .. ":" then
        errs[#errs + 1] = ("%s.txt:%d holds %q"):format(tag, i, l)
      end
    end
  end
  if #errs > 0 then
    error((ctx and (ctx .. "\n") or "") .. "provenance broken:\n  " .. table.concat(errs, "\n  "), 2)
  end
end

local function notes()
  return child.lua_get("_G.notes")
end

-- Rows of each source not shown by any excerpt. A quilt-only editing session must never touch them.
local function hidden(qbuf)
  return child.lua(
    [[
    local qbuf = ...
    local st = require("quilt.buffer").get(qbuf)
    local shown, out = {}, {}
    for _, s in ipairs(st.model:spans()) do
      shown[s.src] = shown[s.src] or {}
      for r = s.src_start, s.src_start + s.count - 1 do shown[s.src][r] = true end
    end
    for src in pairs(shown) do
      local rows = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(src, 0, -1, false)) do
        if not shown[src][i - 1] then rows[#rows + 1] = l end
      end
      out[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":t")] = rows
    end
    return out
  ]],
    { qbuf }
  )
end

local function all_checks(fx, qbuf, ctx)
  H.settle(child, qbuf)
  local ok, err = pcall(H.check, child, qbuf)
  if not ok then
    error((ctx or "") .. "\n" .. tostring(err), 2)
  end
  provenance(fx, ctx)
end

local function keys(...)
  child.type_keys(...)
end

-- A hit list { {tag, lnum}, ... } -> quilt.
local function quilt(fx, hits, ctx)
  H.config(child, { context = ctx or 1 })
  local list = {}
  for i, h in ipairs(hits) do
    list[i] = { fx.tags[h[1]], h[2] }
  end
  return H.quilt_qf(child, list)
end

local function src(fx, tag)
  return H.buf_lines(child, fx.tags[tag])
end

-- Edges ------------------------------------------------------------------------------

-- a:4 a:5 a:6 | b:2 b:3 b:4 | c:5 c:6 c:7
local function three()
  local fx = files({ a = 10, b = 10, c = 10 })
  local qbuf = quilt(fx, { { "a", 5 }, { "b", 3 }, { "c", 6 } })
  return fx, qbuf
end

T["edges"] = MiniTest.new_set()

T["edges"]["3o on the last row of an excerpt, text typed later, puts every copy in that file"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("3o")
  keys("<C-r>=Tg(line('.')-1)<CR>:n")
  keys("<Esc>")
  all_checks(fx, qbuf)
  eq(#src(fx, "a"), 13)
  eq(src(fx, "b"), tagged("b", 10))
end

T["edges"]["3o typed in one go on the last row of an excerpt puts every copy in that file"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("3o<C-r>=Tg(line('.')-1)<CR>:n<Esc>")
  all_checks(fx, qbuf)
  eq(#src(fx, "a"), 13)
end

T["edges"]["2O on the first row of an excerpt puts both lines in that file"] = function()
  local fx, qbuf = three()
  H.go(child, 3)
  keys("2O")
  keys("<C-r>=Tg(line('.')+1)<CR>:n")
  keys("<Esc>")
  all_checks(fx, qbuf)
  eq(#src(fx, "b"), 12)
end

T["edges"]["a macro kyyp from the first row of the next excerpt duplicates into the file above"] = function()
  -- CursorMoved does not fire inside a macro, so the cursor row the flush sees is from before `k`.
  local fx, qbuf = three()
  H.go(child, 3)
  child.cmd([[let @q = "kyyp"]])
  keys("@q")
  all_checks(fx, qbuf)
  eq(
    src(fx, "a"),
    { "a:1 l", "a:2 l", "a:3 l", "a:4 l", "a:5 l", "a:6 l", "a:6 l", "a:7 l", "a:8 l", "a:9 l", "a:10 l" }
  )
end

T["edges"][":normal! kyyp from the first row of the next excerpt duplicates into the file above"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("known v1 limit: a put at an edge inside :normal! can join the excerpt below")
  local fx, qbuf = three()
  H.go(child, 3)
  child.cmd("normal! kyyp")
  all_checks(fx, qbuf)
  eq(#src(fx, "a"), 11)
end

T["edges"]["yyp then an edit on the row above in one command keeps the copy in its file"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  child.cmd("normal! yypkA!")
  all_checks(fx, qbuf)
  eq(src(fx, "b"), tagged("b", 10))
end

T["edges"]["yyp on the last row twice in one command keeps both copies in that file"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("known v1 limit: a put at an edge inside :normal! can join the excerpt below")
  local fx, qbuf = three()
  H.go(child, 2)
  child.cmd("normal! yypyyp")
  all_checks(fx, qbuf)
  eq(#src(fx, "a"), 12)
end

T["edges"]["ddP on the last row of an excerpt is a no-op"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("decided: P puts above the cursor line, which is the next excerpt after dd")
  local fx, qbuf = three()
  H.go(child, 2)
  keys("dd")
  keys("P")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), tagged("a", 10))
  eq(src(fx, "b"), tagged("b", 10))
end

T["edges"]["<C-w> at col 0 of an excerpt's first row joins into the file above"] = function()
  local fx, qbuf = three()
  H.go(child, 3)
  keys("I<C-w><Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "a")[6], "a:6 lb:2 l")
  eq(#src(fx, "b"), 9)
end

T["edges"]["<C-u> at col 0 of an excerpt's first row joins into the file above"] = function()
  local fx, qbuf = three()
  H.go(child, 3)
  keys("I<C-u><Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "a")[6], "a:6 lb:2 l")
end

T["edges"]["<Del> at the end of an excerpt's last row pulls the next file's line into it"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("A<Del><Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "a")[6], "a:6 lb:2 l")
  eq(#src(fx, "b"), 9)
end

T["edges"]["<BS> held across two edges in one insert joins both lines into the first file"] = function()
  local fx = files({ a = 10, b = 10, c = 10 })
  local qbuf = quilt(fx, { { "a", 5 }, { "b", 1 }, { "c", 6 } }, 0) -- a:5 | b:1 | c:6
  H.go(child, 2)
  -- one <BS> joins c:6 onto b:1, five delete "b:1 l", one more joins onto a:5
  keys("I<BS><BS><BS><BS><BS><BS><BS><Esc>")
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:5 lc:6 l" })
  eq(#src(fx, "b"), 9)
end

T["edges"]["<BS> at col 0 then u then <C-r> then u"] = function()
  local fx, qbuf = three()
  H.go(child, 3)
  keys("I<BS><Esc>")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  keys("<C-r>")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), tagged("a", 10))
  eq(src(fx, "b"), tagged("b", 10))
end

-- Collapsed excerpts -----------------------------------------------------------------

T["collapsed"] = MiniTest.new_set()

T["collapsed"]["o on the last row after the last excerpt was deleted appends to the file above"] = function()
  local fx, qbuf = three()
  H.go(child, 6)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 5)
  keys("o<C-r>=Tg(line('.')-1)<CR>:n<Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "c"), { "c:1 l", "c:2 l", "c:3 l", "c:4 l", "c:8 l", "c:9 l", "c:10 l" })
end

T["collapsed"]["yyp on the last row after the last excerpt was deleted appends to the file above"] = function()
  local fx, qbuf = three()
  H.go(child, 6)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 5)
  keys("yyp")
  all_checks(fx, qbuf)
end

T["collapsed"]["A<CR> on the last row after the last excerpt was deleted"] = function()
  local fx, qbuf = three()
  H.go(child, 6)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 5)
  keys("A<CR><C-r>=Tg(line('.')-1)<CR>:cr<Esc>")
  all_checks(fx, qbuf)
end

T["collapsed"]["A! on the last row after the last excerpt was deleted"] = function()
  local fx, qbuf = three()
  H.go(child, 6)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 5)
  keys("A!<Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "b")[4], "b:4 l!")
end

T["collapsed"]["middle excerpt deleted, neighbours edited at the seam, then undo all"] = function()
  local fx, qbuf = three()
  H.go(child, 3)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 2)
  keys("o<C-r>=Tg(line('.')-1)<CR>:o<Esc>")
  all_checks(fx, qbuf)
  H.go(child, 4)
  keys("O<C-r>=Tg(line('.')+1)<CR>:O<Esc>")
  all_checks(fx, qbuf)
  H.go(child, 3)
  keys("J")
  all_checks(fx, qbuf)
  for _ = 1, 4 do
    keys("u")
    all_checks(fx, qbuf)
  end
  eq(src(fx, "a"), tagged("a", 10))
  eq(src(fx, "b"), tagged("b", 10))
  eq(src(fx, "c"), tagged("c", 10))
  for _ = 1, 4 do
    keys("<C-r>")
    all_checks(fx, qbuf)
  end
  eq(#src(fx, "b"), 7)
end

T["collapsed"]["every excerpt deleted then o on the empty quilt"] = function()
  local fx, qbuf = three()
  keys("gg", "dG")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), tagged("a", 10))
  eq(src(fx, "c"), tagged("c", 10))
end

-- Blank and repeated lines at edges --------------------------------------------------

T["blank"] = MiniTest.new_set()

T["blank"]["a one-row blank excerpt survives deleting the other excerpt"] = function()
  local fx = files({ a = { "a:1", "", "a:3" }, b = 5 })
  local qbuf = quilt(fx, { { "a", 2 }, { "b", 3 } }, 0) -- "" | b:3
  eq(H.quilt_lines(child, qbuf), { "", "b:3 l" })
  H.go(child, 1)
  keys("dd")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "", "a:3" })
  eq(src(fx, "b"), { "b:1 l", "b:2 l", "b:4 l", "b:5 l" })
end

T["blank"]["a blank last row, the last excerpt deleted, then text typed on the blank row"] = function()
  local fx = files({ a = { "a:1", "a:2", "", "a:4" }, b = 5 })
  local qbuf = quilt(fx, { { "a", 2 }, { "b", 3 } }, 1) -- a:1 a:2 "" | b:2 b:3 b:4
  eq(H.quilt_lines(child, qbuf), { "a:1", "a:2", "", "b:2 l", "b:3 l", "b:4 l" })
  H.go(child, 3)
  keys("3dd")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "b"), { "b:1 l", "b:5 l" })
  H.go(child, 2)
  keys("Ia:new<Esc>")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "a:2", "a:new", "a:4" })
  eq(src(fx, "b"), { "b:1 l", "b:5 l" })
end

T["blank"]["a blank last row, the last excerpt deleted, then o on the blank row"] = function()
  local fx = files({ a = { "a:1", "a:2", "", "a:4" }, b = 5 })
  local qbuf = quilt(fx, { { "a", 2 }, { "b", 3 } }, 1)
  H.go(child, 3)
  keys("3dd")
  H.settle(child, qbuf)
  H.go(child, 2)
  keys("oa:new<Esc>")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "a:2", "", "a:new", "a:4" })
  eq(src(fx, "b"), { "b:1 l", "b:5 l" })
end

T["blank"]["blank rows on both sides of an edge: o, O, J, dd then undo all"] = function()
  local fx = files({ a = { "a:1", "a:2", "", "a:4" }, b = { "b:1", "", "b:3", "b:4" } })
  local qbuf = quilt(fx, { { "a", 2 }, { "b", 3 } }, 1) -- a:1 a:2 "" | "" b:3 b:4
  eq(H.quilt_lines(child, qbuf), { "a:1", "a:2", "", "", "b:3", "b:4" })
  H.go(child, 2)
  keys("o")
  keys("<Esc>")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "a:2", "", "", "a:4" })
  eq(src(fx, "b"), { "b:1", "", "b:3", "b:4" })
  H.go(child, 4)
  keys("O")
  keys("<Esc>")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "b"), { "b:1", "", "", "b:3", "b:4" })
  H.go(child, 3)
  keys("dd")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "a:2", "", "a:4" })
  for _ = 1, 3 do
    keys("u")
    H.settle(child, qbuf)
    H.check(child, qbuf)
  end
  eq(src(fx, "a"), { "a:1", "a:2", "", "a:4" })
  eq(src(fx, "b"), { "b:1", "", "b:3", "b:4" })
end

T["blank"]["identical lines across an edge: yyp on the last row then yyP on the first"] = function()
  local fx = files({ a = { "a:1", "x", "x", "a:4" }, b = { "b:1", "x", "x", "b:4" } })
  local qbuf = quilt(fx, { { "a", 2 }, { "b", 3 } }, 1) -- a:1 x x | x x b:4
  H.go(child, 2)
  keys("yyp")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "x", "x", "x", "a:4" })
  eq(src(fx, "b"), { "b:1", "x", "x", "b:4" })
  H.go(child, 4)
  keys("yyP")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "x", "x", "x", "a:4" })
  eq(src(fx, "b"), { "b:1", "x", "x", "x", "b:4" })
  keys("u")
  H.settle(child, qbuf)
  keys("u")
  H.settle(child, qbuf)
  H.check(child, qbuf)
  eq(src(fx, "a"), { "a:1", "x", "x", "a:4" })
  eq(src(fx, "b"), { "b:1", "x", "x", "b:4" })
end

-- Two excerpts of one file -----------------------------------------------------------

T["same file"] = MiniTest.new_set()

-- a:3 a:4 a:5 | a:7 a:8 a:9 | b:4 b:5 b:6
local function same_file()
  local fx = files({ a = 12, b = 10 })
  local qbuf = quilt(fx, { { "a", 4 }, { "a", 8 }, { "b", 5 } })
  eq(H.quilt_lines(child, qbuf), { "a:3 l", "a:4 l", "a:5 l", "a:7 l", "a:8 l", "a:9 l", "b:4 l", "b:5 l", "b:6 l" })
  return fx, qbuf
end

T["same file"]["J across the seam of two excerpts of one file keeps the hidden row"] = function()
  local fx, qbuf = same_file()
  H.go(child, 2)
  keys("J")
  all_checks(fx, qbuf)
  eq(
    src(fx, "a"),
    { "a:1 l", "a:2 l", "a:3 l", "a:4 l", "a:5 l a:7 l", "a:6 l", "a:8 l", "a:9 l", "a:10 l", "a:11 l", "a:12 l" }
  )
end

T["same file"]["first excerpt deleted, the second edited at its first row, then undo"] = function()
  local fx, qbuf = same_file()
  H.go(child, 0)
  keys("3dd")
  all_checks(fx, qbuf)
  H.go(child, 0)
  keys("O<C-r>=Tg(line('.')+1)<CR>:O<Esc>")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), tagged("a", 12))
end

T["same file"]["Vjd across the seam then p back"] = function()
  local fx, qbuf = same_file()
  H.go(child, 2)
  keys("Vjd")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), { "a:1 l", "a:2 l", "a:3 l", "a:4 l", "a:6 l", "a:8 l", "a:9 l", "a:10 l", "a:11 l", "a:12 l" })
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "a"), tagged("a", 12))
end

-- Undo chains ------------------------------------------------------------------------

T["undo"] = MiniTest.new_set()

local function edge_edits()
  -- Ten edits that each touch an excerpt edge.
  local steps = {
    { 2, "o<C-r>=Tg(line('.')-1)<CR>:o1<Esc>" },
    { 4, "O<C-r>=Tg(line('.')+1)<CR>:O1<Esc>" },
    { 3, "yyp" },
    { 5, "yyP" },
    { 4, "J" },
    { 2, "A<CR><C-r>=Tg(line('.')-1)<CR>:cr<Esc>" },
    { 5, "I<BS><Esc>" },
    { 0, "dd" },
    { 6, "Vjd" },
    { 1, [[:s/\v^(\a):(\S+)/\1:\2.\r\1:s/e<CR>]] },
  }
  return steps
end

T["undo"]["10 edge edits, 10u, 10<C-r>, 10u"] = function()
  local fx, qbuf = three()
  local after = {}
  for i, s in ipairs(edge_edits()) do
    H.go(child, s[1])
    keys(s[2])
    all_checks(fx, qbuf, "edit " .. i)
    after[i] = { src(fx, "a"), src(fx, "b"), src(fx, "c") }
  end
  keys("10u")
  all_checks(fx, qbuf, "10u")
  eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, { tagged("a", 10), tagged("b", 10), tagged("c", 10) })
  keys("10<C-r>")
  all_checks(fx, qbuf, "10<C-r>")
  eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, after[10])
  keys("10u")
  all_checks(fx, qbuf, "10u again")
  eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, { tagged("a", 10), tagged("b", 10), tagged("c", 10) })
end

T["undo"]["10 edge edits, one u per settle back to the start, then one <C-r> per settle"] = function()
  local fx, qbuf = three()
  local states = { { src(fx, "a"), src(fx, "b"), src(fx, "c") } }
  for i, s in ipairs(edge_edits()) do
    H.go(child, s[1])
    keys(s[2])
    all_checks(fx, qbuf, "edit " .. i)
    states[i + 1] = { src(fx, "a"), src(fx, "b"), src(fx, "c") }
  end
  for i = 10, 1, -1 do
    keys("u")
    all_checks(fx, qbuf, "u back to " .. (i - 1))
    eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, states[i])
  end
  for i = 1, 10 do
    keys("<C-r>")
    all_checks(fx, qbuf, "<C-r> to " .. i)
    eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, states[i + 1])
  end
end

T["undo"]["g- and g+ across a branch"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("known v1 limit: moving across undo branches can put an edge line in the excerpt next to it")
  local fx, qbuf = three()
  H.go(child, 2)
  keys("yyp")
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  H.go(child, 3)
  keys("yyP")
  all_checks(fx, qbuf)
  local branch2 = { src(fx, "a"), src(fx, "b") }
  keys("g-")
  all_checks(fx, qbuf, "g- 1")
  keys("g-")
  all_checks(fx, qbuf, "g- 2")
  local branch1 = { src(fx, "a"), src(fx, "b") }
  eq(#branch1[1], 11)
  eq(branch1[2], tagged("b", 10))
  keys("g-")
  all_checks(fx, qbuf, "g- 3")
  eq({ src(fx, "a"), src(fx, "b") }, { tagged("a", 10), tagged("b", 10) })
  keys("g+")
  keys("g+")
  all_checks(fx, qbuf, "g+ g+")
  keys("g+")
  all_checks(fx, qbuf, "g+")
  eq({ src(fx, "a"), src(fx, "b") }, branch2)
end

T["undo"]["yyp on a last row, an edit elsewhere, 2u, 2<C-r> puts the copy back in its own file"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("yyp")
  all_checks(fx, qbuf)
  H.go(child, 0)
  keys("A!<Esc>")
  all_checks(fx, qbuf)
  keys("2u")
  all_checks(fx, qbuf, "2u")
  keys("2<C-r>")
  all_checks(fx, qbuf, "2<C-r>")
  eq(src(fx, "b"), tagged("b", 10))
end

T["undo"]["yyp, u, yyP on the next excerpt, g- puts the first copy back in its own file"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("yyp")
  all_checks(fx, qbuf)
  keys("u")
  H.go(child, 3)
  keys("yyP")
  all_checks(fx, qbuf)
  keys("g-")
  all_checks(fx, qbuf, "g-")
  eq(src(fx, "b"), tagged("b", 10))
end

T["undo"][":earlier and :later across edge inserts"] = function()
  local fx, qbuf = three()
  H.go(child, 2)
  keys("yyp")
  all_checks(fx, qbuf)
  H.go(child, 4)
  keys("yyP")
  all_checks(fx, qbuf)
  child.cmd("earlier 2")
  all_checks(fx, qbuf, ":earlier 2")
  child.cmd("later 2")
  all_checks(fx, qbuf, ":later 2")
  eq(#src(fx, "a"), 11)
  eq(#src(fx, "b"), 11)
end

T["undo"]["u after a quilt edit and a foreign source edit in the same tick undoes the quilt edit"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("decided: u in the quilt also undoes a change made to the file elsewhere")
  local fx, qbuf = three()
  child.lua(
    [[
    local qbuf, abuf = ...
    vim.api.nvim_set_current_buf(qbuf)
    vim.cmd("normal! 5GA!")
    vim.api.nvim_buf_set_lines(abuf, 0, 1, true, { "a:1 other" })
  ]],
    { qbuf, H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  eq(src(fx, "b")[3], "b:3 l!")
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "b"), tagged("b", 10))
  eq(src(fx, "a")[1], "a:1 other")
end

T["undo"]["u in the quilt after another window changed an excerpt row undoes the quilt edit"] = function()
  -- SPEC "Known limits in v1".
  MiniTest.skip("decided: u in the quilt also undoes a change made to the file elsewhere")
  local fx, qbuf = three()
  H.go(child, 4)
  keys("A!<Esc>")
  all_checks(fx, qbuf)
  child.api.nvim_buf_set_lines(H.bufnr(child, fx.tags.a), 4, 5, true, { "a:5 other" })
  all_checks(fx, qbuf)
  keys("u")
  all_checks(fx, qbuf)
  eq(src(fx, "b"), tagged("b", 10))
  eq(src(fx, "a")[5], "a:5 other")
end

-- View edits in the middle of an undo chain -------------------------------------------

T["view"] = MiniTest.new_set()

for _, view in ipairs({ { "+", "+" }, { "-", "-" }, { "zd", "zd" }, { "refresh", ":Quilt refresh<CR>" } }) do
  T["view"][view[1] .. " in the middle of an undo chain, then u and <C-r>"] = function()
    local fx = files({ a = 20, b = 20, c = 20 })
    local qbuf = quilt(fx, { { "a", 8 }, { "b", 8 }, { "c", 8 } }, 2) -- 5 rows each
    H.go(child, 4)
    keys("o<C-r>=Tg(line('.')-1)<CR>:o<Esc>")
    all_checks(fx, qbuf)
    H.go(child, 6)
    keys("yyP")
    all_checks(fx, qbuf)
    keys("u")
    all_checks(fx, qbuf)
    local before = { src(fx, "a"), src(fx, "b"), src(fx, "c") }
    H.go(child, 7)
    keys(view[2])
    all_checks(fx, qbuf, view[1])
    eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, before)
    local h = hidden(qbuf)
    keys("u")
    all_checks(fx, qbuf, view[1] .. " then u")
    keys("<C-r>")
    all_checks(fx, qbuf, view[1] .. " then <C-r>")
    eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, before)
    eq(hidden(qbuf), h)
    -- and editing still works at the edges afterwards
    H.go(child, 0)
    keys("O<C-r>=Tg(line('.')+1)<CR>:O<Esc>")
    all_checks(fx, qbuf, view[1] .. " then O")
    keys("u")
    all_checks(fx, qbuf, view[1] .. " then O u")
    eq({ src(fx, "a"), src(fx, "b"), src(fx, "c") }, before)
  end
end

T["view"]["+ then undo of edits made before + must not touch the sources twice"] = function()
  local fx = files({ a = 20, b = 20 })
  local qbuf = quilt(fx, { { "a", 8 }, { "b", 8 } }, 2)
  H.go(child, 4)
  keys("yyp")
  all_checks(fx, qbuf)
  H.go(child, 0)
  keys("+")
  all_checks(fx, qbuf)
  local before = { src(fx, "a"), src(fx, "b") }
  keys("u", "u", "u")
  all_checks(fx, qbuf)
  eq({ src(fx, "a"), src(fx, "b") }, before)
end

-- Source-side rewrites ---------------------------------------------------------------

T["source"] = MiniTest.new_set()

T["source"]["whole-buffer rewrite with two lines changed right at excerpt edges"] = function()
  local fx = files({ a = 20, b = 20 })
  local qbuf = quilt(fx, { { "a", 6 }, { "a", 14 }, { "b", 5 } }, 1) -- a:5-7 | a:13-15 | b:4-6
  child.lua(
    [[
    local abuf = ...
    local lines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
    lines[4] = "a:4 FMT"   -- just above the first excerpt
    lines[7] = "a:7 FMT"   -- its last row
    lines[13] = "a:13 FMT" -- first row of the second excerpt
    lines[16] = "a:16 FMT" -- just below it
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
  ]],
    { H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  eq(
    H.quilt_lines(child, qbuf),
    { "a:5 l", "a:6 l", "a:7 FMT", "a:13 FMT", "a:14 l", "a:15 l", "b:4 l", "b:5 l", "b:6 l" }
  )
end

T["source"]["whole-buffer rewrite that inserts a line above and deletes one below an excerpt"] = function()
  local fx = files({ a = 20 })
  local qbuf = quilt(fx, { { "a", 6 }, { "a", 14 } }, 1)
  child.lua(
    [[
    local abuf = ...
    local lines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
    table.remove(lines, 16)
    table.insert(lines, 4, "a:ins")
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
  ]],
    { H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:5 l", "a:6 l", "a:7 l", "a:13 l", "a:14 l", "a:15 l" })
end

T["source"]["whole-buffer rewrite while the quilt has an unsettled edit in another excerpt"] = function()
  local fx = files({ a = 20, b = 20 })
  local qbuf = quilt(fx, { { "a", 6 }, { "b", 6 } }, 1)
  child.lua(
    [[
    local qbuf, abuf = ...
    vim.api.nvim_buf_set_lines(qbuf, 4, 5, true, { "b:6 l!" })
    local lines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
    lines[6] = "a:6 FMT"
    table.insert(lines, 1, "a:top")
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
  ]],
    { qbuf, H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:5 l", "a:6 FMT", "a:7 l", "b:5 l", "b:6 l!", "b:7 l" })
end

T["source"]["apply_text_edits with several edits in one source, inside, at the edges, and outside"] = function()
  local fx = files({ a = 20, b = 10 })
  local qbuf = quilt(fx, { { "a", 6 }, { "a", 14 }, { "b", 5 } }, 1) -- a rows 4..6 | 12..14 | b 3..5
  child.lua(
    [[
    local abuf = ...
    local function e(l1, c1, l2, c2, t)
      return { range = { start = { line = l1, character = c1 }, ["end"] = { line = l2, character = c2 } }, newText = t }
    end
    vim.lsp.util.apply_text_edits({
      e(3, 2, 4, 2, ""),           -- join the row above the first excerpt into its first row
      e(6, 4, 6, 4, "\na:x1\na:x2"), -- split the last row
      e(9, 0, 11, 0, ""),           -- delete two hidden rows between the excerpts
      e(12, 0, 12, 0, "a:pre\n"),   -- insert above the second excerpt
      e(14, 3, 15, 3, "Z"),         -- merge its last row with the row below
    }, abuf, "utf-16")
  ]],
    { H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  local q = H.quilt_lines(child, qbuf)
  for _, l in ipairs(q) do
    eq(l:sub(1, 1) == "a" or l:sub(1, 1) == "b", true)
  end
  eq(vim.tbl_contains(q, "a:7 "), true)
end

T["source"]["formatter rewrite of a 9000 line file with one excerpt"] = function()
  local fx = files({ a = 9000 })
  local qbuf = quilt(fx, { { "a", 4500 } }, 1)
  child.lua(
    [[
    local abuf = ...
    local lines = vim.api.nvim_buf_get_lines(abuf, 0, -1, false)
    lines[4500] = "a:4500 FMT"
    vim.api.nvim_buf_set_lines(abuf, 0, -1, false, lines)
  ]],
    { H.bufnr(child, fx.tags.a) }
  )
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:4499 l", "a:4500 FMT", "a:4501 l" })
end

T["source"][":%s in a 9000 line source, then an edit next to the excerpt"] = function()
  local fx = files({ a = 9000 })
  local qbuf = quilt(fx, { { "a", 4500 } }, 1)
  child.lua([[vim.api.nvim_buf_call(..., function() vim.cmd("silent %s/ l$/ L/") end)]], { H.bufnr(child, fx.tags.a) })
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:4499 L", "a:4500 L", "a:4501 L" })
  child.api.nvim_buf_set_lines(H.bufnr(child, fx.tags.a), 4500, 4501, true, { "a:4501 edited" })
  all_checks(fx, qbuf)
  eq(H.quilt_lines(child, qbuf), { "a:4499 L", "a:4500 L", "a:4501 edited" })
end

T["source"]["an edit in a 9000 row excerpt"] = function()
  local fx = files({ a = 9000 })
  local qbuf = quilt(fx, { { "a", 4500 } }, 4500)
  eq(#H.quilt_lines(child, qbuf), 9000)
  H.go(child, 10)
  keys("A!<Esc>")
  all_checks(fx, qbuf)
  eq(src(fx, "a")[11], "a:11 l!")
end

-- Scale ------------------------------------------------------------------------------

T["scale"] = MiniTest.new_set()

T["scale"]["150 excerpts across 30 files: edits stay fast and correct"] = function()
  local spec, tags = {}, {}
  -- Single-letter tags for Tg(): a..z, then A..D.
  for i = 1, 30 do
    tags[i] = i <= 26 and string.char(96 + i) or string.char(64 + i - 26)
    spec[tags[i]] = 200
  end
  local fx = files(spec)
  local hits = {}
  for i = 1, 30 do
    for k = 1, 5 do
      hits[#hits + 1] = { tags[i], k * 35 }
    end
  end
  local t0 = vim.uv.hrtime()
  local qbuf = quilt(fx, hits, 3)
  local t_open = (vim.uv.hrtime() - t0) / 1e6
  eq(#H.spans(child, qbuf), 150)
  local times = {}
  local function timed(name, fn)
    local t = vim.uv.hrtime()
    fn()
    H.settle(child, qbuf)
    times[#times + 1] = ("%s %.0fms"):format(name, (vim.uv.hrtime() - t) / 1e6)
  end
  timed("A! at the bottom", function()
    keys("G", "A!<Esc>")
  end)
  timed("o at an edge in the middle", function()
    H.go(child, 6 * 75 + 6)
    keys("o<C-r>=Tg(line('.')-1)<CR>:o<Esc>")
  end)
  timed(":%s split every line", function()
    child.cmd([[%s/\v^(\a):(\S+)/\1:\2.\r\1:s/]])
  end)
  timed("u", function()
    keys("u")
  end)
  timed("source rewrite", function()
    child.lua(
      [[
      local b = ...
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      lines[36] = lines[36] .. " FMT"
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    ]],
      { H.bufnr(child, fx.tags.m) }
    )
  end)
  all_checks(fx, qbuf)
  local per_edit = child.lua(
    [[
    local qbuf = ...
    local t = vim.uv.hrtime()
    for i = 1, 20 do
      local line = vim.api.nvim_buf_get_lines(qbuf, i * 10, i * 10 + 1, true)[1]
      vim.api.nvim_buf_set_lines(qbuf, i * 10, i * 10 + 1, true, { line .. "!" })
      require("quilt.buffer").flush(qbuf)
    end
    return (vim.uv.hrtime() - t) / 1e6 / 20
  ]],
    { qbuf }
  )
  times[#times + 1] = ("one flush %.1fms"):format(per_edit)
  all_checks(fx, qbuf)
  MiniTest.add_note(("150 excerpts / 30 files: open %.0fms; %s"):format(t_open, table.concat(times, "; ")))
  eq(per_edit < 50, true)
end

-- Random walk ------------------------------------------------------------------------

-- Each op: keys typed after moving to the row. `.` only comes paired with a change that always succeeds, so it
-- never repeats an older change at a row where the old tag would be wrong.
local OPS = {
  { "o", "o<C-r>=Tg(line('.')-1)<CR>:o<Esc>" },
  { "O", "O<C-r>=Tg(line('.')+1)<CR>:O<Esc>" },
  { "3o", "3o<C-r>=Tg(line('.')-1)<CR>:o3<Esc>" },
  { "2O", "2O<C-r>=Tg(line('.')+1)<CR>:O2<Esc>" },
  { "yyp", "yyp" },
  { "yyP", "yyP" },
  { "yy2p", "yy2p" },
  { ":t.", ":t.<CR>" },
  { "dd", "dd" },
  { "2dd", "2dd" },
  { "Vjd", "Vjd" },
  { "dj", "dj" },
  { "J", "J" },
  { "3J", "3J" },
  { "A!", "A!<Esc>" },
  { "C", "04lC!c<Esc>" },
  { "$x", [[:if strlen(getline('.')) > 6 | exe "normal! $x" | endif<CR>]] },
  { ":s", [[:s/\v^(\a):(\S+)/\1:\2.\r\1:s/e<CR>]] },
  { ":s2", [[:.,.+1s/\v^(\a):(\S+)/\1:\2,\r\1:t/e<CR>]] },
  { "<BS>", "I<BS><Esc>" },
  { "<C-w>", "I<C-w><Esc>" },
  { "<C-u>", "I<C-u><Esc>" },
  { "<Del>", "A<Del><Esc>" },
  { "A<CR>", "A<CR><C-r>=Tg(line('.')-1)<CR>:cr<Esc>" },
  { "I<CR>", "I<C-r>=Tg(line('.'))<CR>:ci <CR><Esc>" },
  { "A! j.", "A!<Esc>j." },
  { "dd .", "dd." },
  { "Vjd .", "Vjd." },
  { "u", "u", "undo" },
  { "u", "u", "undo" },
  { "<C-r>", "<C-r>", "undo" },
  { "3u", "3u", "undo" },
  { "3<C-r>", "3<C-r>", "undo" },
  { "10u", "10u", "undo" },
  { "10<C-r>", "10<C-r>", "undo" },
  { "g-", "g-", "undo" },
  { "g+", "g+", "undo" },
}

local function lcg(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

-- A mirror buffer in its own tab gets the same keys as the quilt.
-- Guarded walks add a 41-row excerpt of f.txt at the end and never pick a row inside it, so the last excerpt is
-- never deleted whole. That keeps the "collapsed last excerpt" bug out of the way of the others.
local GUARD = 38

local function walk_setup(guard)
  local fx =
    files(guard and { a = 30, b = 30, c = 30, d = 30, e = 30, f = 60 } or { a = 30, b = 30, c = 30, d = 30, e = 30 })
  -- a: two excerpts with one hidden row between; b: at the file start; c, e: in the middle; d: at the file end.
  H.config(child, { context = 1 })
  local list = {
    { fx.tags.a, 5 },
    { fx.tags.a, 9 },
    { fx.tags.b, 1 },
    { fx.tags.c, 15 },
    { fx.tags.d, 30 },
    { fx.tags.e, 10 },
  }
  if guard then
    for r = 10, 50 do
      list[#list + 1] = { fx.tags.f, r }
    end
  end
  local qbuf = H.quilt_qf(child, list)
  H.go(child, 0)
  local wq = child.api.nvim_get_current_win()
  child.cmd("tabnew")
  local wm = child.api.nvim_get_current_win()
  local mbuf = child.api.nvim_get_current_buf()
  child.bo.buftype = "nofile"
  child.lua(
    [[
    local mbuf, lines = ...
    local ul = vim.bo[mbuf].undolevels
    vim.bo[mbuf].undolevels = -1
    vim.api.nvim_buf_set_lines(mbuf, 0, -1, false, lines)
    vim.bo[mbuf].undolevels = ul
  ]],
    { mbuf, H.quilt_lines(child, qbuf) }
  )
  child.api.nvim_set_current_win(wq)
  return fx, qbuf, wq, wm, mbuf
end

-- Seeds that hit a known v1 limit (SPEC "Known limits in v1"): a multi-step redo across an edge, and `:t.` at an
-- edge inside fast typeahead.
local KNOWN = { ["39595 paced"] = true, ["23757 batched"] = true }

local function run_walk(seed, nsteps, batched, guard)
  if not guard and KNOWN[seed .. (batched and " batched" or " paced")] then
    MiniTest.skip("known v1 limit, see KNOWN above")
  end
  local fx, qbuf, wq, wm, mbuf = walk_setup(guard)
  local rnd = lcg(seed)
  local hidden0 = hidden(qbuf)
  local log = {}
  local edges = {}
  local function refresh_edges()
    edges = {}
    for _, s in ipairs(H.spans(child, qbuf)) do
      if s.count > 0 then
        edges[#edges + 1] = s.q_start
        edges[#edges + 1] = s.q_start - 1
        edges[#edges + 1] = s.q_start + s.count - 1
      end
    end
  end
  refresh_edges()
  local function fail(step, msg)
    local tail = {}
    for i = math.max(1, #log - 40), #log do
      tail[#tail + 1] = log[i]
    end
    error(
      ("seed %d (%s%s), step %d: %s\nops (step, + = same tick as the op before, row: keys):\n  %s"):format(
        seed,
        batched and "batched" or "paced",
        guard and ", guarded" or "",
        step,
        msg,
        table.concat(tail, "\n  ")
      ),
      0
    )
  end
  local function settle_check(step)
    local ok, err = pcall(function()
      H.settle(child, qbuf)
      local mirror = child.api.nvim_buf_get_lines(mbuf, 0, -1, false)
      local q = H.quilt_lines(child, qbuf)
      if not vim.deep_equal(mirror, q) then
        error(
          "quilt text differs from the mirror buffer:\n  mirror "
            .. vim.inspect(mirror)
            .. "\n  quilt  "
            .. vim.inspect(q)
        )
      end
      for _, l in ipairs(mirror) do
        if l ~= "" and not l:match("^%a:") then
          error("walk made an untagged line (test bug): " .. l)
        end
      end
      H.check(child, qbuf)
      provenance(fx)
      local h = hidden(qbuf)
      if not vim.deep_equal(h, hidden0) then
        error("rows outside every excerpt changed:\n  " .. vim.inspect(hidden0) .. "\n  " .. vim.inspect(h))
      end
      local n = notes()
      if #n > 0 then
        error("notices: " .. vim.inspect(n))
      end
    end)
    if not ok then
      fail(step, tostring(err))
    end
    refresh_edges()
  end
  -- Paced: one op per settle, typed like a person. Batched: 1 to 4 ops run inside one Lua call with
  -- feedkeys(..., "xt"), so no flush can run between them, as in a macro or a mapping. Both are deterministic.
  local function run_one(row, k)
    H.go(child, row)
    return pcall(child.type_keys, k)
  end
  local function run_batch(batch)
    return child.lua(
      [[
      local errs = {}
      for _, op in ipairs(...) do
        local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode(("%dG"):format(op[1] + 1) .. op[2]), "xt", false)
        if not ok then errs[#errs + 1] = err end
      end
      return errs
    ]],
      { batch }
    )
  end
  local step = 0
  while step < nsteps do
    local size = batched and rnd(4) or 1
    local batch = {}
    local mirror = child.api.nvim_buf_get_lines(mbuf, 0, -1, false)
    for _ = 1, size do
      local empty = #mirror == 1 and mirror[1] == "" -- typing into an empty quilt is a SPEC gap, not tested here
      local op
      repeat
        op = OPS[rnd(#OPS)]
      until not empty or op[3] == "undo"
      local row
      if #edges > 0 and rnd(2) == 1 then
        row = edges[rnd(#edges)]
      else
        row = rnd(#mirror) - 1
      end
      row = math.max(0, math.min(#mirror - 1 - (guard and GUARD or 0), row))
      batch[#batch + 1] = { row, op[2] }
      step = step + 1
      log[#log + 1] = ("%3d%s %2d: %s"):format(step, #batch > 1 and "+" or " ", row, op[2])
    end
    for _, w in ipairs({ wm, wq }) do
      child.api.nvim_set_current_win(w)
      if size == 1 then
        local ok, err = run_one(batch[1][1], batch[1][2])
        if not ok then
          log[#log] = log[#log] .. "   (" .. (w == wm and "mirror" or "quilt") .. " error: " .. tostring(err) .. ")"
        end
      else
        run_batch(batch)
      end
    end
    settle_check(step)
  end
end

local function seeds(batched, guard)
  local out = {}
  for i = 1, 5 do
    out[i] = { i * 7919, batched, guard }
  end
  return out
end

for _, mode in ipairs({ { "paced", false, "settled after each" }, { "batched", true, "1 to 4 per tick" } }) do
  for _, guard in ipairs({ false, true }) do
    local name = "walk " .. mode[1] .. (guard and " guarded" or "")
    T[name] = MiniTest.new_set({ parametrize = seeds(mode[2], guard) })
    T[name]["300 random edge-heavy steps, " .. mode[3] .. ", keep text, provenance and hidden rows"] = function(
      seed,
      batched,
      g
    )
      run_walk(seed, 300, batched, g)
    end
  end
end

return T
