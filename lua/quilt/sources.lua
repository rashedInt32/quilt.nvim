-- Sources: hits from quickfix, grep, diagnostics and git, and hits -> ranges.
-- Rows are 0-based and end-exclusive everywhere.
local M = {}

local SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warn = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

---@param path string
---@param root string?
---@return string
local function absolute(path, root)
  if root and path:sub(1, 1) ~= "/" then
    return vim.fs.joinpath(root, path)
  end
  return path
end

--- Hits from a quickfix list (default: the current one). Invalid items are skipped.
---@param list table[]?
---@return quilt.Hit[]
function M.from_qf(list)
  list = list or vim.fn.getqflist()
  local hits = {}
  for _, item in ipairs(list) do
    local hit
    if item.valid ~= 0 then
      local row = math.max((item.lnum or 0) - 1, 0)
      local end_lnum = item.end_lnum
      local end_row = (end_lnum and end_lnum > row + 1) and end_lnum or nil
      if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
        hit = { bufnr = item.bufnr, row = row, end_row = end_row, text = item.text }
      elseif item.filename and item.filename ~= "" then
        hit = { path = absolute(item.filename, vim.fn.getcwd()), row = row, end_row = end_row, text = item.text }
      end
    end
    hits[#hits + 1] = hit
  end
  return vim.tbl_filter(function(h)
    return h ~= nil
  end, hits)
end

--- Hits from diagnostics at or above `min_severity`, all buffers.
---@param min_severity ("error"|"warn"|"info"|"hint"|integer)?
---@return quilt.Hit[]
function M.from_diagnostics(min_severity)
  local sev = type(min_severity) == "string" and SEVERITY[min_severity:lower()] or min_severity
  local opts = sev and { severity = { min = sev } } or nil
  local hits = {}
  for _, d in ipairs(vim.diagnostic.get(nil, opts)) do
    if vim.api.nvim_buf_is_valid(d.bufnr) then
      hits[#hits + 1] = {
        bufnr = d.bufnr,
        row = d.lnum,
        end_row = math.max(d.end_lnum or d.lnum, d.lnum) + 1,
        text = d.message,
      }
    end
  end
  table.sort(hits, function(a, b)
    if a.bufnr ~= b.bufnr then
      return a.bufnr < b.bufnr
    end
    return a.row < b.row
  end)
  return hits
end

--- Parse `rg --vimgrep` output: "path:line:col:text". The text may hold colons.
--- Relative paths are joined to `cwd` when it is given.
---@param lines string[]
---@param cwd string?
---@return quilt.Hit[]
function M.parse_vimgrep(lines, cwd)
  local hits = {}
  for _, line in ipairs(lines) do
    local path, lnum, text = line:match("^(.-):(%d+):%d+:(.*)$")
    if path and path ~= "" then
      hits[#hits + 1] = { path = absolute(path, cwd), row = tonumber(lnum) - 1, text = text }
    end
  end
  return hits
end

--- Parse `git diff -U0` output into one hit per hunk, in the new file.
--- A pure deletion becomes a one-row hit at the row after it; `to_ranges` clamps it.
--- Deleted files are skipped. Paths are joined to `root` when it is given.
---@param lines string[]
---@param root string?
---@return quilt.Hit[]
function M.parse_diff(lines, root)
  local hits = {}
  local path ---@type string?
  local old_left, new_left = 0, 0
  for _, line in ipairs(lines) do
    if old_left > 0 or new_left > 0 then
      -- inside a hunk body: a "+++ x" line here is added text, not a header
      local c = line:sub(1, 1)
      if c == "-" then
        old_left = old_left - 1
      elseif c == "+" then
        new_left = new_left - 1
      end
    elseif line:sub(1, 4) == "+++ " then
      local p = line:sub(5):gsub("\t.*$", "")
      if p == "/dev/null" then
        path = nil
      else
        p = p:gsub('^"(.*)"$', "%1"):gsub("^b/", "", 1)
        path = absolute(p, root)
      end
    elseif path and line:sub(1, 2) == "@@" then
      local o_count, start, count = line:match("^@@ %-%d+,?(%d*) %+(%d+),?(%d*) @@")
      if start then
        old_left = o_count == "" and 1 or tonumber(o_count)
        new_left = count == "" and 1 or tonumber(count)
        if new_left == 0 then
          hits[#hits + 1] = { path = path, row = tonumber(start), end_row = tonumber(start) + 1 }
        else
          hits[#hits + 1] = { path = path, row = tonumber(start) - 1, end_row = tonumber(start) - 1 + new_left }
        end
      end
    end
  end
  return hits
end

--- Run a command on the main loop's behalf. `cb(result)` gets a vim.SystemCompleted,
--- or nil and an error string when the program can't start.
local function run(cmd, cwd, cb)
  local ok, err = pcall(
    vim.system,
    cmd,
    { cwd = cwd, text = true },
    vim.schedule_wrap(function(res)
      cb(res)
    end)
  )
  if not ok then
    vim.schedule(function()
      cb(nil, tostring(err))
    end)
  end
end

--- Search with ripgrep.
---@param pattern string
---@param opts { cwd: string? }?
---@param cb fun(hits: quilt.Hit[]?, err: string?)
function M.grep(pattern, opts, cb)
  local cwd = (opts and opts.cwd) or vim.fn.getcwd()
  if vim.fn.executable("rg") == 0 then
    vim.schedule(function()
      cb(nil, "rg not found")
    end)
    return
  end
  local cmd = { "rg", "--vimgrep", "--no-heading", "--color=never", "--", pattern }
  run(cmd, cwd, function(res, err)
    if not res then
      return cb(nil, err == nil and "rg not found" or "rg not found: " .. err)
    end
    local out = vim.split(res.stdout or "", "\n", { plain = true, trimempty = true })
    if res.code == 0 or res.code == 1 or (res.code == 2 and #out > 0) then
      return cb(M.parse_vimgrep(out, cwd))
    end
    local msg = vim.trim(res.stderr or "")
    cb(nil, msg ~= "" and msg or ("rg exited with code " .. res.code))
  end)
end

--- Hunks of `git diff -U0 [ref]` in the repo that holds `opts.cwd`.
---@param ref string?
---@param opts { cwd: string? }?
---@param cb fun(hits: quilt.Hit[]?, err: string?)
function M.git(ref, opts, cb)
  local cwd = (opts and opts.cwd) or vim.fn.getcwd()
  if vim.fn.executable("git") == 0 then
    vim.schedule(function()
      cb(nil, "git not found")
    end)
    return
  end
  if ref == "" then
    ref = nil
  end
  if ref and ref:sub(1, 1) == "-" then
    vim.schedule(function()
      cb(nil, "invalid git ref: " .. ref)
    end)
    return
  end
  run({ "git", "rev-parse", "--show-toplevel" }, cwd, function(res, err)
    if not res then
      return cb(nil, err)
    end
    if res.code ~= 0 then
      local msg = vim.trim(res.stderr or "")
      return cb(nil, msg ~= "" and msg or "not a git repository")
    end
    local root = vim.trim(res.stdout or "")
    local cmd = {
      "git",
      "-c",
      "core.quotepath=off",
      "diff",
      "-U0",
      "--no-color",
      "--no-ext-diff",
      "--src-prefix=a/",
      "--dst-prefix=b/",
    }
    if ref then
      cmd[#cmd + 1] = ref
    end
    cmd[#cmd + 1] = "--"
    run(cmd, root, function(dres, derr)
      if not dres then
        return cb(nil, derr)
      end
      if dres.code ~= 0 then
        local msg = vim.trim(dres.stderr or "")
        return cb(nil, msg ~= "" and msg or ("git diff exited with code " .. dres.code))
      end
      local out = vim.split(dres.stdout or "", "\n", { plain = true, trimempty = true })
      cb(M.parse_diff(out, root))
    end)
  end)
end

--- Load the buffer of every hit and pad each hit by `context` rows, clamped to the file.
--- Buffers created here are unlisted. Every buffer loaded here is returned so the caller can unload it later.
--- Hits whose file can't be read are dropped, with one notice that counts them.
---@param hits quilt.Hit[]
---@param context integer?
---@return quilt.Range[] ranges
---@return integer[] created_bufnrs
function M.to_ranges(hits, context)
  context = math.max(context or 0, 0)
  local existing, by_name = {}, {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    existing[b] = true
    by_name[vim.api.nvim_buf_get_name(b)] = true
  end
  local by_path, created, ranges, dropped = {}, {}, {}, 0

  local function resolve(hit)
    if hit.bufnr then
      if not vim.api.nvim_buf_is_valid(hit.bufnr) then
        return nil
      end
      return hit.bufnr
    end
    local path = hit.path
    if not path or path == "" then
      return nil
    end
    if by_path[path] ~= nil then
      return by_path[path] or nil
    end
    local bufnr
    if by_name[path] or vim.fn.filereadable(path) == 1 then
      bufnr = vim.fn.bufadd(path)
      if not existing[bufnr] then
        existing[bufnr] = true
        created[#created + 1] = bufnr
        vim.bo[bufnr].buflisted = false
      end
    end
    by_path[path] = bufnr or false
    return bufnr
  end

  for _, hit in ipairs(hits) do
    local bufnr = resolve(hit)
    if bufnr and not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
      -- A quickfix list makes buffers without loading them; those are ours to unload too.
      if not vim.tbl_contains(created, bufnr) then
        created[#created + 1] = bufnr
      end
    end
    if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then
      dropped = dropped + 1
    else
      local n = vim.api.nvim_buf_line_count(bufnr)
      local row = math.min(math.max(hit.row, 0), n - 1)
      local end_row = math.max(hit.end_row or row + 1, row + 1)
      local start = math.max(row - context, 0)
      local stop = math.min(end_row + context, n)
      ranges[#ranges + 1] = { src = bufnr, start = start, count = stop - start }
    end
  end

  if dropped > 0 then
    vim.notify(("quilt: dropped %d hit(s) in files that could not be read"):format(dropped), vim.log.levels.WARN)
  end
  return ranges, created
end

return M
