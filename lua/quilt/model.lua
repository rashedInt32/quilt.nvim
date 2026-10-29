-- The excerpt model: which source rows each quilt row shows. Plain Lua, no Neovim.
--
-- All rows are 0-based and ranges end-exclusive. Spans live in quilt order as
-- { id, src, start, count }; quilt rows are derived by summing counts. Every
-- method that changes state returns the edits that bring the other side in
-- line, valid when applied in list order.
local M = {}

---@class quilt.Range
---@field src integer
---@field start integer
---@field count integer

---@class quilt.Span
---@field id integer
---@field src integer
---@field src_start integer
---@field q_start integer
---@field count integer

---@class quilt.SrcEdit
---@field src integer
---@field first integer
---@field last integer
---@field lines string[]

---@class quilt.QEdit
---@field first integer
---@field last integer
---@field lines string[]?
---@field src integer?
---@field src_first integer?
---@field src_last integer?

---@class quilt.Model
---@field private _spans { id: integer, src: integer, start: integer, count: integer }[]
---@field private _next_id integer
local Model = {}
Model.__index = Model

local function copy(lines, from, to)
  local out = {}
  for i = from or 1, to or #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function snapshot(s, q)
  return { id = s.id, src = s.src, src_start = s.start, q_start = q, count = s.count }
end

local function read(q, src, first, last)
  return { first = q, last = q, src = src, src_first = first, src_last = last }
end

--- Build a model from ranges. Groups by source in first-seen order, sorts
--- and merges each group, drops ranges with count < 1.
---@param ranges quilt.Range[]
---@return quilt.Model
function M.new(ranges)
  local self = setmetatable({ _spans = {}, _next_id = 1 }, Model)
  local order, groups = {}, {}
  for _, r in ipairs(ranges or {}) do
    if r.count >= 1 then
      if not groups[r.src] then
        groups[r.src] = {}
        order[#order + 1] = r.src
      end
      table.insert(groups[r.src], { start = r.start, count = r.count })
    end
  end
  for _, src in ipairs(order) do
    local g = groups[src]
    table.sort(g, function(a, b)
      return a.start < b.start
    end)
    local cur
    for _, r in ipairs(g) do
      if cur and r.start <= cur.start + cur.count then
        cur.count = math.max(cur.count, r.start + r.count - cur.start)
      else
        cur = { id = self._next_id, src = src, start = r.start, count = r.count }
        self._next_id = self._next_id + 1
        self._spans[#self._spans + 1] = cur
      end
    end
  end
  return self
end

--- Index and quilt row of the span with this id.
---@private
function Model:_index(id)
  local q = 0
  for i, s in ipairs(self._spans) do
    if s.id == id then
      return i, q
    end
    q = q + s.count
  end
end

--- Snapshot of every span in quilt order. Fresh tables.
---@return quilt.Span[]
function Model:spans()
  local out, q = {}, 0
  for i, s in ipairs(self._spans) do
    out[i] = snapshot(s, q)
    q = q + s.count
  end
  return out
end

---@return integer
function Model:line_count()
  local n = 0
  for _, s in ipairs(self._spans) do
    n = n + s.count
  end
  return n
end

--- The span showing quilt row `qrow` and the source row it shows.
---@param qrow integer
---@return quilt.Span?, integer?
function Model:locate(qrow)
  local q = 0
  for _, s in ipairs(self._spans) do
    if qrow >= q and qrow < q + s.count then
      return snapshot(s, q), s.start + qrow - q
    end
    q = q + s.count
  end
end

--- The quilt row showing `src_row` of `src`, or nil when no span shows it.
---@param src integer
---@param src_row integer
---@return integer?
function Model:to_quilt(src, src_row)
  local q = 0
  for _, s in ipairs(self._spans) do
    if s.src == src and src_row >= s.start and src_row < s.start + s.count then
      return q + src_row - s.start
    end
    q = q + s.count
  end
end

---@param id integer
---@return quilt.Span?
function Model:find(id)
  local i, q = self:_index(id)
  return i and snapshot(self._spans[i], q)
end

--- Quilt rows [first, last) became `lines`. Returns the source edits.
--- Each touched span gets as many new lines as it lost rows, in quilt order,
--- and the last one also gets any left over. `prefer` ("above" | "below",
--- default "below") picks the span for a pure insertion at a boundary.
---@param first integer
---@param last integer
---@param lines string[]
---@param prefer? "above"|"below"
---@return quilt.SrcEdit[]
function Model:apply_quilt_change(first, last, lines, prefer)
  local spans, k, edits = self._spans, #lines, {}
  if first == last then
    if k == 0 then
      return edits
    end
    local q = 0
    for i, s in ipairs(spans) do
      local e = q + s.count
      local inside = first >= q and first < e
      local append = first == e and (i == #spans or prefer == "above")
      if inside or append then
        local row = s.start + first - q
        edits[1] = { src = s.src, first = row, last = row, lines = copy(lines) }
        s.count = s.count + k
        for j = i + 1, #spans do
          if spans[j].src == s.src then
            spans[j].start = spans[j].start + k
          end
        end
        break
      end
      q = e
    end
    return edits
  end

  -- Lines are dealt out row for row; the last touched span takes the rest.
  local tail, q = nil, 0
  for i, s in ipairs(spans) do
    if q < last and q + s.count > first then
      tail = i
    end
    q = q + s.count
  end
  -- Spans of one source come in row order, so earlier edits of a source sit
  -- above later ones and `off` shifts the later rows.
  local off, out, used = {}, {}, 0
  q = 0
  for i, s in ipairs(spans) do
    local e = q + s.count
    local d = off[s.src] or 0
    s.start = s.start + d
    if e > first and q < last then
      local lo = math.max(first, q)
      local removed = math.min(last, e) - lo
      local take = i == tail and k - used or math.min(removed, k - used)
      local new = copy(lines, used + 1, used + take)
      used = used + take
      local row = s.start + lo - q
      edits[#edits + 1] = { src = s.src, first = row, last = row + removed, lines = new }
      s.count = s.count - removed + take
      off[s.src] = d + take - removed
    end
    if s.count > 0 then
      out[#out + 1] = s
    end
    q = e
  end
  self._spans = out
  return edits
end

--- Source rows [first, last) of `src` became `lines`. Returns the quilt edits.
--- They always carry literal lines.
---@param src integer
---@param first integer
---@param last integer
---@param lines string[]
---@return quilt.QEdit[]
function Model:apply_source_change(src, first, last, lines)
  local k, edits = #lines, {}
  local delta = k - (last - first)
  if first == last and k == 0 then
    return edits
  end
  local merged, old_end, qf, ql
  local out, q = {}, 0
  for _, s in ipairs(self._spans) do
    local keep = true
    if s.src == src then
      local a, b = s.start, s.start + s.count
      if first == last then
        if first <= a then
          s.start = a + k
        elseif first < b then
          local row = q + first - a
          edits[1] = { first = row, last = row, lines = copy(lines) }
          s.count = s.count + k
        end
      elseif last <= a then
        s.start = a + delta
      elseif first < b then
        if merged then
          keep = false
        else
          merged = s
          qf = q + math.max(0, first - a)
          s.start = math.min(a, first)
        end
        ql = q + math.min(b, last) - a
        old_end = math.max(b, last)
      end
      q = q + b - a
    else
      q = q + s.count
    end
    if keep then
      out[#out + 1] = s
    end
  end
  if merged then
    merged.count = old_end + delta - merged.start
    edits[1] = { first = qf, last = ql, lines = copy(lines) }
    if merged.count == 0 then
      for i, s in ipairs(out) do
        if s == merged then
          table.remove(out, i)
          break
        end
      end
    end
  end
  self._spans = out
  return edits
end

--- Grow a span by source rows, clamped to [0, src_line_count). Every span of
--- the same source the new range meets merges in; the topmost keeps its id.
--- Quilt only: never mirror these edits into the source.
---@param id integer
---@param above integer
---@param below integer
---@param src_line_count integer
---@return quilt.QEdit[]
function Model:expand(id, above, below, src_line_count)
  local i, q = self:_index(id)
  if not i then
    return {}
  end
  local spans, edits = self._spans, {}
  local s = spans[i]
  local na = math.min(s.start, math.max(0, s.start - math.max(0, above)))
  local nb = math.max(s.start + s.count, math.min(src_line_count, s.start + s.count + math.max(0, below)))
  local lo, hi = i, i
  while lo > 1 and spans[lo - 1].src == s.src and na <= spans[lo - 1].start + spans[lo - 1].count do
    lo = lo - 1
    q = q - spans[lo].count
    na = math.min(na, spans[lo].start)
  end
  while hi < #spans and spans[hi + 1].src == s.src and nb >= spans[hi + 1].start do
    hi = hi + 1
    nb = math.max(nb, spans[hi].start + spans[hi].count)
  end

  -- Read only the gaps, so rows already shown stay untouched.
  local row, cur = q, na
  for j = lo, hi do
    local x = spans[j]
    if cur < x.start then
      edits[#edits + 1] = read(row, s.src, cur, x.start)
      row = row + x.start - cur
    end
    row, cur = row + x.count, x.start + x.count
  end
  if cur < nb then
    edits[#edits + 1] = read(row, s.src, cur, nb)
  end

  spans[lo].start, spans[lo].count = na, nb - na
  for _ = lo + 1, hi do
    table.remove(spans, lo + 1)
  end
  return edits
end

--- Drop rows from the top and bottom of a span, keeping at least one. When
--- both sides ask for more than there is, they share what can go.
--- Quilt only: never mirror these edits into the source.
---@param id integer
---@param above integer
---@param below integer
---@return quilt.QEdit[]
function Model:shrink(id, above, below)
  local i, q = self:_index(id)
  if not i then
    return {}
  end
  local s, edits = self._spans[i], {}
  above, below = math.max(0, above), math.max(0, below)
  local room = s.count - 1
  local ta, tb = above, below
  if above + below > room then
    ta = math.min(above, math.max(room - below, math.floor(room / 2)))
    tb = room - ta
  end
  if ta > 0 then
    edits[#edits + 1] = { first = q, last = q + ta, lines = {} }
  end
  if tb > 0 then
    local e = q + s.count - ta
    edits[#edits + 1] = { first = e - tb, last = e, lines = {} }
  end
  s.start = s.start + ta
  s.count = s.count - ta - tb
  return edits
end

--- Drop a span and its quilt rows. Quilt only: the source keeps its lines.
---@param id integer
---@return quilt.QEdit[]
function Model:remove(id)
  local i, q = self:_index(id)
  if not i then
    return {}
  end
  local s = table.remove(self._spans, i)
  return { { first = q, last = q + s.count, lines = {} } }
end

--- `src` was reloaded and now has `src_line_count` rows. Spans past the end
--- shrink or go, and every remaining span of `src` is reread.
---@param src integer
---@param src_line_count integer
---@return quilt.QEdit[]
function Model:clamp(src, src_line_count)
  local out, edits, q = {}, {}, 0
  for _, s in ipairs(self._spans) do
    local c = s.count
    if s.src == src then
      local keep = math.min(c, src_line_count - s.start)
      if keep <= 0 then
        edits[#edits + 1] = { first = q, last = q + c, lines = {} }
        c = 0
      else
        edits[#edits + 1] = { first = q, last = q + c, src = src, src_first = s.start, src_last = s.start + keep }
        s.count, c = keep, keep
        out[#out + 1] = s
      end
    else
      out[#out + 1] = s
    end
    q = q + c
  end
  self._spans = out
  return edits
end

return M
