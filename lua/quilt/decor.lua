-- Decoration for a quilt buffer: headers, status column, treesitter and diagnostic projection.
local api = vim.api

local M = {}

local ns_head = api.nvim_create_namespace("quilt.decor.headers")
local ns_hl = api.nvim_create_namespace("quilt.decor.highlights")
local ns_diag = api.nvim_create_namespace("quilt.decor.diagnostics")

---@type table<integer, quilt.Span[]>
local saved = {}
local widths = {}
local watched = {}

M.statuscolumn = "%!v:lua.require'quilt.decor'.sc()"

--- Default links for the Quilt* groups.
function M.setup_highlights()
  local links = {
    QuiltHeader = "Title",
    QuiltHeaderPath = "Directory",
    QuiltHeaderLnum = "LineNr",
    QuiltLineNr = "LineNr",
  }
  for name, target in pairs(links) do
    api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local function priority_base()
  local hl = vim.hl or vim.highlight
  return hl.priorities.treesitter
end

---@param spans quilt.Span[] sorted by q_start
---@return quilt.Span|nil, integer|nil
local function span_at(spans, qrow)
  local lo, hi = 1, #spans
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local s = spans[mid]
    if qrow < s.q_start then
      hi = mid - 1
    elseif qrow >= s.q_start + s.count then
      lo = mid + 1
    else
      return s, s.src_start + (qrow - s.q_start)
    end
  end
end

--- Source line number (1-based) shown on a quilt row, as a string. Empty when unknown.
---@param qbuf integer
---@param qrow integer 0-based quilt row
---@return string
function M.lnum(qbuf, qrow)
  local _, srow = span_at(saved[qbuf] or {}, qrow)
  return srow and tostring(srow + 1) or ""
end

--- Status column body. Arguments default to v:lnum and v:virtnum.
---@param lnum? integer 1-based quilt line
---@param virtnum? integer
---@return string
function M.sc(lnum, virtnum)
  lnum = lnum or vim.v.lnum
  virtnum = virtnum or vim.v.virtnum
  local win = vim.g.statusline_winid
  local buf = (win and win ~= 0 and api.nvim_win_is_valid(win)) and api.nvim_win_get_buf(win)
    or api.nvim_get_current_buf()
  local width = widths[buf] or 3
  if virtnum ~= 0 then
    return string.rep(" ", width + 1)
  end
  return string.format("%%#QuiltLineNr#%" .. width .. "s ", M.lnum(buf, lnum - 1))
end

local function draw_headers(qbuf, spans)
  for i, s in ipairs(spans) do
    local name = api.nvim_buf_is_valid(s.src) and api.nvim_buf_get_name(s.src) or ""
    local path = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":~:.")
    local lines = {}
    if i > 1 then
      lines[#lines + 1] = { { "", "QuiltHeader" } }
    end
    lines[#lines + 1] = {
      { path, "QuiltHeaderPath" },
      { ":", "QuiltHeader" },
      { tostring(s.src_start + 1), "QuiltHeaderLnum" },
    }
    api.nvim_buf_set_extmark(qbuf, ns_head, s.q_start, 0, {
      virt_lines = lines,
      virt_lines_above = true,
      strict = false,
    })
  end
end

local function project_capture(qbuf, s, lang, name, node, metadata)
  local range = vim.treesitter.get_range(node, s.src, metadata)
  local sr, sc, er, ec
  if #range >= 6 then
    sr, sc, er, ec = range[1], range[2], range[4], range[5]
  else
    sr, sc, er, ec = range[1], range[2], range[3], range[4]
  end
  local first, stop = s.src_start, s.src_start + s.count
  if er < first or sr >= stop or (er == first and ec == 0 and sr < first) then
    return
  end
  if sr < first then
    sr, sc = first, 0
  end
  if er >= stop then
    er, ec = stop, 0
  end
  if sr == er and sc >= ec then
    return
  end
  local prio = tonumber(metadata.priority) or tonumber((metadata[name] or {}).priority) or priority_base()
  local off = s.q_start - s.src_start
  api.nvim_buf_set_extmark(qbuf, ns_hl, sr + off, sc, {
    end_row = er + off,
    end_col = ec,
    hl_group = "@" .. name .. "." .. lang,
    priority = prio,
    strict = false,
  })
end

local MARGIN = 20

--- Quilt row ranges [first, last] visible in windows showing qbuf, or nil when none is shown.
local function visible_ranges(qbuf)
  local out = {}
  for _, win in ipairs(vim.fn.win_findbuf(qbuf)) do
    local r = api.nvim_win_call(win, function()
      return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
    end)
    out[#out + 1] = { r[1] - MARGIN, r[2] + MARGIN }
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function intersects(ranges, first, last)
  if not ranges then
    return true
  end
  for _, r in ipairs(ranges) do
    if first <= r[2] and last >= r[1] then
      return true
    end
  end
  return false
end

---@return table<integer, quilt.Span[]>, integer[]
local function group_by_src(spans)
  local by_src, order = {}, {}
  for _, s in ipairs(spans) do
    if not by_src[s.src] then
      by_src[s.src] = {}
      order[#order + 1] = s.src
    end
    table.insert(by_src[s.src], s)
  end
  return by_src, order
end

local function draw_treesitter(qbuf, by_src, order)
  for _, src in ipairs(order) do
    local group = by_src[src]
    if api.nvim_buf_is_loaded(src) then
      local ok, parser = pcall(vim.treesitter.get_parser, src, nil, { error = false })
      if ok and parser then
        local lo, hi = math.huge, 0
        for _, s in ipairs(group) do
          lo = math.min(lo, s.src_start)
          hi = math.max(hi, s.src_start + s.count)
        end
        pcall(parser.parse, parser, { lo, hi })
        parser:for_each_tree(function(tree, ltree)
          local lang = ltree:lang()
          local qok, query = pcall(vim.treesitter.query.get, lang, "highlights")
          if not qok or not query then
            return
          end
          for _, s in ipairs(group) do
            for id, node, metadata in query:iter_captures(tree:root(), src, s.src_start, s.src_start + s.count) do
              local name = query.captures[id]
              if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
                project_capture(qbuf, s, lang, name, node, metadata or {})
              end
            end
          end
        end)
      end
    end
  end
end

local fallback_signs = { "E", "W", "I", "H" }

local function sign_text(sev)
  local ok, cfg = pcall(vim.diagnostic.config)
  local signs = ok and cfg and cfg.signs
  if type(signs) == "table" and type(signs.text) == "table" and signs.text[sev] then
    return signs.text[sev]
  end
  return fallback_signs[sev]
end

local function draw_diagnostics(qbuf, by_src, order)
  for _, src in ipairs(order) do
    local group = by_src[src]
    if api.nvim_buf_is_valid(src) then
      for _, d in ipairs(vim.diagnostic.get(src)) do
        local s
        local srow = d.lnum
        -- group is sorted by src_start, so binary search on source rows
        local lo, hi = 1, #group
        while lo <= hi do
          local mid = math.floor((lo + hi) / 2)
          local g = group[mid]
          if srow < g.src_start then
            hi = mid - 1
          elseif srow >= g.src_start + g.count then
            lo = mid + 1
          else
            s = g
            break
          end
        end
        if s then
          local off = s.q_start - s.src_start
          local sev = d.severity or vim.diagnostic.severity.ERROR
          local name = ({ "Error", "Warn", "Info", "Hint" })[sev] or "Error"
          local last = s.src_start + s.count - 1
          local end_row, end_col = d.end_lnum or d.lnum, d.end_col
          if end_row > last then
            end_row, end_col = last + 1, 0
          end
          if end_row == d.lnum and (not end_col or end_col <= d.col) then
            end_col = d.col + 1
          end
          local first_line = (d.message or ""):match("[^\n]*")
          api.nvim_buf_set_extmark(qbuf, ns_diag, d.lnum + off, d.col, {
            end_row = end_row + off,
            end_col = end_col or 0,
            hl_group = "DiagnosticUnderline" .. name,
            sign_text = sign_text(sev),
            sign_hl_group = "DiagnosticSign" .. name,
            virt_text = { { first_line, "DiagnosticVirtualText" .. name } },
            virt_text_pos = "eol",
            strict = false,
          })
        end
      end
    end
  end
end

--- Redraw highlights and diagnostics for the rows visible in windows showing qbuf.
--- With no window showing it, every span is drawn. Call from WinScrolled.
---@param qbuf integer
function M.render_visible(qbuf)
  local spans = saved[qbuf]
  if not spans or not api.nvim_buf_is_valid(qbuf) then
    return
  end
  api.nvim_buf_clear_namespace(qbuf, ns_hl, 0, -1)
  api.nvim_buf_clear_namespace(qbuf, ns_diag, 0, -1)
  local ranges = visible_ranges(qbuf)
  local vis = {}
  for _, s in ipairs(spans) do
    if intersects(ranges, s.q_start, s.q_start + s.count - 1) then
      vis[#vis + 1] = s
    end
  end
  local by_src, order = group_by_src(vis)
  for _, g in pairs(by_src) do
    table.sort(g, function(x, y)
      return x.src_start < y.src_start
    end)
  end
  draw_treesitter(qbuf, by_src, order)
  draw_diagnostics(qbuf, by_src, order)
end

--- Draw headers for every span, then highlights and diagnostics for the visible ones. Idempotent.
---@param qbuf integer
---@param spans quilt.Span[]
---@param opts? table reserved
function M.render(qbuf, spans, opts) -- luacheck: ignore opts
  if not api.nvim_buf_is_valid(qbuf) then
    return
  end
  local copy = {}
  local last = 0
  for _, s in ipairs(spans) do
    if s.count > 0 then
      copy[#copy + 1] = { id = s.id, src = s.src, src_start = s.src_start, q_start = s.q_start, count = s.count }
      last = math.max(last, s.src_start + s.count)
    end
  end
  saved[qbuf] = copy
  widths[qbuf] = math.max(#tostring(last), 3)
  if not watched[qbuf] then
    watched[qbuf] = true
    api.nvim_create_autocmd("BufWipeout", {
      buffer = qbuf,
      once = true,
      callback = function()
        saved[qbuf], watched[qbuf], widths[qbuf] = nil, nil, nil
      end,
    })
  end
  api.nvim_buf_clear_namespace(qbuf, ns_head, 0, -1)
  draw_headers(qbuf, copy)
  M.render_visible(qbuf)
end

--- Scroll window `win` to the top with the first header (virtual lines above row 0) visible.
---@param win integer
function M.show_top(win)
  local buf = api.nvim_win_get_buf(win)
  local marks = api.nvim_buf_get_extmarks(buf, ns_head, { 0, 0 }, { 0, -1 }, { details = true })
  local n = 0
  for _, m in ipairs(marks) do
    n = n + #(m[4].virt_lines or {})
  end
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, topfill = n })
  end)
end

return M
