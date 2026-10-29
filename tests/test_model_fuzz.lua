-- Randomised model check against a plain-array simulator. QUILT_SEED=n reproduces a run.
local M = require("quilt.model")

local T = MiniTest.new_set()

local STEPS = 2000
local SEED = tonumber(os.getenv("QUILT_SEED") or "") or 20261029

-- Park-Miller LCG: exact in doubles, the same on every Lua.
local function lcg(seed)
  local state = seed % 2147483646 + 1
  return function(lo, hi)
    state = state * 16807 % 2147483647
    return lo + state % (hi - lo + 1)
  end
end

local function splice(t, first, last, new)
  local out = {}
  for i = 1, first do
    out[#out + 1] = t[i]
  end
  for _, l in ipairs(new) do
    out[#out + 1] = l
  end
  for i = last + 1, #t do
    out[#out + 1] = t[i]
  end
  return out
end

local function slice(t, first, last)
  local out = {}
  for i = first + 1, last do
    out[#out + 1] = t[i]
  end
  return out
end

local function fail(w, msg)
  error(
    string.format(
      "QUILT_SEED=%d scenario=%s step=%d: %s\nop: %s\nbefore: %s\nafter: %s",
      SEED,
      w.name,
      w.step,
      msg,
      vim.inspect(w.op),
      vim.inspect(w.before),
      vim.inspect({ srcs = w.srcs, quilt = w.quilt, spans = w.m:spans() })
    ),
    0
  )
end

-- Every line ever made is unique, except "" which edits throw in on purpose.
local function line(w)
  if w.r(1, 6) == 1 then
    return ""
  end
  w.counter = w.counter + 1
  return "l" .. w.counter
end

local function new_lines(w, n)
  local out = {}
  for i = 1, n do
    out[i] = line(w)
  end
  return out
end

-- Fresh sources and ranges. The quilt is read through the first spans.
local function reset(w)
  w.srcs = {}
  for s = 1, w.r(1, 4) do
    w.srcs[s] = new_lines(w, w.r(1, 40))
  end
  local ranges, want = {}, {}
  for _ = 1, w.r(1, 6) do
    local s = w.r(1, #w.srcs)
    local start = w.r(0, #w.srcs[s] - 1)
    local count = w.r(0, math.min(6, #w.srcs[s] - start))
    ranges[#ranges + 1] = { src = s, start = start, count = count }
    for row = start, start + count - 1 do
      want[s .. ":" .. row] = true
    end
  end
  w.m = M.new(ranges)
  w.quilt = {}
  local got = {}
  for _, sp in ipairs(w.m:spans()) do
    for row = sp.src_start, sp.src_start + sp.count - 1 do
      w.quilt[#w.quilt + 1] = w.srcs[sp.src][row + 1]
      got[sp.src .. ":" .. row] = true
    end
  end
  if not vim.deep_equal(got, want) then
    fail(w, "new does not cover exactly the rows of its ranges")
  end
  if #w.quilt == 0 then
    return reset(w)
  end
end

local function apply_src_edits(w, edits)
  for i, e in ipairs(edits) do
    local src = w.srcs[e.src]
    if not src or e.first < 0 or e.first > e.last or e.last > #src or type(e.lines) ~= "table" then
      fail(w, "bad SrcEdit #" .. i)
    end
    w.srcs[e.src] = splice(src, e.first, e.last, e.lines)
  end
end

local function apply_q_edits(w, edits)
  for i, e in ipairs(edits) do
    if e.first < 0 or e.first > e.last or e.last > #w.quilt then
      fail(w, "bad QEdit #" .. i)
    end
    local new = e.lines
    if not new then
      local src = w.srcs[e.src]
      if not src or e.src_first < 0 or e.src_first > e.src_last or e.src_last > #src then
        fail(w, "bad QEdit source read #" .. i)
      end
      new = slice(src, e.src_first, e.src_last)
    end
    w.quilt = splice(w.quilt, e.first, e.last, new)
  end
end

-- Invariants 1 to 4 plus the queries, all against the simulator's arrays.
local function check(w)
  local spans, q, seen, ids, last_src = w.m:spans(), 0, {}, {}, nil
  local ends = {}
  for i, sp in ipairs(spans) do
    if sp.count < 0 then
      fail(w, "span " .. i .. " has count < 0")
    end
    if sp.q_start ~= q then
      fail(w, "span " .. i .. " has the wrong q_start")
    end
    if ids[sp.id] then
      fail(w, "duplicate id " .. sp.id)
    end
    ids[sp.id] = true
    if sp.src ~= last_src then
      if seen[sp.src] then
        fail(w, "spans of source " .. sp.src .. " are not contiguous")
      end
      seen[sp.src] = true
    elseif sp.src_start < ends[sp.src] then
      fail(w, "spans of source " .. sp.src .. " overlap or are out of order")
    end
    last_src, ends[sp.src] = sp.src, sp.src_start + sp.count
    local src = w.srcs[sp.src]
    if sp.src_start < 0 or sp.src_start + sp.count > #src then
      fail(w, "span " .. i .. " is outside its source")
    end
    for j = 0, sp.count - 1 do
      if w.quilt[q + j + 1] ~= src[sp.src_start + j + 1] then
        fail(w, "quilt row " .. (q + j) .. " is not its source row")
      end
      local at, row = w.m:locate(q + j)
      if not at or at.id ~= sp.id or row ~= sp.src_start + j then
        fail(w, "locate is wrong at " .. (q + j))
      end
      if w.m:to_quilt(sp.src, sp.src_start + j) ~= q + j then
        fail(w, "to_quilt is wrong at " .. (q + j))
      end
    end
    q = q + sp.count
  end
  if q ~= #w.quilt or w.m:line_count() ~= q then
    fail(w, "line count is wrong")
  end
  if w.m:locate(q) or w.m:locate(-1) then
    fail(w, "locate past the end")
  end
end

local function shown(w)
  local set = {}
  for _, l in ipairs(w.quilt) do
    if l ~= "" then
      set[l] = true
    end
  end
  return set
end

-- Source rows no span shows, per source, in order.
local function hidden(w)
  local out = {}
  for s, src in ipairs(w.srcs) do
    local mask = {}
    for _, sp in ipairs(w.m:spans()) do
      if sp.src == s then
        for row = sp.src_start, sp.src_start + sp.count - 1 do
          mask[row] = true
        end
      end
    end
    out[s] = {}
    for row = 0, #src - 1 do
      if not mask[row] then
        table.insert(out[s], src[row + 1])
      end
    end
  end
  return out
end

-- Half the edits start at or next to an edge, where the bugs live.
local function position(w, edges, n, back)
  if #edges == 0 or w.r(0, 1) == 0 then
    return w.r(0, n)
  end
  return math.max(0, math.min(n, edges[w.r(1, #edges)] + w.r(-back, 1)))
end

-- One replace call, the way the sync layer makes them, checked on its own.
local function replace_one(w, sp, rf, rl, lines)
  local spans, hid = w.m:spans(), hidden(w)
  w.quilt = splice(w.quilt, sp.q_start + rf, sp.q_start + rl, lines)
  local e = w.m:replace(sp.id, rf, rl, vim.deepcopy(lines))
  local want = { src = sp.src, first = sp.src_start + rf, last = sp.src_start + rl, lines = lines }
  if not vim.deep_equal(e, want) then
    fail(w, "replace returned the wrong SrcEdit")
  end
  apply_src_edits(w, { e })
  check(w)
  if not vim.deep_equal(hidden(w), hid) then
    fail(w, "replace changed source rows no span shows")
  end
  local after = w.m:spans()
  if #after ~= #spans then
    fail(w, "replace added or dropped a span")
  end
  for i, x in ipairs(spans) do
    local count = x.id == sp.id and x.count - (rl - rf) + #lines or x.count
    if after[i].id ~= x.id or after[i].count ~= count then
      fail(w, "replace changed the wrong span")
    end
  end
end

-- Random rows of a random span. Aims at collapsed spans a third of the time,
-- and sometimes deletes a whole span so it collapses.
local function replace(w)
  local spans, folded = w.m:spans(), {}
  for _, x in ipairs(spans) do
    if x.count == 0 then
      folded[#folded + 1] = x
    end
  end
  local sp = (#folded > 0 and w.r(1, 3) == 1) and folded[w.r(1, #folded)] or spans[w.r(1, #spans)]
  local rf, rl, lines
  if w.r(1, 5) == 1 then
    rf, rl, lines = 0, sp.count, {}
  else
    rf = w.r(0, sp.count)
    rl = w.r(rf, math.min(sp.count, rf + 4))
    lines = new_lines(w, w.r(0, 4))
  end
  w.op = { "replace", sp.id, rf, rl, lines }
  replace_one(w, sp, rf, rl, lines)
end

-- A flush: one replace per span, top-down, each on the state the last left.
local function flush(w)
  w.op = { "flush" }
  for _, x in ipairs(w.m:spans()) do
    local sp = w.m:find(x.id)
    local rf = w.r(0, sp.count)
    local rl = w.r(rf, sp.count)
    local lines = new_lines(w, w.r(0, 4))
    table.insert(w.op, { sp.id, rf, rl, lines })
    replace_one(w, sp, rf, rl, lines)
  end
end

local function source_edit(w, aim)
  local s = aim and aim.src or w.r(1, #w.srcs)
  for _, sp in ipairs(aim and {} or w.m:spans()) do
    if sp.count == 0 and w.r(0, 1) == 0 then
      s, aim = sp.src, sp
    end
  end
  local n, edges = #w.srcs[s], {}
  for _, sp in ipairs(w.m:spans()) do
    if sp.src == s then
      vim.list_extend(edges, { sp.src_start, sp.src_start + sp.count })
    end
  end
  -- Around a collapsed span, most of the time, when there is one.
  if aim and w.r(1, 4) > 1 then
    edges = { aim.src_start }
  end
  local first = position(w, edges, n, 2)
  local last = w.r(1, 3) == 1 and first or math.min(n, first + w.r(0, 4))
  local lines = new_lines(w, w.r(0, 4))
  w.op = { "source", s, first, last, lines }
  local touched = false
  for _, sp in ipairs(w.m:spans()) do
    local a, b = sp.src_start, sp.src_start + sp.count
    if
      sp.src == s
      and sp.count > 0
      and ((first == last and a < first and first < b) or (first < last and a < last and b > first))
    then
      touched = true
    end
  end
  -- Collapsed spans go when inside the change, or at its edge when it grows
  -- a span. Elsewhere they only shift.
  local fates = {}
  for _, sp in ipairs(w.m:spans()) do
    if sp.src == s and sp.count == 0 then
      local c, at = sp.src_start, sp.src_start
      local gone = first < last and ((first < c and c < last) or (touched and (c == first or c == last)))
      if (first == last and first <= c) or (first < last and last <= c) then
        at = c + #lines - (last - first)
      end
      fates[#fates + 1] = { id = sp.id, at = not gone and at or nil }
    end
  end
  local before, quilt = shown(w), w.quilt
  for _, l in ipairs(slice(w.srcs[s], first, last)) do
    before[l] = nil
  end
  w.srcs[s] = splice(w.srcs[s], first, last, lines)
  apply_q_edits(w, w.m:apply_source_change(s, first, last, vim.deepcopy(lines)))
  check(w)
  local after = shown(w)
  for l in pairs(before) do
    if not after[l] then
      fail(w, "a source edit hid a row it did not touch: " .. l)
    end
  end
  for _, l in ipairs(lines) do
    if l ~= "" and (after[l] == true) ~= touched then
      fail(w, touched and "a change that touches a span is not shown" or "a change outside every span is shown")
    end
  end
  if not touched and not vim.deep_equal(quilt, w.quilt) then
    fail(w, "a change outside every span changed the quilt")
  end
  for _, f in ipairs(fates) do
    local now = w.m:find(f.id)
    if (now and now.src_start) ~= f.at or (now and now.count ~= 0) then
      fail(w, "collapsed span " .. f.id .. " should be " .. (f.at and ("at " .. f.at) or "gone"))
    end
  end
end

-- Collapse a span, edit its source around it, then bring rows back.
local function fold_cycle(w)
  local spans, open = w.m:spans(), {}
  for _, x in ipairs(spans) do
    if x.count > 0 then
      open[#open + 1] = x
    end
  end
  if #open == 0 then
    return replace(w)
  end
  local sp = open[w.r(1, #open)]
  w.op = { "fold", sp.id }
  replace_one(w, sp, 0, sp.count, {})
  for _ = 1, w.r(1, 3) do
    local now = w.m:find(sp.id)
    if not now then
      break
    end
    source_edit(w, now)
  end
  local now = w.m:find(sp.id)
  if now and now.count == 0 then
    local lines = new_lines(w, w.r(1, 4))
    w.op = { "unfold", sp.id, lines }
    replace_one(w, now, 0, 0, lines)
  end
end

local function pick_span(w)
  local spans = w.m:spans()
  return spans[w.r(1, #spans)]
end

local function expand(w)
  local sp = pick_span(w)
  local above, below, n = w.r(0, 4), w.r(0, 4), #w.srcs[sp.src]
  w.op = { "expand", sp.id, above, below, n }
  local srcs = vim.deepcopy(w.srcs)
  apply_q_edits(w, w.m:expand(sp.id, above, below, n))
  check(w)
  for row = math.max(0, sp.src_start - above), math.min(n, sp.src_start + sp.count + below) - 1 do
    if not w.m:to_quilt(sp.src, row) then
      fail(w, "expand left out row " .. row)
    end
  end
  if not vim.deep_equal(srcs, w.srcs) then
    fail(w, "expand changed a source")
  end
end

local function shrink(w)
  local sp = pick_span(w)
  local above, below = w.r(0, 4), w.r(0, 4)
  w.op = { "shrink", sp.id, above, below }
  apply_q_edits(w, w.m:shrink(sp.id, above, below))
  check(w)
  local now = w.m:find(sp.id)
  local want = sp.count <= 1 and sp.count or math.max(1, sp.count - above - below)
  if not now or now.count ~= want then
    fail(w, "shrink kept the wrong number of rows")
  end
  if now.src_start < sp.src_start or now.src_start + now.count > sp.src_start + sp.count then
    fail(w, "shrink moved outside the old span")
  end
end

local function remove(w)
  local sp = pick_span(w)
  w.op = { "remove", sp.id }
  local n = #w.quilt
  apply_q_edits(w, w.m:remove(sp.id))
  check(w)
  if w.m:find(sp.id) or #w.quilt ~= n - sp.count then
    fail(w, "remove left the span or took the wrong rows")
  end
end

-- A reload: the source gets new text of a new length, then clamp.
local function reload(w)
  local s = w.r(1, #w.srcs)
  local n = w.r(0, 1) == 0 and w.r(1, math.max(1, #w.srcs[s])) or w.r(1, 40)
  -- Sometimes end the file right at a collapsed span, or just before it.
  for _, sp in ipairs(w.m:spans()) do
    if sp.src == s and sp.count == 0 and w.r(0, 1) == 0 then
      n = math.max(1, sp.src_start - w.r(0, 1))
    end
  end
  local lines = new_lines(w, n)
  w.op = { "reload", s, n }
  w.srcs[s] = lines
  local spans = w.m:spans()
  apply_q_edits(w, w.m:clamp(s, n))
  check(w)
  for _, sp in ipairs(spans) do
    local stays = sp.src ~= s or sp.src_start < n or (sp.count == 0 and sp.src_start == n)
    if (w.m:find(sp.id) ~= nil) ~= stays then
      fail(w, "clamp kept or dropped the wrong span " .. sp.id)
    end
  end
end

local function run(name, salt, ops)
  local w = { name = name, r = lcg(SEED + salt), counter = 0, step = 0 }
  reset(w)
  check(w)
  for step = 1, STEPS do
    w.step = step
    w.before = { srcs = vim.deepcopy(w.srcs), quilt = w.quilt, spans = w.m:spans() }
    ops[w.r(1, #ops)](w)
    local spans = w.m:spans()
    if #spans == 0 or (w.m:line_count() == 0 and w.r(1, 4) == 1) or w.r(1, 150) == 1 then
      reset(w)
      check(w)
    end
  end
end

T["2000 random replace calls keep every invariant"] = function()
  run("replace", 1, { replace, replace, replace, flush })
end

T["2000 random source edits keep every invariant"] = function()
  run("source", 2, { source_edit })
end

T["2000 mixed steps keep every invariant"] = function()
  run("mixed", 3, {
    replace,
    replace,
    flush,
    fold_cycle,
    fold_cycle,
    source_edit,
    source_edit,
    source_edit,
    expand,
    shrink,
    remove,
    reload,
  })
end

T["the same seed gives the same run"] = function()
  local a, b = lcg(SEED), lcg(SEED)
  for _ = 1, 100 do
    MiniTest.expect.equality(a(0, 1000), b(0, 1000))
  end
end

return T
