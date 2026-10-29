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

-- Quilt edits may point at source rows. Read them now, while the rows still hold the text the model saw.
local function literal(e)
  if e.lines then
    return e.lines
  end
  return api.nvim_buf_get_lines(e.src, e.src_first, e.src_last, false)
end

local function set_lines(st, buf, first, last, lines)
  st.applying[buf] = true
  local ok, err = pcall(api.nvim_buf_set_lines, buf, first, last, false, lines)
  st.applying[buf] = nil
  return ok, err
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

local attach_source

local function rebuild(st)
  local lines = {}
  for _, s in ipairs(st.model:spans()) do
    attach_source(st, s.src)
    vim.list_extend(lines, api.nvim_buf_get_lines(s.src, s.src_start, s.src_start + s.count, false))
  end
  set_lines(st, st.qbuf, 0, -1, lines)
  render_now(st)
  sync_modified(st)
end

local function flush(st)
  st.scheduled = false
  local queue = st.queue
  st.queue = {}
  for _, item in ipairs(queue) do
    if api.nvim_buf_is_loaded(item.buf) then
      local ok, err = set_lines(st, item.buf, item.first, item.last, item.lines)
      if not ok then
        st.broken = true
        notify(("could not change %s: %s"):format(api.nvim_buf_get_name(item.buf), err))
      end
    else
      st.broken = true
    end
  end
  if st.broken and alive(st) then
    st.broken = false
    rebuild(st)
    return
  end
  schedule_render(st)
  sync_modified(st)
end

local function enqueue(st, buf, first, last, lines)
  table.insert(st.queue, { buf = buf, first = first, last = last, lines = lines })
  if not st.scheduled then
    st.scheduled = true
    vim.schedule(function()
      if alive(st) then
        flush(st)
      end
    end)
  end
end

-- An event from `buf` while edits for `buf` still wait in the queue means the model is ahead of that buffer.
local function behind(st, buf)
  for _, item in ipairs(st.queue) do
    if item.buf == buf then
      return true
    end
  end
  return false
end

local function enqueue_quilt_edits(st, edits)
  for _, e in ipairs(edits) do
    enqueue(st, st.qbuf, e.first, e.last, literal(e))
  end
end

function attach_source(st, src)
  if st.attached[src] then
    return
  end
  st.attached[src] = true
  api.nvim_buf_attach(src, false, {
    on_lines = function(_, buf, _, first, last_old, last_new)
      if not alive(st) or not st.attached[buf] then
        return true
      end
      if st.applying[buf] then
        return
      end
      if behind(st, st.qbuf) or behind(st, buf) then
        st.broken = true
        return
      end
      local lines = api.nvim_buf_get_lines(buf, first, last_new, false)
      enqueue_quilt_edits(st, st.model:apply_source_change(buf, first, last_old, lines))
    end,
    on_reload = function(_, buf)
      if alive(st) and st.attached[buf] then
        enqueue_quilt_edits(st, st.model:clamp(buf, api.nvim_buf_line_count(buf)))
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
          attach_source(st, buf)
          enqueue_quilt_edits(st, st.model:clamp(buf, api.nvim_buf_line_count(buf)))
          M.flush(st.qbuf)
          return
        end
        for _, s in ipairs(st.model:spans()) do
          if s.src == buf then
            for _, e in ipairs(st.model:remove(s.id)) do
              set_lines(st, st.qbuf, e.first, e.last, {})
            end
          end
        end
        render_now(st)
      end)
    end,
  })
end

local function on_quilt_lines(st, first, last_old, last_new)
  if not alive(st) then
    return true
  end
  if st.applying[st.qbuf] then
    return
  end
  if behind(st, st.qbuf) then
    st.broken = true
    return
  end
  local lines = api.nvim_buf_get_lines(st.qbuf, first, last_new, false)
  local prefer = st.last_row >= first and "below" or "above"
  for _, e in ipairs(st.model:apply_quilt_change(first, last_old, lines, prefer)) do
    st.touched[e.src] = true
    enqueue(st, e.src, e.first, e.last, e.lines)
  end
  schedule_render(st)
end

-- Quilt-only edits (expand, shrink, drop) change what the quilt shows, never a source.
local function apply_view_edits(st, edits)
  for _, e in ipairs(edits) do
    set_lines(st, st.qbuf, e.first, e.last, literal(e))
  end
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
      if s.q_start > row then
        target = s.q_start
        break
      end
    end
  else
    for i = #spans, 1, -1 do
      if spans[i].q_start < row then
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
  -- The initial text is not an undo step.
  local undolevels = vim.bo[qbuf].undolevels
  vim.bo[qbuf].undolevels = -1
  rebuild(st)
  vim.bo[qbuf].undolevels = undolevels
  vim.bo[qbuf].filetype = "quilt"
  vim.bo[qbuf].modified = false

  api.nvim_buf_attach(qbuf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      return on_quilt_lines(st, first, last_old, last_new)
    end,
  })

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
    callback = function()
      M.write(qbuf)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = qbuf,
    callback = function()
      setup_window(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
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

---@param qbuf integer
function M.pending(qbuf)
  local st = states[qbuf]
  return st and #st.queue or 0
end

---Apply queued edits now. Must not be called from inside on_lines.
---@param qbuf integer
function M.flush(qbuf)
  local st = M.get(qbuf)
  if st and (#st.queue > 0 or st.broken) then
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
