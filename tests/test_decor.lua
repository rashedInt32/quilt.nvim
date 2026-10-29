-- Decor: headers, status column, treesitter and diagnostic projection.
local eq = MiniTest.expect.equality
local D = require("quilt.decor")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      D.setup_highlights()
    end,
  },
})

local function mkbuf(lines, name, ft)
  local b = vim.api.nvim_create_buf(true, false)
  if name then
    vim.api.nvim_buf_set_name(b, name)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then
    vim.bo[b].filetype = ft
  end
  return b
end

local function quilt_of(parts)
  local lines, spans = {}, {}
  for i, p in ipairs(parts) do
    spans[i] = { id = i, src = p.src, src_start = p.start, q_start = #lines, count = p.count }
    for r = p.start, p.start + p.count - 1 do
      lines[#lines + 1] = vim.api.nvim_buf_get_lines(p.src, r, r + 1, false)[1]
    end
  end
  local q = mkbuf(lines)
  return q, spans
end

local function marks(buf, ns)
  local id = vim.api.nvim_get_namespaces()[ns]
  return vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })
end

local function text(vl)
  local t = {}
  for _, chunk in ipairs(vl) do
    t[#t + 1] = chunk[1]
  end
  return table.concat(t)
end

T["headers: one virt_lines block per span, relative path, no spacer on the first"] = function()
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.chdir(dir)
  local a = mkbuf({ "a1", "a2", "a3" }, dir .. "/a.txt")
  local b = mkbuf({ "b1", "b2" }, dir .. "/sub/b.txt")
  local q, spans = quilt_of({ { src = a, start = 1, count = 2 }, { src = b, start = 0, count = 2 } })
  D.render(q, spans)
  vim.fn.chdir(cwd)

  local ms = marks(q, "quilt.decor.headers")
  eq(#ms, 2)
  eq(ms[1][2], 0)
  eq(ms[2][2], 2)
  eq(ms[1][4].virt_lines_above, true)
  eq(#ms[1][4].virt_lines, 1)
  eq(text(ms[1][4].virt_lines[1]), "a.txt:2")
  eq(#ms[2][4].virt_lines, 2)
  eq(text(ms[2][4].virt_lines[1]), "")
  eq(text(ms[2][4].virt_lines[2]), "sub/b.txt:1")
end

T["render twice leaves one set of extmarks"] = function()
  local a = mkbuf({ "local x = 1", "return x" }, nil, "lua")
  local q, spans = quilt_of({ { src = a, start = 0, count = 2 } })
  D.render(q, spans)
  local h, c = #marks(q, "quilt.decor.headers"), #marks(q, "quilt.decor.highlights")
  D.render(q, spans)
  eq(#marks(q, "quilt.decor.headers"), h)
  eq(#marks(q, "quilt.decor.highlights"), c)
  eq(h, 1)
end

T["lnum returns the source line number, 1-based, for every row"] = function()
  local a = mkbuf({ "1", "2", "3", "4", "5", "6" })
  local b = mkbuf({ "x", "y", "z" })
  local q, spans = quilt_of({ { src = a, start = 3, count = 2 }, { src = b, start = 0, count = 3 } })
  D.render(q, spans)
  local got = {}
  for r = 0, 4 do
    got[#got + 1] = D.lnum(q, r)
  end
  eq(got, { "4", "5", "1", "2", "3" })
  eq(D.lnum(q, 5), "")
end

T["statuscolumn prints source numbers for real rows and padding for virtual rows"] = function()
  local a = mkbuf({ "1", "2", "3", "4", "5", "6" })
  local q, spans = quilt_of({ { src = a, start = 3, count = 2 } })
  D.render(q, spans)
  vim.api.nvim_set_current_buf(q)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].statuscolumn = D.statuscolumn
  local res = vim.api.nvim_eval_statusline(D.statuscolumn, { winid = win, use_statuscol_lnum = 2, highlights = false })
  eq(vim.trim(res.str), "5")
  eq(vim.trim(D.sc(1, -1)), "")
  eq(vim.trim(D.sc(1, 1)), "")
  eq(vim.trim(D.sc(1, 0):gsub("%%#%w+#", "")), "4")
end

T["lua source: highlight extmarks land on the right quilt rows and cols"] = function()
  local a = mkbuf({ "-- c", "local x = 1", "return x", "local y = 2" }, nil, "lua")
  local q, spans = quilt_of({ { src = a, start = 1, count = 2 } })
  D.render(q, spans)
  local found = false
  for _, m in ipairs(marks(q, "quilt.decor.highlights")) do
    local d = m[4]
    eq(m[2] <= 1, true)
    if d.hl_group == "@keyword.lua" and m[2] == 0 and m[3] == 0 and d.end_col == 5 then
      found = true
    end
  end
  eq(found, true)
  local ret = false
  for _, m in ipairs(marks(q, "quilt.decor.highlights")) do
    if m[2] == 1 and m[3] == 0 and m[4].hl_group:find("^@keyword") then
      ret = true
    end
  end
  eq(ret, true)
end

T["capture crossing a span edge is clipped"] = function()
  local a = mkbuf({ "x = 1", "local s = [[", "mid", "end]]", "y = 2" }, nil, "lua")
  local q, spans = quilt_of({ { src = a, start = 2, count = 2 } })
  D.render(q, spans)
  local ok = false
  for _, m in ipairs(marks(q, "quilt.decor.highlights")) do
    local d = m[4]
    eq(m[2] >= 0 and m[2] <= 2, true)
    eq((d.end_row or m[2]) <= 2, true)
    if d.hl_group:find("^@string") and m[2] == 0 and m[3] == 0 then
      ok = true
    end
  end
  eq(ok, true)
end

T["source with no parser: no error, no highlights"] = function()
  local a = mkbuf({ "just text", "more" }, nil, "nosuchlang")
  local q, spans = quilt_of({ { src = a, start = 0, count = 2 } })
  D.render(q, spans)
  eq(#marks(q, "quilt.decor.highlights"), 0)
  eq(#marks(q, "quilt.decor.headers"), 1)
end

T["diagnostics inside spans show on mapped rows, outside are skipped"] = function()
  local a = mkbuf({ "a", "b", "c", "d", "e" })
  local ns = vim.api.nvim_create_namespace("quilt.test.diag")
  vim.diagnostic.set(ns, a, {
    { lnum = 0, col = 0, message = "out above" },
    { lnum = 2, col = 1, end_lnum = 2, end_col = 1, message = "in", severity = 1 },
    { lnum = 3, col = 0, end_lnum = 4, end_col = 1, message = "crosses" },
    { lnum = 4, col = 0, message = "out below" },
  })
  local q, spans = quilt_of({ { src = a, start = 2, count = 2 } })
  D.render(q, spans)
  local got = vim.diagnostic.get(q)
  table.sort(got, function(x, y)
    return x.lnum < y.lnum
  end)
  eq(#got, 2)
  eq({ got[1].lnum, got[1].col, got[1].message, got[1].severity }, { 0, 1, "in", 1 })
  eq({ got[2].lnum, got[2].message, got[2].end_lnum }, { 1, "crosses", 1 })
  D.render(q, spans)
  eq(#vim.diagnostic.get(q), 2)
end

T["show_top makes the first header visible"] = function()
  local a = mkbuf({ "a", "b" })
  local q, spans = quilt_of({ { src = a, start = 0, count = 2 } })
  vim.api.nvim_set_current_buf(q)
  D.render(q, spans)
  D.show_top(vim.api.nvim_get_current_win())
  eq(vim.fn.winsaveview().topfill, 1)
end

return T
