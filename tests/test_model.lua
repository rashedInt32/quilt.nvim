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
  m:replace(a, 0, 0, { "x" })
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

-- The fixture with B's rows deleted from the quilt and the source.
local function collapsed()
  local m, srcs = fixture()
  local b = m:spans()[2].id
  apply_src(srcs, { m:replace(b, 0, 2, {}) })
  return m, srcs, b
end

T["replace"] = MiniTest.new_set()

T["replace"]["replace inside one span changes only that source row"] = function()
  local m = fixture()
  eq(m:replace(m:spans()[1].id, 1, 2, { "x" }), { src = 1, first = 3, last = 4, lines = { "x" } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
end

T["replace"]["replace with more lines shifts later spans of the same source and every later q_start"] = function()
  local m = fixture()
  eq(m:replace(m:spans()[1].id, 1, 1, { "x", "y" }), { src = 1, first = 3, last = 3, lines = { "x", "y" } })
  eq(shape(m), { { 1, 2, 5 }, { 1, 10, 2 }, { 2, 0, 2 } })
  eq(
    vim.tbl_map(function(s)
      return s.q_start
    end, m:spans()),
    { 0, 5, 7 }
  )
end

T["replace"]["replace inserts at rel 0 and appends at rel count"] = function()
  local m, srcs, quilt = fixture()
  local b = m:spans()[2].id
  local e1 = m:replace(b, 0, 0, { "x" })
  eq(e1, { src = 1, first = 8, last = 8, lines = { "x" } })
  local e2 = m:replace(b, 3, 3, { "y" })
  eq(e2, { src = 1, first = 11, last = 11, lines = { "y" } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 4 }, { 2, 0, 2 } })
  apply_src(srcs, { e1, e2 })
  eq(view(m, srcs), { quilt[1], quilt[2], quilt[3], "x", "a8", "a9", "y", "b0", "b1" })
end

T["replace"]["replace of every row collapses the span"] = function()
  local m, srcs, b = collapsed()
  local spans = m:spans()
  eq(#spans, 3)
  eq(spans[2], { id = b, src = 1, src_start = 8, q_start = 3, count = 0 })
  eq(spans[3].q_start, 3)
  eq(m:find(b).count, 0)
  eq(m:line_count(), 5)
  eq(m:locate(3).id, spans[3].id)
  eq(m:to_quilt(1, 8), nil)
  eq(view(m, srcs), { "a2", "a3", "a4", "b0", "b1" })
end

T["replace"]["replace at rel 0 on a collapsed span brings its rows back"] = function()
  local m, srcs, b = collapsed()
  local e = m:replace(b, 0, 0, { "a8", "a9" })
  eq(e, { src = 1, first = 8, last = 8, lines = { "a8", "a9" } })
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
  apply_src(srcs, { e })
  eq(srcs, { rows("a", 12), rows("b", 4) })
end

T["replace"][":%s with \\r across three excerpts keeps every line in its own source"] = function()
  local m, srcs, quilt = fixture()
  local want, edits = {}, {}
  for _, s in ipairs(m:spans()) do
    local new = {}
    for i = 1, s.count do
      vim.list_extend(new, { quilt[s.q_start + i]:upper(), "Y" })
    end
    vim.list_extend(want, new)
    edits[#edits + 1] = m:replace(s.id, 0, s.count, new)
  end
  eq(edits, {
    { src = 1, first = 2, last = 5, lines = { "A2", "Y", "A3", "Y", "A4", "Y" } },
    { src = 1, first = 11, last = 13, lines = { "A8", "Y", "A9", "Y" } },
    { src = 2, first = 0, last = 2, lines = { "B0", "Y", "B1", "Y" } },
  })
  apply_src(srcs, edits)
  eq(view(m, srcs), want)
  eq(srcs[2], { "B0", "Y", "B1", "Y", "b2", "b3" })
end

T["replace"]["J across an edge keeps the joined line in the first span"] = function()
  local m, srcs = fixture()
  local a, b = unpack(ids(m))
  local edits = { m:replace(a, 2, 3, { "a4 a8" }), m:replace(b, 0, 1, {}) }
  eq(edits, {
    { src = 1, first = 4, last = 5, lines = { "a4 a8" } },
    { src = 1, first = 8, last = 9, lines = {} },
  })
  apply_src(srcs, edits)
  eq(view(m, srcs), { "a2", "a3", "a4 a8", "a9", "b0", "b1" })
end

T["replace"]["replace calls stay valid on the state each one left"] = function()
  local m, srcs, quilt = fixture()
  local a, b, c = unpack(ids(m))
  local steps = {
    { a, 0, 3, { "p" } },
    { b, 1, 2, { "q", "r", "s" } },
    { c, 0, 2, {} },
    { b, 0, 4, {} },
    { b, 0, 0, { "t" } },
    { c, 0, 0, { "u", "" } },
    { a, 1, 1, { "v" } },
  }
  for _, st in ipairs(steps) do
    local s = m:find(st[1])
    quilt = splice(quilt, s.q_start + st[2], s.q_start + st[3], st[4])
    apply_src(srcs, { m:replace(st[1], st[2], st[3], st[4]) })
    eq(view(m, srcs), quilt)
    eq(m:line_count(), #quilt)
  end
end

T["replace"]["replace with an unknown id returns nil"] = function()
  local m = fixture()
  eq(m:replace(999, 0, 0, { "x" }), nil)
  eq(shape(m), { { 1, 2, 3 }, { 1, 8, 2 }, { 2, 0, 2 } })
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

T["apply_source_change"]["a collapsed span outside the change only shifts"] = function()
  local m, _, b = collapsed()
  eq(m:apply_source_change(1, 0, 1, { "p", "q" }), {})
  eq(m:find(b).src_start, 9)
  eq(m:apply_source_change(1, 9, 9, { "x" }), {})
  eq(m:find(b).src_start, 10)
  eq(m:apply_source_change(1, 10, 11, { "z" }), {})
  eq(m:find(b).src_start, 10)
end

T["apply_source_change"]["a collapsed span inside the change is removed"] = function()
  local m, _, b = collapsed()
  eq(m:apply_source_change(1, 6, 10, { "z" }), {})
  eq(m:find(b), nil)
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 2 } })
end

T["apply_source_change"]["a collapsed span at the edge of a change that grows a span is removed"] = function()
  local m, srcs, b = collapsed()
  local quilt = view(m, srcs)
  srcs[1] = splice(srcs[1], 4, 8, { "z" })
  local edits = m:apply_source_change(1, 4, 8, { "z" })
  eq(edits, { { first = 2, last = 3, lines = { "z" } } })
  eq(m:find(b), nil)
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 2 } })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["apply_source_change"]["a collapsed span inside the change does not count as growing a span"] = function()
  local m, srcs, b = collapsed()
  local a = m:spans()[1].id
  apply_src(srcs, { m:replace(a, 0, 3, {}) })
  eq(m:find(b).src_start, 5)
  eq(m:apply_source_change(1, 2, 6, { "z" }), {})
  eq(m:find(b), nil)
  eq(m:find(a).src_start, 2)
end

T["apply_source_change"]["a collapsed span at the edge of a change that touches no span stays"] = function()
  local m, _, b = collapsed()
  eq(m:apply_source_change(1, 6, 8, {}), {})
  eq(m:find(b).src_start, 6)
  eq(m:apply_source_change(1, 6, 7, { "x", "y" }), {})
  eq(m:find(b).src_start, 6)
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

T["expand / shrink / remove / clamp"]["expand grows a collapsed span"] = function()
  local m, srcs, b = collapsed()
  local quilt = view(m, srcs)
  local edits = m:expand(b, 1, 1, #srcs[1])
  eq(edits, {
    { first = 3, last = 3, src = 1, src_first = 7, src_last = 8 },
    { first = 4, last = 4, src = 1, src_first = 8, src_last = 9 },
  })
  eq(shape(m), { { 1, 2, 3 }, { 1, 7, 2 }, { 2, 0, 2 } })
  eq(apply_q(quilt, srcs, edits), view(m, srcs))
end

T["expand / shrink / remove / clamp"]["shrink and remove of a collapsed span change no rows"] = function()
  local m, _, b = collapsed()
  eq(m:shrink(b, 1, 1), {})
  eq(m:find(b).count, 0)
  eq(m:remove(b), {})
  eq(shape(m), { { 1, 2, 3 }, { 2, 0, 2 } })
end

T["expand / shrink / remove / clamp"]["clamp drops collapsed spans past the new end"] = function()
  local m, _, b = collapsed()
  eq(m:clamp(1, 8), { { first = 0, last = 3, src = 1, src_first = 2, src_last = 5 } })
  eq(m:find(b).src_start, 8)
  eq(m:clamp(1, 7), { { first = 0, last = 3, src = 1, src_first = 2, src_last = 5 } })
  eq(m:find(b), nil)
end

return T
