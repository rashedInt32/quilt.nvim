-- The excerpt model: which source rows each quilt row shows. Plain Lua, no Neovim.
--
-- All rows are 0-based and ranges end-exclusive. Spans live in quilt order as
-- { id, src, start, count }; quilt rows are derived by summing counts. A span
-- with count 0 is collapsed: it keeps its id and place so undo can refill it.
-- Every method that changes state returns the edits that bring the other side
-- in line, valid when applied in list order.
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

--- Rows [rel_first, rel_last) of a span, counted from its first row, became
--- `lines`. Returns the source edit; the span may collapse to 0 rows.
---@param id integer
---@param rel_first integer
---@param rel_last integer
---@param lines string[]
---@return quilt.SrcEdit?
function Model:replace(id, rel_first, rel_last, lines)
  local i = self:_index(id)
  if not i then
    return nil
  end
  local spans = self._spans
  local s = spans[i]
  local delta = #lines - (rel_last - rel_first)
  s.count = s.count + delta
  for j = i + 1, #spans do
    if spans[j].src == s.src then
      spans[j].start = spans[j].start + delta
    end
  end
  return { src = s.src, first = s.start + rel_first, last = s.start + rel_last, lines = copy(lines) }
end

--- Source rows [first, last) of `src` became `lines`. Returns the quilt edits.
--- They always carry literal lines. A collapsed span inside the change, or at
--- its edge when the change grows a span, goes; elsewhere it only shifts.
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
  local grows = false
  for _, s in ipairs(self._spans) do
    if s.src == src and s.count > 0 and s.start < last and s.start + s.count > first then
      grows = true
    end
  end
  local merged, old_end, qf, ql
  local out, q = {}, 0
  for _, s in ipairs(self._spans) do
    local keep, c = true, s.count
    local a, b = s.start, s.start + c
    local mine = s.src == src
    if mine and first == last then
      if first <= a then
        s.start = a + k
      elseif first < b then
        local row = q + first - a
        edits[1] = { first = row, last = row, lines = copy(lines) }
        s.count = c + k
      end
    elseif mine and c == 0 then
      if (first < a and a < last) or (grows and (a == first or a == last)) then
        keep = false
      elseif last <= a then
        s.start = a + delta
      end
    elseif mine and last <= a then
      s.start = a + delta
    elseif mine and first < b then
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
    if keep then
      out[#out + 1] = s
    end
    q = q + c
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
  if s.count <= 1 then
    return edits
  end
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
  return s.count > 0 and { { first = q, last = q + s.count, lines = {} } } or {}
end

--- `src` was reloaded and now has `src_line_count` rows. Spans past the end
--- shrink or go, and every remaining span of `src` is reread. A collapsed
--- span stays while its row is at most the new line count.
---@param src integer
---@param src_line_count integer
---@return quilt.QEdit[]
function Model:clamp(src, src_line_count)
  local out, edits, q = {}, {}, 0
  for _, s in ipairs(self._spans) do
    local c = s.count
    if s.src == src and c == 0 then
      if s.start <= src_line_count then
        out[#out + 1] = s
      end
    elseif s.src == src then
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
