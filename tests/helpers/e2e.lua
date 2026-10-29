-- End to end helpers: child Neovim, temp files, settle, and the sync oracle read from real buffers.
local eq = MiniTest.expect.equality

local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local dirs = {}

function H.new_child()
  return MiniTest.new_child_neovim()
end

function H.restart(child)
  child.restart({ "-u", H.root .. "/tests/minimal_init.lua" })
  child.o.lines, child.o.columns = 30, 80
end

-- { "a1", "a2", ... } for a file with n lines.
function H.lines(prefix, n)
  local out = {}
  for i = 1, n do
    out[i] = prefix .. i
  end
  return out
end

-- Writes files into a fresh temp dir and makes it the child's cwd.
-- files: { [relpath] = lines }. Returns { dir = dir, paths = { [relpath] = abspath } }.
function H.setup(child, files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  dirs[#dirs + 1] = dir
  local paths = {}
  for rel, lines in pairs(files) do
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    paths[rel] = path
  end
  child.cmd("cd " .. vim.fn.fnameescape(dir))
  return { dir = dir, paths = paths }
end

function H.cleanup()
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, "rf")
  end
  dirs = {}
end

function H.config(child, opts)
  child.lua("require('quilt').setup(...)", { opts })
end

-- Sets the quickfix list from { { path, lnum }, ... } (lnum 1-based), runs :Quilt, returns the quilt bufnr.
function H.quilt_qf(child, hits)
  child.lua(
    [[
    local items = {}
    for _, h in ipairs(...) do
      items[#items + 1] = { filename = h[1], lnum = h[2], col = 1, text = "hit" }
    end
    vim.fn.setqflist({}, " ", { items = items })
  ]],
    { hits }
  )
  child.cmd("Quilt")
  local qbuf = child.api.nvim_get_current_buf()
  eq(child.lua_get("require('quilt.buffer').get(...) ~= nil", { qbuf }), true)
  H.settle(child, qbuf)
  return qbuf
end

-- Waits until every queued edit of the quilt has been applied.
function H.settle(child, qbuf)
  local ok = child.lua(
    [[
    local qbuf = ...
    local B = require("quilt.buffer")
    return vim.wait(1000, function() return B.pending(qbuf) == 0 end, 5)
  ]],
    { qbuf }
  )
  eq(ok, true)
end

function H.bufnr(child, path)
  return child.lua(
    [[
    local path = ...
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == path then return b end
    end
    return -1
  ]],
    { path }
  )
end

function H.buf_lines(child, path)
  local buf = H.bufnr(child, path)
  if buf == -1 then
    error("no buffer for " .. path)
  end
  return child.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function H.quilt_lines(child, qbuf)
  return child.api.nvim_buf_get_lines(qbuf, 0, -1, false)
end

function H.modified(child, buf)
  return child.api.nvim_get_option_value("modified", { buf = buf })
end

function H.disk(path)
  return vim.fn.readfile(path)
end

function H.spans(child, qbuf)
  return child.lua_get("require('quilt.buffer').get(...).model:spans()", { qbuf })
end

-- Spans of one source as { { src_start, count }, ... }.
function H.spans_of(child, qbuf, path)
  local buf = H.bufnr(child, path)
  local out = {}
  for _, s in ipairs(H.spans(child, qbuf)) do
    if s.src == buf and s.count > 0 then -- collapsed spans are hidden
      out[#out + 1] = { s.src_start, s.count }
    end
  end
  return out
end

-- Moves the cursor to a 0-based quilt row with real keys.
function H.go(child, qrow)
  child.type_keys(tostring(qrow + 1) .. "G")
end

function H.cursor_row(child)
  return child.api.nvim_win_get_cursor(0)[1] - 1
end

function H.screen_rows(child)
  local shot = child.get_screenshot()
  local rows = {}
  for i, cells in ipairs(shot.text) do
    rows[i] = table.concat(cells)
  end
  return rows
end

-- The oracle: quilt text equals the concatenated source rows of each span, read from the real buffers.
-- Also checks count >= 0 (0 is a collapsed span), q_start, and that spans of one source are contiguous,
-- sorted, and non-overlapping.
function H.check(child, qbuf)
  local r = child.lua(
    [[
    local qbuf = ...
    local st = require("quilt.buffer").get(qbuf)
    if not st then return { errs = { "no quilt state for " .. qbuf } } end
    local spans = st.model:spans()
    local want, errs, seen, prev, last_src = {}, {}, {}, {}, nil
    for i, s in ipairs(spans) do
      local tag = ("span %d (id %s, src %s)"):format(i, tostring(s.id), tostring(s.src))
      if s.count < 0 then errs[#errs + 1] = tag .. ": count " .. s.count end
      if s.q_start ~= #want then errs[#errs + 1] = tag .. ": q_start " .. s.q_start .. ", want " .. #want end
      if not vim.api.nvim_buf_is_loaded(s.src) then errs[#errs + 1] = tag .. ": source not loaded" end
      if s.src ~= last_src then
        if seen[s.src] then errs[#errs + 1] = tag .. ": spans of this source are not contiguous" end
        seen[s.src], last_src = true, s.src
      elseif s.src_start < prev[s.src].src_start + prev[s.src].count then
        errs[#errs + 1] = tag .. ": overlaps or precedes the span before it"
      end
      prev[s.src] = s
      local rows = vim.api.nvim_buf_get_lines(s.src, s.src_start, s.src_start + s.count, false)
      if #rows ~= s.count then errs[#errs + 1] = tag .. ": runs past the end of its source" end
      vim.list_extend(want, rows)
    end
    local lc = st.model:line_count()
    if lc ~= #want then errs[#errs + 1] = ("line_count %d, spans cover %d"):format(lc, #want) end
    if #want == 0 then want = { "" } end -- an empty quilt still holds one line
    return { errs = errs, want = want, got = vim.api.nvim_buf_get_lines(qbuf, 0, -1, false) }
  ]],
    { qbuf }
  )
  eq(r.errs, {})
  eq(r.got, r.want)
end

return H
