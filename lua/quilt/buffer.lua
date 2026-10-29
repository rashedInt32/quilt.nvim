-- The quilt buffer: owns the model and keeps the quilt and its sources in sync both ways.
local Model = require("quilt.model")
local decor = require("quilt.decor")

local api = vim.api
local M = {}

---@type table<integer, table>
local states = {}
local counter = 0
local RENDER_DELAY = 40

local function notify(msg, level)
  vim.notify("quilt: " .. msg, level or vim.log.levels.WARN)
end

local function alive(st)
  return st and not st.dead and api.nvim_buf_is_valid(st.qbuf)
end

local NS = api.nvim_create_namespace("quilt.marks")

-- Quilt edits may point at source rows. Read them now, while the rows still hold the text the model saw.
local function literal(e)
  if e.lines then
    return e.lines
  end
  return api.nvim_buf_get_lines(e.src, e.src_first, e.src_last, false)
end

-- Our edits come from scheduled callbacks, which Neovim would join to the user's last undo step.
local function break_undo(buf)
  api.nvim_buf_call(buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
  end)
end

local function set_lines(st, buf, first, last, lines)
  st.applying[buf] = true
  local ok, err = pcall(api.nvim_buf_set_lines, buf, first, last, false, lines)
  st.applying[buf] = nil
  return ok, err
end

-- View edits (expand, shrink, drop, reread) can't be undone without undo deleting source rows, so they clear
-- the quilt's undo history. Each source keeps its own.
local function without_undo(st, fn)
  local levels = vim.bo[st.qbuf].undolevels
  vim.bo[st.qbuf].undolevels = -1
  fn()
  vim.bo[st.qbuf].undolevels = levels
end

local function sync_modified(st)
  if not alive(st) then
    return
  end
  local any = false
  for src in pairs(st.touched) do
    if api.nvim_buf_is_loaded(src) and vim.bo[src].modified then
      any = true
      break
    end
  end
  vim.bo[st.qbuf].modified = any
end

local function render_now(st)
  if alive(st) then
    decor.render(st.qbuf, st.model:spans(), {})
  end
end

local function schedule_render(st)
  st.timer:stop()
  st.timer:start(
    RENDER_DELAY,
    0,
    vim.schedule_wrap(function()
      render_now(st)
    end)
  )
end

local function mark_pos(st, span)
  local id = st.marks[span.id]
  if id then
    local m = api.nvim_buf_get_extmark_by_id(st.qbuf, NS, id, {})
    if m[1] then
      return m[1], m[2]
    end
  end
end

-- Put each span's mark at its q_start. A span collapsed at the very end sits at the end of the last line.
local function place_marks(st)
  local n = api.nvim_buf_line_count(st.qbuf)
  local last_len = #(api.nvim_buf_get_lines(st.qbuf, n - 1, n, false)[1] or "")
  local seen = {}
  for _, s in ipairs(st.model:spans()) do
    seen[s.id] = true
    local row, col = s.q_start, 0
    if row >= n then
      row, col = n - 1, last_len
    end
    local r, c = mark_pos(st, s)
    if r ~= row or c ~= col then
      st.marks[s.id] = api.nvim_buf_set_extmark(st.qbuf, NS, row, col, { id = st.marks[s.id], right_gravity = false })
    end
  end
  for sid, id in pairs(st.marks) do
    if not seen[sid] then
      pcall(api.nvim_buf_del_extmark, st.qbuf, NS, id)
      st.marks[sid] = nil
    end
  end
end

local attach_source

-- What every span showed at the last sync. Commit diffs against this, so it can tell the user's edit from a
-- source change that arrived in the same moment.
local function snapshot(st)
  local spans = st.model:spans()
  local lines = api.nvim_buf_get_lines(st.qbuf, 0, -1, false)
  st.base = { spans = spans, rows = {} }
  for _, s in ipairs(spans) do
    st.base.rows[s.id] = { unpack(lines, s.q_start + 1, s.q_start + s.count) }
  end
end

local function rebuild(st)
  for _, s in ipairs(st.model:spans()) do
    if not api.nvim_buf_is_loaded(s.src) then
      st.model:remove(s.id)
    end
  end
  local lines = {}
  for _, s in ipairs(st.model:spans()) do
    attach_source(st, s.src)
    vim.list_extend(lines, api.nvim_buf_get_lines(s.src, s.src_start, s.src_start + s.count, false))
  end
  without_undo(st, function()
    set_lines(st, st.qbuf, 0, -1, lines)
  end)
  st.dirty = false
  place_marks(st)
  snapshot(st)
  render_now(st)
  sync_modified(st)
end

-- Where each span starts now, read from the marks. See SPEC "How sync works" 3 and 6.
local function derive_starts(st, spans)
  local n = api.nvim_buf_line_count(st.qbuf)
  local lines = api.nvim_buf_get_lines(st.qbuf, 0, -1, false)
  local all_top = true
  local starts = {}
  for i, s in ipairs(spans) do
    local r, c = mark_pos(st, s)
    if not r then
      r, c = s.q_start, 0
    end
    all_top = all_top and r == 0 and c == 0
    local row = r
    if c > 0 then
      row = r + 1
    elseif r == n - 1 and lines[n] == "" and s.count == 0 then
      row = n -- still collapsed at the end; the empty last line is not its row
    end
    starts[i] = math.min(math.max(row, starts[i - 1] or 0), n)
  end
  if n == 1 and lines[1] == "" and all_top then
    for i in ipairs(starts) do
      starts[i] = n
    end
  elseif starts[1] then
    starts[1] = 0
  end
  return starts, lines, n
end

-- `o` on the last row of one span and `O` on the first row of the next look the same. See SPEC "How sync works" 5.
local function settle_insertion(st, p, count, above)
  if p == 0 then
    return
  end
  local at = {}
  local spans = st.base.spans
  local owner
  for i, s in ipairs(spans) do
    local r, c = mark_pos(st, s)
    if r == p and c == 0 then
      at[#at + 1] = s
      owner = i
    end
  end
  if not owner then
    return
  end
  local nxt = spans[owner + 1] and mark_pos(st, spans[owner + 1]) or api.nvim_buf_line_count(st.qbuf)
  if nxt == p + count then
    return -- undo or redo put this span's rows back
  end
  if above then
    for _, s in ipairs(at) do
      api.nvim_buf_set_extmark(st.qbuf, NS, p + count, 0, { id = st.marks[s.id], right_gravity = false })
    end
    return true
  end
end

local function trim(old, new)
  local pre = 0
  while pre < #old and pre < #new and old[pre + 1] == new[pre + 1] do
    pre = pre + 1
  end
  local suf = 0
  while suf < #old - pre and suf < #new - pre and old[#old - suf] == new[#new - suf] do
    suf = suf + 1
  end
  return pre, suf
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- Push what the user changed in the quilt into the sources, span by span, against the last snapshot.
local function commit(st)
  st.dirty = false
  local seq = vim.fn.undotree(st.qbuf).seq_cur
  local ins = st.pending_ins
  if ins then
    -- Redo replays the side the first run chose.
    local above = ins.redo and st.sides[seq] or (not ins.redo and ins[3])
    if settle_insertion(st, ins[1], ins[2], above) and above then
      st.settled_above = true
    end
  end
  if st.settled_above then
    st.sides[seq] = true
  end
  st.pending_ins, st.settled_above = nil, nil
  local spans = st.base.spans
  local starts, qlines, n = derive_starts(st, spans)
  local conflict, broke = false, {}
  for i, s in ipairs(spans) do
    local base = st.base.rows[s.id]
    local new = { unpack(qlines, starts[i] + 1, starts[i + 1] or n) }
    if not same(base, new) then
      local span = st.model:find(s.id)
      local loaded = span and api.nvim_buf_is_loaded(span.src)
      local cur = loaded and api.nvim_buf_get_lines(span.src, span.src_start, span.src_start + span.count, false)
      if span and not loaded then
        st.raced = true -- the source went away; the rebuild below drops its spans
      elseif not cur or not same(cur, base) then
        conflict = true -- the source changed under this span too
      elseif not vim.bo[span.src].modifiable then
        broke[span.src] = true
      else
        local pre, suf = trim(base, new)
        local e = st.model:replace(s.id, pre, #base - suf, { unpack(new, pre + 1, #new - suf) })
        if not st.undo_broken[e.src] then
          st.undo_broken[e.src] = true
          break_undo(e.src)
        end
        st.touched[e.src] = true
        local ok, err = set_lines(st, e.src, e.first, e.last, e.lines)
        if not ok then
          notify(("could not change %s: %s"):format(api.nvim_buf_get_name(e.src), err))
          broke[e.src] = true
        end
      end
    end
  end
  st.undo_broken = {}
  for src in pairs(broke) do
    notify(api.nvim_buf_get_name(src) .. " can't be changed; the quilt shows it again as it is")
  end
  if conflict then
    notify(
      "a file and the quilt changed the same excerpt at once; the quilt shows the file's version",
      vim.log.levels.ERROR
    )
  end
  if conflict or st.raced or next(broke) then
    st.raced = false
    rebuild(st)
    return
  end
  place_marks(st)
  snapshot(st)
end

local function flush(st)
  st.scheduled = false
  if st.dirty and #st.queue > 0 then
    st.raced = true
  end
  if st.raced then
    -- Quilt and sources both moved. The model already follows the sources; merge the quilt's edits per span.
    st.queue = {}
    commit(st)
    schedule_render(st)
    sync_modified(st)
    return
  end
  local queue = st.queue
  st.queue = {}
  if #queue > 0 then
    break_undo(st.qbuf)
    for _, item in ipairs(queue) do
      local ok, err = set_lines(st, st.qbuf, item.first, item.last, item.lines)
      if not ok then
        notify("could not update the quilt: " .. err)
        rebuild(st)
        return
      end
    end
    place_marks(st)
    snapshot(st)
  end
  if st.dirty then
    commit(st)
  end
  schedule_render(st)
  sync_modified(st)
end

local function schedule_flush(st)
  if not st.scheduled then
    st.scheduled = true
    vim.schedule(function()
      if alive(st) then
        flush(st)
      end
    end)
  end
end

-- A formatter may replace a whole file to change two lines. Diff against our copy of the source so only the
-- rows that really changed reach the model, and excerpts don't swallow the file.
local function source_hunks(old, new, first)
  if #old + #new <= 4 then
    return { { first, first + #old, new } }
  end
  local hunks = {}
  local indices = vim.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", {
    result_type = "indices",
  }) --[[@as integer[][] ]]
  local offset = 0
  for _, h in ipairs(indices) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local row = first + (ca > 0 and sa - 1 or sa) + offset
    hunks[#hunks + 1] = { row, row + ca, cb > 0 and { unpack(new, sb, sb + cb - 1) } or {} }
    offset = offset + cb - ca
  end
  return hunks
end

local function enqueue_quilt_edits(st, edits)
  for _, e in ipairs(edits) do
    table.insert(st.queue, { first = e.first, last = e.last, lines = literal(e) })
  end
  if #edits > 0 then
    schedule_flush(st)
  end
end

function attach_source(st, src)
  if st.attached[src] then
    return
  end
  st.attached[src] = true
  st.cache[src] = api.nvim_buf_get_lines(src, 0, -1, false)
  api.nvim_buf_attach(src, false, {
    on_lines = function(_, buf, _, first, last_old, last_new)
      if not alive(st) or not st.attached[buf] then
        return true
      end
      local cache = st.cache[buf]
      local old = { unpack(cache, first + 1, last_old) }
      local lines = api.nvim_buf_get_lines(buf, first, last_new, false)
      for _ = first + 1, last_old do
        table.remove(cache, first + 1)
      end
      for i, l in ipairs(lines) do
        table.insert(cache, first + i, l)
      end
      if st.applying[buf] then
        return
      end
      for _, h in ipairs(source_hunks(old, lines, first)) do
        local edits = st.model:apply_source_change(buf, h[1], h[2], h[3])
        -- The quilt has edits of its own that aren't in the sources yet. Keep the model right; the flush rereads.
        if st.dirty or st.raced then
          st.raced = true
          schedule_flush(st)
        else
          enqueue_quilt_edits(st, edits)
        end
      end
    end,
    on_reload = function(_, buf)
      if alive(st) and st.attached[buf] then
        st.cache[buf] = api.nvim_buf_get_lines(buf, 0, -1, false)
        local edits = st.model:clamp(buf, api.nvim_buf_line_count(buf))
        if st.dirty or st.raced then
          st.raced = true
          schedule_flush(st)
        else
          enqueue_quilt_edits(st, edits)
        end
      end
    end,
    on_detach = function(_, buf)
      st.attached[buf] = nil
      vim.schedule(function()
        if not alive(st) then
          return
        end
        M.flush(st.qbuf)
        -- `:e!` detaches and loads the buffer again in one go.
        if api.nvim_buf_is_loaded(buf) then
          st.cache[buf] = nil
          attach_source(st, buf)
          enqueue_quilt_edits(st, st.model:clamp(buf, api.nvim_buf_line_count(buf)))
          M.flush(st.qbuf)
          return
        end
        without_undo(st, function()
          for _, s in ipairs(st.model:spans()) do
            if s.src == buf then
              for _, e in ipairs(st.model:remove(s.id)) do
                set_lines(st, st.qbuf, e.first, e.last, {})
              end
            end
          end
        end)
        place_marks(st)
        snapshot(st)
        render_now(st)
      end)
    end,
  })
end

-- `:sort` and the like rewrite a range in place and drop every mark inside it onto one row. When the line count
-- didn't change and marks collapsed, keep each span's rows where they were.
local function keep_rows(st, first, last)
  local prev
  local collapsed = false
  for _, s in ipairs(st.base.spans) do
    if s.count > 0 and s.q_start <= first then
      prev = mark_pos(st, s)
    elseif s.count > 0 and s.q_start < last then
      local r = mark_pos(st, s)
      collapsed = collapsed or r == prev
      prev = r
    end
  end
  if not collapsed then
    return
  end
  for _, s in ipairs(st.base.spans) do
    if s.q_start > first and s.q_start < last then
      api.nvim_buf_set_extmark(st.qbuf, NS, s.q_start, 0, { id = st.marks[s.id], right_gravity = false })
    end
  end
end

local on_quilt_lines

-- Unloading the quilt (`:e!`) detaches it, so this runs again when its text comes back.
local function attach_quilt(st)
  api.nvim_buf_attach(st.qbuf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      return on_quilt_lines(st, first, last_old, last_new)
    end,
  })
end

function on_quilt_lines(st, first, last_old, last_new)
  if not alive(st) then
    return true
  end
  if st.applying[st.qbuf] then
    return
  end
  if #st.queue > 0 then
    st.raced = true
  end
  if not st.dirty and last_old == last_new and last_old - first > 1 then
    keep_rows(st, first, last_old)
  end
  local ins = st.pending_ins
  if ins then
    -- Typing into the new lines (`ox<Esc>`, `.`) keeps the insertion whole; anything else cancels it.
    if first >= ins[1] and last_old <= ins[1] + ins[2] then
      ins[2] = ins[2] + last_new - last_old
    else
      st.pending_ins = nil
    end
  end
  if first == last_old and last_new > first and st.undo_kind ~= "undo" then
    if st.intent then
      if settle_insertion(st, first, last_new - first, st.intent == "above") then
        st.settled_above = true
      end
    elseif not st.dirty then
      -- Decided at the flush, and only when the command did nothing else (`p`, `P`, `:put`, `.`, redo).
      st.pending_ins = { first, last_new - first, st.last_row < first, redo = st.undo_kind == "redo" }
    end
  end
  st.dirty = true
  schedule_flush(st)
  schedule_render(st)
end

-- Quilt-only edits (expand, shrink, drop) change what the quilt shows, never a source.
local function apply_view_edits(st, edits)
  M.flush(st.qbuf)
  without_undo(st, function()
    for _, e in ipairs(edits) do
      set_lines(st, st.qbuf, e.first, e.last, literal(e))
    end
  end)
  place_marks(st)
  snapshot(st)
  render_now(st)
end

local function cleanup(st)
  if st.dead then
    return
  end
  st.dead = true
  states[st.qbuf] = nil
  st.timer:stop()
  st.timer:close()
  local qbuf = st.qbuf
  vim.schedule(function()
    for buf in pairs(st.created) do
      local used = false
      for _, other in pairs(states) do
        for _, s in ipairs(other.model:spans()) do
          used = used or s.src == buf
        end
      end
      if not used and api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 then
        pcall(api.nvim_buf_delete, buf, { unload = true })
      end
    end
    if api.nvim_buf_is_valid(qbuf) then
      pcall(api.nvim_buf_delete, qbuf, { force = true })
    end
  end)
end

local function setup_window(win)
  local wo = vim.wo[win][0]
  wo.number = true
  wo.relativenumber = false
  wo.statuscolumn = decor.statuscolumn
  wo.foldenable = false
  wo.wrap = false
  decor.show_top(win)
end

local function cursor(st)
  local pos = api.nvim_win_get_cursor(0)
  local span, src_row = st.model:locate(pos[1] - 1)
  return span, src_row, pos[2]
end

local function lsp_pos(st)
  local span, src_row, col = cursor(st)
  if span then
    return { src = span.src, row = src_row, col = col }
  end
end

local function jump_in_quilt(st)
  return function(buf, row, col)
    local q = st.model:to_quilt(buf, row)
    if not q then
      return false
    end
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { q + 1, col })
    return true
  end
end

local function step(st, dir)
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local spans = st.model:spans()
  local target
  if dir > 0 then
    for _, s in ipairs(spans) do
      if s.count > 0 and s.q_start > row then
        target = s.q_start
        break
      end
    end
  else
    for i = #spans, 1, -1 do
      if spans[i].count > 0 and spans[i].q_start < row then
        target = spans[i].q_start
        break
      end
    end
  end
  if target then
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { target + 1, 0 })
    if target == 0 then
      decor.show_top(0)
    end
  end
end

local function actions(st, opts)
  local lsp = require("quilt.lsp")
  local function with_span(fn)
    return function()
      M.flush(st.qbuf)
      local span, src_row, col = cursor(st)
      if span then
        fn(span, src_row, col)
      end
    end
  end
  local function with_pos(fn)
    return function()
      M.flush(st.qbuf)
      local pos = lsp_pos(st)
      if pos then
        fn(pos)
      end
    end
  end
  return {
    open = with_span(function(span, src_row, col)
      vim.cmd("normal! m'")
      api.nvim_win_set_buf(0, span.src)
      vim.bo[span.src].buflisted = true
      api.nvim_win_set_cursor(0, { src_row + 1, col })
    end),
    next = function()
      step(st, 1)
    end,
    prev = function()
      step(st, -1)
    end,
    expand = with_span(function(span)
      local n = opts.context
      apply_view_edits(st, st.model:expand(span.id, n, n, api.nvim_buf_line_count(span.src)))
    end),
    shrink = with_span(function(span)
      local n = opts.context
      apply_view_edits(st, st.model:shrink(span.id, n, n))
    end),
    drop = with_span(function(span)
      apply_view_edits(st, st.model:remove(span.id))
    end),
    hover = with_pos(lsp.hover),
    definition = with_pos(function(pos)
      lsp.definition(pos, { on_location = jump_in_quilt(st) })
    end),
    implementation = with_pos(function(pos)
      lsp.implementation(pos, { on_location = jump_in_quilt(st) })
    end),
    rename = with_pos(function(pos)
      lsp.rename(pos)
    end),
    code_action = with_pos(lsp.code_action),
    references = with_pos(function(pos)
      lsp.references(pos, function(hits, err)
        if not hits then
          notify(err or "no references")
          return
        end
        require("quilt").open_hits(hits, "refs")
      end)
    end),
  }
end

local function set_keys(st, opts)
  -- `o` and `O` say which excerpt a new line at an edge belongs to, even inside `:g` and `:normal`,
  -- where CursorMoved doesn't fire.
  -- Undo puts marks back where they were; the cursor rule must not move them again.
  for lhs, kind in pairs({ u = "undo", U = "undo", ["g-"] = "undo", ["<C-r>"] = "redo", ["g+"] = "redo" }) do
    vim.keymap.set("n", lhs, function()
      st.undo_kind = kind
      vim.schedule(function()
        st.undo_kind = nil
      end)
      return lhs
    end, { buffer = st.qbuf, expr = true, desc = "quilt: " .. kind })
  end
  for lhs, side in pairs({ o = "above", O = "below" }) do
    vim.keymap.set("n", lhs, function()
      st.intent = side
      vim.schedule(function()
        st.intent = nil
      end)
      return lhs
    end, { buffer = st.qbuf, expr = true, desc = "quilt: open line" })
  end
  local acts = actions(st, opts)
  for name, lhs in pairs(opts.keys or {}) do
    if lhs and acts[name] then
      vim.keymap.set("n", lhs, acts[name], { buffer = st.qbuf, nowait = true, desc = "quilt: " .. name })
    end
  end
end

---@class quilt.OpenOpts
---@field title? string
---@field created? integer[]      bufnrs the quilt may unload later
---@field win? integer
---@field keys? table<string, string|false>
---@field context? integer

---Create a quilt from ranges and show it.
---@param ranges quilt.Range[]
---@param opts? quilt.OpenOpts
---@return integer qbuf
function M.open(ranges, opts)
  opts = opts or {}
  opts.context = opts.context or 3
  counter = counter + 1
  local qbuf = api.nvim_create_buf(false, false)
  local st = {
    qbuf = qbuf,
    model = Model.new(ranges),
    queue = {},
    applying = {},
    attached = {},
    touched = {},
    created = {},
    marks = {},
    cache = {},
    sides = {},
    undo_broken = {},
    last_row = 0,
    timer = assert(vim.uv.new_timer()),
  }
  for _, b in ipairs(opts.created or {}) do
    st.created[b] = true
  end
  for _, s in ipairs(st.model:spans()) do
    st.touched[s.src] = true
  end
  states[qbuf] = st

  api.nvim_buf_set_name(qbuf, ("quilt://%d/%s"):format(counter, opts.title or "quilt"))
  vim.bo[qbuf].buftype = "acwrite"
  vim.bo[qbuf].swapfile = false
  vim.bo[qbuf].bufhidden = "hide"
  rebuild(st) -- not an undo step
  vim.bo[qbuf].filetype = "quilt"
  vim.bo[qbuf].modified = false

  attach_quilt(st)

  local group = api.nvim_create_augroup("quilt_" .. qbuf, { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    buffer = qbuf,
    callback = function()
      st.last_row = api.nvim_win_get_cursor(0)[1] - 1
    end,
  })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = qbuf,
    nested = true, -- so each source's own write autocmds run
    callback = function(ev)
      if ev.match ~= api.nvim_buf_get_name(qbuf) then
        notify(":w {file} doesn't work in a quilt; :w writes every changed file")
        return
      end
      M.write(qbuf)
    end,
  })
  -- `:e!` in the quilt: its edits already live in the sources, so reread them.
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    buffer = qbuf,
    callback = function()
      if not alive(st) then
        return
      end
      st.queue, st.dirty, st.raced = {}, false, false
      rebuild(st)
      attach_quilt(st)
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      if alive(st) and vim.tbl_contains(vim.fn.win_findbuf(qbuf), tonumber(vim.fn.expand("<amatch>"))) then
        decor.render_visible(qbuf)
      end
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = qbuf,
    callback = function()
      setup_window(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = qbuf,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, group)
      cleanup(st)
    end,
  })
  api.nvim_create_autocmd({ "DiagnosticChanged", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      if alive(st) and st.attached[ev.buf] then
        schedule_render(st)
        sync_modified(st)
      end
    end,
  })

  set_keys(st, opts)
  local win = opts.win or api.nvim_get_current_win()
  api.nvim_win_set_buf(win, qbuf)
  api.nvim_win_set_cursor(win, { 1, 0 })
  setup_window(win)
  return qbuf
end

---@param qbuf integer
function M.get(qbuf)
  local st = states[qbuf]
  if alive(st) then
    return st
  end
end

---Queued work not yet applied: quilt edits from sources, plus one for an uncommitted quilt edit.
---@param qbuf integer
function M.pending(qbuf)
  local st = states[qbuf]
  return st and (#st.queue + ((st.dirty or st.raced) and 1 or 0)) or 0
end

---Apply queued edits now. Must not be called from inside on_lines.
---@param qbuf integer
function M.flush(qbuf)
  local st = M.get(qbuf)
  if st and (#st.queue > 0 or st.dirty or st.raced) then
    flush(st)
  end
end

---Reread every span from its source.
---@param qbuf integer
function M.resync(qbuf)
  local st = M.get(qbuf)
  if st then
    M.flush(qbuf)
    rebuild(st)
  end
end

---Write every changed source with its normal autocmds.
---@param qbuf integer
function M.write(qbuf)
  local st = M.get(qbuf)
  if not st then
    return
  end
  M.flush(qbuf)
  local failed = 0
  for src in pairs(st.touched) do
    if api.nvim_buf_is_loaded(src) and vim.bo[src].modified then
      local ok, err = pcall(api.nvim_buf_call, src, function()
        vim.cmd("silent write")
      end)
      if not ok then
        failed = failed + 1
        notify(err, vim.log.levels.ERROR)
      end
    end
  end
  -- Format-on-save edits arrive through on_lines and wait in the queue.
  M.flush(qbuf)
  sync_modified(st)
  if failed == 0 then
    vim.bo[qbuf].modified = false
  end
end

return M
