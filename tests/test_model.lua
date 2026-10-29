-- The excerpt model: building, queries, and edits in both directions.
local eq = MiniTest.expect.equality
local M = require("quilt.model")

local T = MiniTest.new_set()

-- { src, src_start, count } per span, in quilt order.
local function shape(m)
  return vim.tbl_map(function(s)
    return { s.src, s.src_start, s.count }
  end, m:spans())
end

local function rows(prefix, n)
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = prefix .. i
  end
  return out
end

local function splice(t, first, last, new)
  local out = vim.list_slice(t, 1, first)
  vim.list_extend(out, new)
  return vim.list_extend(out, t, last + 1, #t)
end

local function apply_src(srcs, edits)
  for _, e in ipairs(edits) do
    srcs[e.src] = splice(srcs[e.src], e.first, e.last, e.lines)
  end
end

local function apply_q(quilt, srcs, edits)
  for _, e in ipairs(edits) do
    local new = e.lines or vim.list_slice(srcs[e.src], e.src_first + 1, e.src_last)
    quilt = splice(quilt, e.first, e.last, new)
  end
  return quilt
end

-- The oracle: the quilt is the source rows of each span, in order.
local function view(m, srcs)
  local out = {}
  for _, s in ipairs(m:spans()) do
    vim.list_extend(out, srcs[s.src], s.src_start + 1, s.src_start + s.count)
  end
  return out
end

-- A = src 1 rows [2, 5), B = src 1 rows [8, 10), C = src 2 rows [0, 2).
local function fixture()
  local m = M.new({
    { src = 1, start = 2, count = 3 },
    { src = 1, start = 8, count = 2 },
    { src = 2, start = 0, count = 2 },
  })
  local srcs = { rows("a", 12), rows("b", 4) }
  return m, srcs, view(m, srcs)
end

local function ids(m)
  return vim.tbl_map(function(s)
    return s.id
  end, m:spans())
end

T["new"] = MiniTest.new_set()

T["new"]["groups by source in first-seen order, sorts rows within a source"] = function()
  local m = M.new({
    { src = 7, start = 10, count = 2 },
    { src = 3, start = 5, count = 1 },
    { src = 7, start = 0, count = 3 },
    { src = 3, start = 1, count = 1 },
  })
  eq(shape(m), { { 7, 0, 3 }, { 7, 10, 2 }, { 3, 1, 1 }, { 3, 5, 1 } })
end

T["new"]["merges overlapping ranges and touching ranges"] = function()
  local m = M.new({
    { src = 1, start = 0, count = 3 },
    { src = 1, start = 2, count = 4 },
    { src = 1, start = 6, count = 1 },
    { src = 1, start = 1, count = 1 },
    { src = 1, start = 8, count = 1 },
  })
  eq(shape(m), { { 1, 0, 7 }, { 1, 8, 1 } })
end

T["new"]["drops ranges with count < 1"] = function()
  local m = M.new({
    { src = 1, start = 0, count = 0 },
    { src = 2, start = 4, count = 2 },
    { src = 2, start = 9, count = -1 },
  })
  eq(shape(m), { { 2, 4, 2 } })
  eq(M.new({}):line_count(), 0)
  eq(M.new({}):spans(), {})
end

T["new"]["spans have stable unique ids and correct q_start"] = function()
  local m = fixture()
  local spans = m:spans()
  eq(
    vim.tbl_map(function(s)
      return s.q_start
    end, spans),
    { 0, 3, 5 }
  )
  local a, b, c = spans[1].id, spans[2].id, spans[3].id
  eq(a ~= b and b ~= c and a ~= c, true)
  m:remove(b)
  eq(ids(m), { a, c })
  eq(m:spans()[2].q_start, 3)
  m:apply_quilt_change(0, 0, { "x" })
  eq(ids(m), { a, c })
end

T["new"]["spans returns a snapshot the caller can change"] = function()
  local m = fixture()
  local spans = m:spans()
  spans[1].count = 99
  table.remove(spans, 2)
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
  local s = m:locate(0)
  s.src_start = 50
  eq(m:find(s.id).src_start, 2)
end

T["queries"] = MiniTest.new_set()

T["queries"]["locate maps every quilt row and returns nil past the end"] = function()
  local m = fixture()
  local spans = m:spans()
  local want = { { 1, 2 }, { 1, 3 }, { 1, 4 }, { 2, 8 }, { 2, 9 }, { 3, 0 }, { 3, 1 } }
  for qrow, w in ipairs(want) do
    local span, row = m:locate(qrow - 1)
    eq({ span.id, row }, { spans[w[1]].id, w[2] })
    eq(span, spans[w[1]])
  end
  eq(m:locate(7), nil)
  eq(m:locate(-1), nil)
  eq(m:line_count(), 7)
end

T["queries"]["to_quilt maps rows inside spans and returns nil outside"] = function()
  local m = fixture()
  eq(m:to_quilt(1, 2), 0)
  eq(m:to_quilt(1, 4), 2)
  eq(m:to_quilt(1, 9), 4)
  eq(m:to_quilt(2, 1), 6)
  eq(m:to_quilt(1, 5), nil)
  eq(m:to_quilt(1, 1), nil)
  eq(m:to_quilt(1, 10), nil)
  eq(m:to_quilt(2, 2), nil)
  eq(m:to_quilt(9, 0), nil)
end

T["queries"]["find returns the span or nil"] = function()
  local m = fixture()
  local b = m:spans()[2]
  eq(m:find(b.id), b)
  eq(m:find(999), nil)
end

T["apply_quilt_change"] = MiniTest.new_set()

T["apply_quilt_change"]["edit inside one span changes only that source row"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(1, 2, { "x" }), { { src = 1, first = 3, last = 4, lines = { "x" } } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
end

T["apply_quilt_change"]["insert in the middle of a span shifts later spans of the same source"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(1, 1, { "x", "y" }), { { src = 1, first = 3, last = 3, lines = { "x", "y" } } })
  eq(shape(m), { { 1, 2, 5 }, { 1, 10, 2 }, { 2, 0, 2 } })
  eq(m:spans()[3].q_start, 7)
end

T["apply_quilt_change"]["boundary insert with prefer above appends to the span above"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(3, 3, { "x" }, "above"), { { src = 1, first = 5, last = 5, lines = { "x" } } })
  eq(shape(m), { { 1, 2, 4 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(m:apply_quilt_change(6, 6, { "y" }, "above"), { { src = 1, first = 11, last = 11, lines = { "y" } } })
  eq(shape(m), { { 1, 2, 4 }, { 1, 9, 3 }, { 2, 0, 2 } })
end

T["apply_quilt_change"]["boundary insert with prefer below prepends to the span below"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(3, 3, { "x" }, "below"), { { src = 1, first = 8, last = 8, lines = { "x" } } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 3 }, { 2, 0, 2 } })
  eq(m:apply_quilt_change(6, 6, { "y" }, "below"), { { src = 2, first = 0, last = 0, lines = { "y" } } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 3 }, { 2, 0, 3 } })
end

T["apply_quilt_change"]["boundary insert with no prefer goes below"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(3, 3, { "x" }), { { src = 1, first = 8, last = 8, lines = { "x" } } })
end

T["apply_quilt_change"]["insert at row 0 and at the end"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(0, 0, { "x" }, "above"), { { src = 1, first = 2, last = 2, lines = { "x" } } })
  eq(shape(m), { { 1, 2, 4 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(m:apply_quilt_change(8, 8, { "y", "" }, "below"), { { src = 2, first = 2, last = 2, lines = { "y", "" } } })
  eq(shape(m), { { 1, 2, 4 }, { 1, 9, 2 }, { 2, 0, 4 } })
end

T["apply_quilt_change"]["empty insert changes nothing"] = function()
  local m = fixture()
  eq(m:apply_quilt_change(2, 2, {}), {})
  eq(M.new({}):apply_quilt_change(0, 0, { "x" }), {})
end

T["apply_quilt_change"]["delete all lines of a span removes it and deletes its source rows"] = function()
  local m = fixture()
  local b = m:spans()[2].id
  eq(m:apply_quilt_change(3, 5, {}), { { src = 1, first = 8, last = 10, lines = {} } })
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 2 } })
  eq(m:find(b), nil)
end

T["apply_quilt_change"]["change spanning two spans of different sources (the J case)"] = function()
  local m, srcs, quilt = fixture()
  local edits = m:apply_quilt_change(4, 6, { "a9 b0" })
  eq(edits, {
    { src = 1, first = 9, last = 10, lines = { "a9 b0" } },
    { src = 2, first = 0, last = 1, lines = {} },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 1 } })
  apply_src(srcs, edits)
  eq(view(m, srcs), splice(quilt, 4, 6, { "a9 b0" }))
end

T["apply_quilt_change"]["change spanning two spans of the same source"] = function()
  local m, srcs, quilt = fixture()
  local edits = m:apply_quilt_change(2, 4, { "j", "k", "l" })
  -- One line each, the leftover goes to the last span. The gap rows a5..a7
  -- stay in the source, unseen.
  eq(edits, {
    { src = 1, first = 4, last = 5, lines = { "j" } },
    { src = 1, first = 8, last = 9, lines = { "k", "l" } },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 3 }, { 2, 0, 2 } })
  apply_src(srcs, edits)
  eq(srcs[1], { "a0", "a1", "a2", "a3", "j", "a5", "a6", "a7", "k", "l", "a9", "a10", "a11" })
  eq(view(m, srcs), splice(quilt, 2, 4, { "j", "k", "l" }))
end

T["apply_quilt_change"][":%s across three excerpts keeps every line in its own source"] = function()
  local m, srcs, quilt = fixture()
  local new = vim.tbl_map(function(l)
    return l:upper()
  end, quilt)
  local edits = m:apply_quilt_change(0, 7, new)
  eq(edits, {
    { src = 1, first = 2, last = 5, lines = { "A2", "A3", "A4" } },
    { src = 1, first = 8, last = 10, lines = { "A8", "A9" } },
    { src = 2, first = 0, last = 2, lines = { "B0", "B1" } },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
  apply_src(srcs, edits)
  eq(view(m, srcs), new)
end

T["apply_quilt_change"]["> across an edge keeps every line in its own source"] = function()
  local m, srcs = fixture()
  local edits = m:apply_quilt_change(1, 6, { "\ta3", "\ta4", "\ta8", "\ta9", "\tb0" })
  eq(edits, {
    { src = 1, first = 3, last = 5, lines = { "\ta3", "\ta4" } },
    { src = 1, first = 8, last = 10, lines = { "\ta8", "\ta9" } },
    { src = 2, first = 0, last = 1, lines = { "\tb0" } },
  })
  apply_src(srcs, edits)
  eq(view(m, srcs), { "a2", "\ta3", "\ta4", "\ta8", "\ta9", "\tb0", "b1" })
end

T["apply_quilt_change"]["J across an edge keeps the joined line in the first span"] = function()
  local m, srcs = fixture()
  local edits = m:apply_quilt_change(2, 4, { "a4 a8" })
  eq(edits, {
    { src = 1, first = 4, last = 5, lines = { "a4 a8" } },
    { src = 1, first = 8, last = 9, lines = {} },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 1 }, { 2, 0, 2 } })
  apply_src(srcs, edits)
  eq(view(m, srcs), { "a2", "a3", "a4 a8", "a9", "b0", "b1" })
end

T["apply_quilt_change"]["dj across an edge deletes from both spans"] = function()
  local m, srcs = fixture()
  local edits = m:apply_quilt_change(4, 6, {})
  eq(edits, {
    { src = 1, first = 9, last = 10, lines = {} },
    { src = 2, first = 0, last = 1, lines = {} },
  })
  apply_src(srcs, edits)
  eq(view(m, srcs), { "a2", "a3", "a4", "a8", "b1" })
end

T["apply_quilt_change"]["fewer lines than rows fill the touched spans in order"] = function()
  local m, srcs = fixture()
  local c = m:spans()[3].id
  local edits = m:apply_quilt_change(1, 6, { "x", "y" })
  eq(edits, {
    { src = 1, first = 3, last = 5, lines = { "x", "y" } },
    { src = 1, first = 8, last = 10, lines = {} },
    { src = 2, first = 0, last = 1, lines = {} },
  })
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 1 } })
  eq(m:spans()[2].id, c)
  apply_src(srcs, edits)
  eq(view(m, srcs), { "a2", "x", "y", "b1" })
end

T["apply_quilt_change"]["delete the whole quilt"] = function()
  local m, srcs = fixture()
  local edits = m:apply_quilt_change(0, 7, {})
  eq(edits, {
    { src = 1, first = 2, last = 5, lines = {} },
    { src = 1, first = 5, last = 7, lines = {} },
    { src = 2, first = 0, last = 2, lines = {} },
  })
  eq(m:spans(), {})
  eq(m:line_count(), 0)
  apply_src(srcs, edits)
  eq(srcs, { { "a0", "a1", "a5", "a6", "a7", "a10", "a11" }, { "b2", "b3" } })
end

T["apply_quilt_change"]["replacing the whole quilt with one line keeps it in the first span"] = function()
  local m, srcs = fixture()
  apply_src(srcs, m:apply_quilt_change(0, 7, { "x" }))
  eq(shape(m), { { 1, 2, 1 } })
  eq(view(m, srcs), { "x" })
end

T["apply_quilt_change"]["returned SrcEdits are valid when applied in order"] = function()
  local m, srcs, quilt = fixture()
  local steps = {
    { 1, 6, { "p", "q", "r", "s" } },
    { 0, 2, { "t" } },
    { 3, 3, { "u", "v" }, "above" },
    { 2, 5, {} },
    { 0, 1, { "w", "x", "y" } },
  }
  for _, st in ipairs(steps) do
    quilt = splice(quilt, st[1], st[2], st[3])
    apply_src(srcs, m:apply_quilt_change(st[1], st[2], st[3], st[4]))
    eq(view(m, srcs), quilt)
    eq(m:line_count(), #quilt)
  end
end

T["apply_source_change"] = MiniTest.new_set()

T["apply_source_change"]["change above a span shifts it, change below leaves it"] = function()
  local m = fixture()
  eq(m:apply_source_change(1, 0, 1, { "p", "q" }), {})
  eq(shape(m), { { 1, 3, 3 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(m:apply_source_change(1, 6, 8, {}), {})
  eq(shape(m), { { 1, 3, 3 }, { 1, 7, 2 }, { 2, 0, 2 } })
  eq(m:apply_source_change(1, 9, 11, { "z" }), {})
  eq(shape(m), { { 1, 3, 3 }, { 1, 7, 2 }, { 2, 0, 2 } })
end

T["apply_source_change"]["change that ends at a span's first row shifts it"] = function()
  local m = fixture()
  eq(m:apply_source_change(1, 6, 8, { "x" }), {})
  eq(shape(m), { { 1, 2, 3 }, { 1, 7, 2 }, { 2, 0, 2 } })
end

T["apply_source_change"]["insert at a span's first row shifts it, insert after its last row is outside"] = function()
  local m = fixture()
  eq(m:apply_source_change(1, 2, 2, { "x" }), {})
  eq(shape(m), { { 1, 3, 3 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(m:apply_source_change(1, 6, 6, { "y", "z" }), {})
  eq(shape(m), { { 1, 3, 3 }, { 1, 11, 2 }, { 2, 0, 2 } })
end

T["apply_source_change"]["change inside a span edits the quilt with literal lines"] = function()
  local m = fixture()
  eq(m:apply_source_change(1, 3, 4, { "y", "z" }), { { first = 1, last = 2, lines = { "y", "z" } } })
  eq(shape(m), { { 1, 2, 4 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(m:apply_source_change(1, 3, 3, { "x" }), { { first = 1, last = 1, lines = { "x" } } })
  eq(shape(m), { { 1, 2, 5 }, { 1, 10, 2 }, { 2, 0, 2 } })
end

T["apply_source_change"]["change overlapping a span's top edge grows the span upward"] = function()
  local m, srcs, quilt = fixture()
  srcs[1] = splice(srcs[1], 1, 3, { "p", "q", "r" })
  local edits = m:apply_source_change(1, 1, 3, { "p", "q", "r" })
  eq(edits, { { first = 0, last = 1, lines = { "p", "q", "r" } } })
  eq(shape(m), { { 1, 1, 5 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
end

T["apply_source_change"]["change overlapping a span's bottom edge grows it downward"] = function()
  local m, srcs, quilt = fixture()
  srcs[1] = splice(srcs[1], 4, 6, { "p", "q", "r" })
  local edits = m:apply_source_change(1, 4, 6, { "p", "q", "r" })
  eq(edits, { { first = 2, last = 3, lines = { "p", "q", "r" } } })
  eq(shape(m), { { 1, 2, 5 }, { 1, 9, 2 }, { 2, 0, 2 } })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
end

T["apply_source_change"]["change covering two spans merges them, gap rows come from the change"] = function()
  local m, srcs, quilt = fixture()
  local a = m:spans()[1].id
  srcs[1] = splice(srcs[1], 4, 9, { "m" })
  local edits = m:apply_source_change(1, 4, 9, { "m" })
  eq(edits, { { first = 2, last = 4, lines = { "m" } } })
  eq(shape(m), { { 1, 2, 4 }, { 2, 0, 2 } })
  eq(m:spans()[1].id, a)
  eq(view(m, srcs), { "a2", "a3", "m", "a9", "b0", "b1" })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
end

T["apply_source_change"]["change around a whole span grows it on both sides"] = function()
  local m, srcs, quilt = fixture()
  srcs[1] = splice(srcs[1], 7, 11, { "p", "q" })
  local edits = m:apply_source_change(1, 7, 11, { "p", "q" })
  eq(edits, { { first = 3, last = 5, lines = { "p", "q" } } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 7, 2 }, { 2, 0, 2 } })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
end

T["apply_source_change"]["delete covering a whole span removes it"] = function()
  local m, srcs, quilt = fixture()
  srcs[1] = splice(srcs[1], 7, 11, {})
  local edits = m:apply_source_change(1, 7, 11, {})
  eq(edits, { { first = 3, last = 5, lines = {} } })
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 2 } })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
  local m2 = fixture()
  eq(m2:apply_source_change(1, 8, 10, {}), { { first = 3, last = 5, lines = {} } })
  eq(shape(m2), { { 1, 2, 3 }, { 2, 0, 2 } })
end

T["apply_source_change"]["delete covering one span and part of the next keeps the rest"] = function()
  local m, srcs, quilt = fixture()
  srcs[1] = splice(srcs[1], 1, 9, {})
  local edits = m:apply_source_change(1, 1, 9, {})
  eq(edits, { { first = 0, last = 4, lines = {} } })
  eq(shape(m), { { 1, 1, 1 }, { 2, 0, 2 } })
  eq(view(m, srcs), apply_q(quilt, srcs, edits))
end

T["apply_source_change"]["change in a source not in the quilt returns no edits"] = function()
  local m = fixture()
  eq(m:apply_source_change(9, 0, 3, { "x" }), {})
  eq(m:apply_source_change(1, 3, 3, {}), {})
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
end

T["expand / shrink / remove / clamp"] = MiniTest.new_set()

T["expand / shrink / remove / clamp"]["expand clamps to 0 and to the source length"] = function()
  local m = M.new({ { src = 1, start = 1, count = 2 }, { src = 2, start = 0, count = 1 } })
  local srcs, quilt = { rows("a", 4), rows("b", 2) }, { "a1", "a2", "b0" }
  local id = m:spans()[1].id
  local edits = m:expand(id, 5, 5, 4)
  eq(edits, {
    { first = 0, last = 0, src = 1, src_first = 0, src_last = 1 },
    { first = 3, last = 3, src = 1, src_first = 3, src_last = 4 },
  })
  eq(shape(m), { { 1, 0, 4 }, { 2, 0, 1 } })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
  eq(m:expand(id, 2, 2, 4), {})
  eq(srcs, { rows("a", 4), rows("b", 2) })
end

T["expand / shrink / remove / clamp"]["expand into a neighbour merges the two spans"] = function()
  local m, srcs, quilt = fixture()
  local a, b, c = unpack(ids(m))
  local edits = m:expand(b, 5, 1, 12)
  eq(edits, {
    { first = 3, last = 3, src = 1, src_first = 5, src_last = 8 },
    { first = 8, last = 8, src = 1, src_first = 10, src_last = 11 },
  })
  eq(shape(m), { { 1, 2, 9 }, { 2, 0, 2 } })
  eq(ids(m), { a, c })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["expand down into the next span merges too"] = function()
  local m, srcs, quilt = fixture()
  local a, _, c = unpack(ids(m))
  local edits = m:expand(a, 0, 3, 12)
  eq(edits, { { first = 3, last = 3, src = 1, src_first = 5, src_last = 8 } })
  eq(shape(m), { { 1, 2, 8 }, { 2, 0, 2 } })
  eq(ids(m), { a, c })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["expand past a neighbour keeps going and shows every row asked for"] = function()
  local m, srcs, quilt = fixture()
  local a, _, c = unpack(ids(m))
  local edits = m:expand(a, 0, 7, 12)
  eq(edits, {
    { first = 3, last = 3, src = 1, src_first = 5, src_last = 8 },
    { first = 8, last = 8, src = 1, src_first = 10, src_last = 12 },
  })
  eq(shape(m), { { 1, 2, 10 }, { 2, 0, 2 } })
  eq(ids(m), { a, c })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["expand merges every span it meets on both sides"] = function()
  local m =
    M.new({ { src = 1, start = 0, count = 1 }, { src = 1, start = 3, count = 1 }, { src = 1, start = 6, count = 1 } })
  local srcs, quilt = { rows("a", 10) }, { "a0", "a3", "a6" }
  local first, mid = unpack(ids(m))
  local edits = m:expand(mid, 5, 5, 10)
  eq(edits, {
    { first = 1, last = 1, src = 1, src_first = 1, src_last = 3 },
    { first = 4, last = 4, src = 1, src_first = 4, src_last = 6 },
    { first = 7, last = 7, src = 1, src_first = 7, src_last = 9 },
  })
  eq(shape(m), { { 1, 0, 9 } })
  eq(ids(m), { first })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["expand never crosses into another source"] = function()
  local m, srcs, quilt = fixture()
  local edits = m:expand(m:spans()[3].id, 3, 1, 4)
  eq(edits, { { first = 7, last = 7, src = 2, src_first = 2, src_last = 3 } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 3 } })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["shrink stops at one row"] = function()
  local m = M.new({ { src = 1, start = 0, count = 5 }, { src = 1, start = 10, count = 3 } })
  local srcs, quilt = { rows("a", 14) }, { "a0", "a1", "a2", "a3", "a4", "a10", "a11", "a12" }
  local first, second = unpack(ids(m))
  local edits = m:shrink(first, 1, 2)
  eq(edits, { { first = 0, last = 1, lines = {} }, { first = 2, last = 4, lines = {} } })
  eq(shape(m), { { 1, 1, 2 }, { 1, 10, 3 } })
  quilt = apply_q(quilt, srcs, edits)
  eq(quilt, view(m, srcs))
  -- Both sides want more than there is: they share it and the middle row stays.
  edits = m:shrink(second, 5, 5)
  eq(shape(m), { { 1, 1, 2 }, { 1, 11, 1 } })
  quilt = apply_q(quilt, srcs, edits)
  eq(quilt, view(m, srcs))
  eq(m:shrink(second, 1, 1), {})
  eq(m:shrink(first, 0, 9), { { first = 1, last = 2, lines = {} } })
  eq(shape(m), { { 1, 1, 1 }, { 1, 11, 1 } })
end

T["expand / shrink / remove / clamp"]["remove drops the span and its quilt rows only"] = function()
  local m, srcs, quilt = fixture()
  local a, b, c = unpack(ids(m))
  local edits = m:remove(b)
  eq(edits, { { first = 3, last = 5, lines = {} } })
  eq(ids(m), { a, c })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
  eq(m:remove(b), {})
end

T["expand / shrink / remove / clamp"]["clamp after the source got shorter"] = function()
  local m, srcs, quilt = fixture()
  local a, _, c = unpack(ids(m))
  srcs[1] = rows("n", 9)
  local edits = m:clamp(1, 9)
  eq(edits, {
    { first = 0, last = 3, src = 1, src_first = 2, src_last = 5 },
    { first = 3, last = 5, src = 1, src_first = 8, src_last = 9 },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 1 }, { 2, 0, 2 } })
  quilt = apply_q(quilt, srcs, edits)
  eq(quilt, view(m, srcs))
  srcs[1] = rows("o", 3)
  edits = m:clamp(1, 3)
  eq(edits, {
    { first = 0, last = 3, src = 1, src_first = 2, src_last = 3 },
    { first = 1, last = 2, lines = {} },
  })
  eq(shape(m), { { 1, 2, 1 }, { 2, 0, 2 } })
  eq(ids(m), { a, c })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

return T
