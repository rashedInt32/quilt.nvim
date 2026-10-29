-- Sources: vimgrep and diff parsing, qf and diagnostic hits, to_ranges, grep and git.
local eq = MiniTest.expect.equality
local S = require("quilt.sources")

local dirs = {}
local notices = {}
local orig_notify = vim.notify

local function tmpdir()
  local d = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(d, "p")
  dirs[#dirs + 1] = d
  return d
end

local function write(path, lines)
  vim.fn.writefile(lines, path)
  return path
end

local function numbered(n)
  local t = {}
  for i = 1, n do
    t[i] = "line" .. i
  end
  return t
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      notices = {}
      vim.notify = function(msg, level)
        notices[#notices + 1] = { msg = msg, level = level }
      end
    end,
    post_case = function()
      vim.notify = orig_notify
      for _, d in ipairs(dirs) do
        vim.fn.delete(d, "rf")
      end
      dirs = {}
      vim.cmd("silent! %bwipeout!")
      vim.diagnostic.reset()
      vim.fn.setqflist({}, "r")
    end,
  },
})

T["parse_vimgrep keeps colons in the text and ignores blank lines"] = function()
  local hits = S.parse_vimgrep({ "src/a.lua:3:5:local x = a:b():c", "", "b.lua:10:1:", "garbage" }, "/proj")
  eq(hits, {
    { path = "/proj/src/a.lua", row = 2, text = "local x = a:b():c" },
    { path = "/proj/b.lua", row = 9, text = "" },
  })
end

T["parse_vimgrep leaves absolute paths alone and needs no cwd"] = function()
  eq(S.parse_vimgrep({ "/abs/f.lua:1:1:x" }, "/proj")[1].path, "/abs/f.lua")
  eq(S.parse_vimgrep({ "f.lua:1:1:x" })[1].path, "f.lua")
end

T["parse_diff handles add, change and pure delete"] = function()
  local hits = S.parse_diff({
    "diff --git a/f.lua b/f.lua",
    "index 111..222 100644",
    "--- a/f.lua",
    "+++ b/f.lua",
    "@@ -0,0 +1,2 @@",
    "+one",
    "+two",
    "@@ -10 +12 @@",
    "-old",
    "+new",
    "@@ -20,3 +21,0 @@",
    "-x",
    "-y",
    "-z",
  }, "/r")
  eq(hits, {
    { path = "/r/f.lua", row = 0, end_row = 2 },
    { path = "/r/f.lua", row = 11, end_row = 12 },
    { path = "/r/f.lua", row = 21, end_row = 22 },
  })
end

T["parse_diff does not read added text that looks like a header"] = function()
  local hits = S.parse_diff({
    "--- a/f.lua",
    "+++ b/f.lua",
    "@@ -1 +1,2 @@",
    "-a",
    "+++ b/evil.lua",
    "+b",
    "@@ -5 +6 @@",
    "-c",
    "+d",
  })
  eq(hits, {
    { path = "f.lua", row = 0, end_row = 2 },
    { path = "f.lua", row = 5, end_row = 6 },
  })
end

T["parse_diff covers several files, new files, deleted files and renames"] = function()
  local hits = S.parse_diff({
    "diff --git a/a.lua b/a.lua",
    "--- a/a.lua",
    "+++ b/a.lua",
    "@@ -1 +1 @@",
    "-x",
    "+y",
    "diff --git a/new.lua b/new.lua",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/new.lua",
    "@@ -0,0 +1,3 @@",
    "+1",
    "+2",
    "+3",
    "diff --git a/gone.lua b/gone.lua",
    "deleted file mode 100644",
    "--- a/gone.lua",
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    "-1",
    "-2",
    "diff --git a/old.lua b/dir/moved.lua",
    "similarity index 80%",
    "rename from old.lua",
    "rename to dir/moved.lua",
    "--- a/old.lua",
    "+++ b/dir/moved.lua",
    "@@ -4 +4 @@",
    "-p",
    "+q",
    "diff --git a/same.lua b/renamed_only.lua",
    "similarity index 100%",
    "rename from same.lua",
    "rename to renamed_only.lua",
  }, "/r")
  eq(hits, {
    { path = "/r/a.lua", row = 0, end_row = 1 },
    { path = "/r/new.lua", row = 0, end_row = 3 },
    { path = "/r/dir/moved.lua", row = 3, end_row = 4 },
  })
end

T["from_qf takes items with a bufnr and items with only a filename"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/f.lua", numbered(5))
  local buf = vim.fn.bufadd(file)
  local hits = S.from_qf({
    { bufnr = buf, lnum = 3, text = "hi", valid = 1 },
    { filename = file, lnum = 1, end_lnum = 4, text = "span" },
    { bufnr = 0, filename = "rel.lua", lnum = 0 },
  })
  eq(#hits, 3)
  eq(hits[1], { bufnr = buf, row = 2, text = "hi" })
  eq(hits[2], { path = file, row = 0, end_row = 4, text = "span" })
  eq(hits[3].path, vim.fn.getcwd() .. "/rel.lua")
  eq(hits[3].row, 0)
end

T["from_qf skips invalid items and items without a file"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/f.lua", numbered(2))
  local hits = S.from_qf({
    { filename = file, lnum = 1, valid = 0 },
    { text = "just a message", valid = 1 },
    { bufnr = 0, filename = "", lnum = 4 },
    { filename = file, lnum = 2 },
  })
  eq(#hits, 1)
  eq(hits[1].row, 1)
end

T["from_qf reads the current quickfix list by default"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/f.lua", numbered(4))
  vim.fn.setqflist({ { filename = file, lnum = 2, text = "x" } })
  local hits = S.from_qf()
  eq(#hits, 1)
  eq(hits[1].row, 1)
  eq(vim.api.nvim_buf_get_name(hits[1].bufnr), file)
end

T["from_diagnostics filters by severity"] = function()
  local dir = tmpdir()
  local buf = vim.fn.bufadd(write(dir .. "/f.lua", numbered(6)))
  vim.fn.bufload(buf)
  local ns = vim.api.nvim_create_namespace("quilt_test_diag")
  local sev = vim.diagnostic.severity
  vim.diagnostic.set(ns, buf, {
    { lnum = 0, col = 0, severity = sev.ERROR, message = "e" },
    { lnum = 2, col = 0, end_lnum = 3, severity = sev.WARN, message = "w" },
    { lnum = 4, col = 0, severity = sev.HINT, message = "h" },
  })
  local function rows(hits)
    return vim.tbl_map(function(h)
      return h.row
    end, hits)
  end
  eq(rows(S.from_diagnostics()), { 0, 2, 4 })
  eq(rows(S.from_diagnostics("error")), { 0 })
  eq(rows(S.from_diagnostics("warn")), { 0, 2 })
  eq(rows(S.from_diagnostics("hint")), { 0, 2, 4 })
  local warn = S.from_diagnostics("warn")[2]
  eq(warn.bufnr, buf)
  eq(warn.end_row, 4)
  eq(warn.text, "w")
end

T["to_ranges pads with context and clamps at the file start and end"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/f.lua", numbered(10))
  local ranges = S.to_ranges({
    { path = file, row = 1 },
    { path = file, row = 9 },
    { path = file, row = 4, end_row = 6 },
  }, 3)
  local buf = ranges[1].src
  eq(ranges, {
    { src = buf, start = 0, count = 5 },
    { src = buf, start = 6, count = 4 },
    { src = buf, start = 1, count = 8 },
  })
end

T["to_ranges returns a buffer that existed unloaded, as a quickfix list leaves it"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/qf.lua", numbered(3))
  local buf = vim.fn.bufadd(file)
  eq(vim.api.nvim_buf_is_loaded(buf), false)
  local _, created = S.to_ranges({ { bufnr = buf, row = 0 } }, 0)
  eq(created, { buf })
  eq(vim.api.nvim_buf_is_loaded(buf), true)
end

T["to_ranges clamps a row past the end to the last line"] = function()
  local dir = tmpdir()
  local file = write(dir .. "/f.lua", numbered(4))
  local ranges = S.to_ranges({ { path = file, row = 4, end_row = 5 } }, 0)
  eq(ranges[1].start, 3)
  eq(ranges[1].count, 1)
end

T["to_ranges creates unlisted buffers and returns only the ones it loaded"] = function()
  local dir = tmpdir()
  local old = write(dir .. "/old.lua", numbered(3))
  local new = write(dir .. "/new.lua", numbered(3))
  local old_buf = vim.fn.bufadd(old)
  vim.fn.bufload(old_buf)
  vim.bo[old_buf].buflisted = true
  local ranges, created = S.to_ranges({ { path = old, row = 0 }, { path = new, row = 1 }, { path = new, row = 2 } }, 0)
  eq(#ranges, 3)
  eq(ranges[1].src, old_buf)
  eq(#created, 1)
  eq(created[1], ranges[2].src)
  eq(vim.bo[created[1]].buflisted, false)
  eq(vim.bo[old_buf].buflisted, true)
  eq(vim.api.nvim_buf_is_loaded(old_buf), true)
  eq(vim.api.nvim_buf_is_loaded(created[1]), true)
end

T["to_ranges accepts hits that carry a bufnr"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, numbered(5))
  local ranges, created = S.to_ranges({ { bufnr = buf, row = 2 } }, 1)
  eq(ranges, { { src = buf, start = 1, count = 3 } })
  eq(created, {})
end

T["to_ranges drops unreadable paths with one notice"] = function()
  local dir = tmpdir()
  local good = write(dir .. "/good.lua", numbered(3))
  local ranges, created = S.to_ranges({
    { path = dir .. "/missing1.lua", row = 0 },
    { path = good, row = 1 },
    { path = dir .. "/missing2.lua", row = 0 },
    { path = dir, row = 0 },
  }, 0)
  eq(#ranges, 1)
  eq(#created, 1)
  eq(#notices, 1)
  eq(notices[1].msg:find("3", 1, true) ~= nil, true)
  eq(notices[1].level, vim.log.levels.WARN)
end

T["to_ranges gives no notice when nothing is dropped"] = function()
  eq(S.to_ranges({}, 3), {})
  eq(notices, {})
end

local function wait(fn)
  vim.wait(5000, fn, 10)
end

T["grep returns hits with absolute paths from rg"] = function()
  if vim.fn.executable("rg") == 0 then
    MiniTest.skip("rg is not installed")
  end
  local dir = tmpdir()
  write(dir .. "/a.txt", { "nothing", "needle: here", "x" })
  vim.fn.mkdir(dir .. "/sub")
  write(dir .. "/sub/b.txt", { "a needle" })
  local done, got, err = false, nil, nil
  S.grep("needle", { cwd = dir }, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(err, nil)
  table.sort(got, function(a, b)
    return a.path < b.path
  end)
  eq(got, {
    { path = dir .. "/a.txt", row = 1, text = "needle: here" },
    { path = dir .. "/sub/b.txt", row = 0, text = "a needle" },
  })
end

T["grep with no match returns empty hits and no error"] = function()
  if vim.fn.executable("rg") == 0 then
    MiniTest.skip("rg is not installed")
  end
  local dir = tmpdir()
  write(dir .. "/a.txt", { "nothing" })
  local done, got, err = false, nil, nil
  S.grep("zzzqqq", { cwd = dir }, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(err, nil)
  eq(got, {})
end

T["grep reports a bad pattern as an error"] = function()
  if vim.fn.executable("rg") == 0 then
    MiniTest.skip("rg is not installed")
  end
  local dir = tmpdir()
  write(dir .. "/a.txt", { "nothing" })
  local done, got, err = false, nil, nil
  S.grep("(unclosed", { cwd = dir }, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(got, nil)
  eq(type(err), "string")
end

T["git returns the hunks of a changed file with absolute paths"] = function()
  if vim.fn.executable("git") == 0 then
    MiniTest.skip("git is not installed")
  end
  local dir = tmpdir()
  local function git(...)
    local res = vim
      .system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... }, { cwd = dir, text = true })
      :wait()
    assert(res.code == 0, res.stderr)
  end
  git("init", "-q")
  write(dir .. "/f.lua", numbered(10))
  git("add", ".")
  git("commit", "-q", "-m", "init")
  local changed = numbered(10)
  changed[3] = "changed"
  table.remove(changed, 8)
  write(dir .. "/f.lua", changed)
  vim.fn.mkdir(dir .. "/sub")
  local done, got, err = false, nil, nil
  -- run from a subdirectory: paths must still be relative to the repo root
  S.git(nil, { cwd = dir .. "/sub" }, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(err, nil)
  eq(got, {
    { path = dir .. "/f.lua", row = 2, end_row = 3 },
    { path = dir .. "/f.lua", row = 7, end_row = 8 },
  })
end

T["git reports an error outside a repository"] = function()
  if vim.fn.executable("git") == 0 then
    MiniTest.skip("git is not installed")
  end
  local dir = tmpdir()
  local done, got, err = false, nil, nil
  S.git(nil, { cwd = dir }, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(got, nil)
  eq(type(err), "string")
end

T["git refuses a ref that looks like an option"] = function()
  local done, got, err = false, nil, nil
  S.git("--output=/tmp/x", {}, function(hits, e)
    got, err, done = hits, e, true
  end)
  wait(function()
    return done
  end)
  eq(got, nil)
  eq(type(err), "string")
end

return T
