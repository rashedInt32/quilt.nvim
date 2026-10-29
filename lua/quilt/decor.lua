-- Decoration for a quilt buffer: headers, status column, treesitter and diagnostic projection.
local api = vim.api

local M = {}

local ns_head = api.nvim_create_namespace("quilt.decor.headers")
local ns_hl = api.nvim_create_namespace("quilt.decor.highlights")
local ns_diag = api.nvim_create_namespace("quilt.decor.diagnostics")

---@type table<integer, quilt.Span[]>
local saved = {}
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

---@param spans quilt.Span[]
---@return quilt.Span|nil, integer|nil
local function span_at(spans, qrow)
  for _, s in ipairs(spans) do
    if qrow >= s.q_start and qrow < s.q_start + s.count then
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
  local buf = api.nvim_get_current_buf()
  local spans = saved[buf] or {}
  local last = 0
  for _, s in ipairs(spans) do
    last = math.max(last, s.src_start + s.count)
  end
  local width = math.max(#tostring(last), 3)
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

local function draw_treesitter(qbuf, spans)
  local by_src, order = {}, {}
  for _, s in ipairs(spans) do
    if not by_src[s.src] then
      by_src[s.src] = {}
      order[#order + 1] = s.src
    end
    table.insert(by_src[s.src], s)
  end
  for _, src in ipairs(order) do
    if api.nvim_buf_is_loaded(src) then
      local ok, parser = pcall(vim.treesitter.get_parser, src, nil, { error = false })
      if ok and parser then
        pcall(parser.parse, parser, true)
        parser:for_each_tree(function(tree, ltree)
          local lang = ltree:lang()
          local qok, query = pcall(vim.treesitter.query.get, lang, "highlights")
          if not qok or not query then
            return
          end
          for _, s in ipairs(by_src[src]) do
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

local function draw_diagnostics(qbuf, spans)
  local out = {}
  local seen = {}
  for _, s in ipairs(spans) do
    if not seen[s.src] and api.nvim_buf_is_valid(s.src) then
      seen[s.src] = true
    end
  end
  for src in pairs(seen) do
    for _, d in ipairs(vim.diagnostic.get(src)) do
      for _, s in ipairs(spans) do
        local last = s.src_start + s.count - 1
        if s.src == src and d.lnum >= s.src_start and d.lnum <= last then
          local nd = vim.deepcopy(d)
          nd.bufnr = qbuf
          nd.lnum = d.lnum + s.q_start - s.src_start
          if d.end_lnum and d.end_lnum > last then
            nd.end_lnum = s.q_start + s.count - 1
            nd.end_col = nil
          elseif d.end_lnum then
            nd.end_lnum = d.end_lnum + s.q_start - s.src_start
          end
          out[#out + 1] = nd
        end
      end
    end
  end
  vim.diagnostic.set(ns_diag, qbuf, out)
end

--- Draw headers, highlights and diagnostics for a quilt. Idempotent.
---@param qbuf integer
---@param spans quilt.Span[]
---@param opts? table reserved
function M.render(qbuf, spans, opts) -- luacheck: ignore opts
  if not api.nvim_buf_is_valid(qbuf) then
    return
  end
  local copy = {}
  for i, s in ipairs(spans) do
    copy[i] = { id = s.id, src = s.src, src_start = s.src_start, q_start = s.q_start, count = s.count }
  end
  saved[qbuf] = copy
  if not watched[qbuf] then
    watched[qbuf] = true
    api.nvim_create_autocmd("BufWipeout", {
      buffer = qbuf,
      once = true,
      callback = function()
        saved[qbuf], watched[qbuf] = nil, nil
      end,
    })
  end
  api.nvim_buf_clear_namespace(qbuf, ns_head, 0, -1)
  api.nvim_buf_clear_namespace(qbuf, ns_hl, 0, -1)
  draw_headers(qbuf, copy)
  draw_treesitter(qbuf, copy)
  draw_diagnostics(qbuf, copy)
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
