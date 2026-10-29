-- lsp.lua against a fake in-process server, with the cursor outside the source buffer.
local eq = MiniTest.expect.equality
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local fake = dofile(root .. "/tests/helpers/fake_lsp.lua")
local L = require("quilt.lsp")

local dir, orig_notify, orig_input, orig_select, notices

local function write(name, lines)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf, path
end

local function uri(path)
  return vim.uri_from_fname(path)
end

local function range(l1, c1, l2, c2)
  return { start = { line = l1, character = c1 }, ["end"] = { line = l2, character = c2 } }
end

local function wait(fn)
  eq(vim.wait(2000, fn, 5), true)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fn.resolve(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      notices = {}
      orig_notify, orig_input, orig_select = vim.notify, vim.ui.input, vim.ui.select
      vim.notify = function(msg)
        table.insert(notices, msg)
      end
    end,
    post_case = function()
      vim.notify, vim.ui.input, vim.ui.select = orig_notify, orig_input, orig_select
      fake.stop_all()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(dir, "rf")
    end,
  },
})

T["position goes out in utf-16 for a line with multibyte text"] = function()
  local buf = write("a.txt", { "é😀x" })
  local s = fake.start(buf, { encoding = "utf-16", handlers = { ["textDocument/hover"] = { contents = "x" } } })
  L.hover({ src = buf, row = 0, col = 6 })
  wait(function()
    return #s:calls("textDocument/hover") == 1
  end)
  local p = s:calls("textDocument/hover")[1].params
  eq(p.position, { line = 0, character = 3 })
  eq(p.textDocument.uri, vim.uri_from_bufnr(buf))
end

T["position goes out in utf-8 for a line with multibyte text"] = function()
  local buf = write("a.txt", { "é😀x" })
  local s = fake.start(buf, { encoding = "utf-8", handlers = { ["textDocument/hover"] = { contents = "x" } } })
  L.hover({ src = buf, row = 0, col = 6 })
  wait(function()
    return #s:calls("textDocument/hover") == 1
  end)
  eq(s:calls("textDocument/hover")[1].params.position, { line = 0, character = 6 })
end

T["hover opens a float with the markdown content"] = function()
  local buf = write("a.txt", { "hello" })
  fake.start(buf, {
    handlers = { ["textDocument/hover"] = { contents = { kind = "markdown", value = "**bold** text" } } },
  })
  L.hover({ src = buf, row = 0, col = 1 })
  wait(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        return true
      end
    end
  end)
  local float
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      float = w
    end
  end
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
  eq(table.concat(lines, "\n"):find("bold", 1, true) ~= nil, true)
end

local function def_setup()
  local buf = write("a.txt", { "call()" })
  local _, target = write("b.txt", { "zero", "one", "é😀def" })
  local s = fake.start(buf, {
    handlers = {
      ["textDocument/definition"] = { { uri = uri(target), range = range(2, 3, 2, 6) } },
    },
  })
  return buf, target, s
end

T["definition calls on_location first and stops when it returns true"] = function()
  local buf, target = def_setup()
  local got
  L.definition({ src = buf, row = 0, col = 0 }, {
    on_location = function(b, row, col)
      got = { name = vim.api.nvim_buf_get_name(b), row = row, col = col }
      return true
    end,
  })
  wait(function()
    return got ~= nil
  end)
  eq(got, { name = target, row = 2, col = 6 })
  vim.wait(100)
  eq(vim.api.nvim_buf_get_name(0) == target, false)
end

T["definition falls back to show_document when on_location returns false"] = function()
  local buf, target = def_setup()
  local called = false
  L.definition({ src = buf, row = 0, col = 0 }, {
    on_location = function()
      called = true
      return false
    end,
  })
  wait(function()
    return vim.api.nvim_buf_get_name(0) == target
  end)
  eq(called, true)
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end

T["references returns hits with rows and paths"] = function()
  local buf, path = write("a.txt", { "x" })
  local _, other = write("b.txt", { "y", "z" })
  local s = fake.start(buf, {
    handlers = {
      ["textDocument/references"] = {
        { uri = uri(path), range = range(0, 0, 0, 1) },
        { uri = uri(other), range = range(1, 0, 3, 0) },
        { uri = uri(other), range = range(1, 2, 1, 2) },
      },
    },
  })
  local hits, err
  L.references({ src = buf, row = 0, col = 0 }, function(h, e)
    hits, err = h, e
  end)
  wait(function()
    return hits ~= nil or err ~= nil
  end)
  eq(err, nil)
  eq(hits, {
    { path = path, row = 0, end_row = 1 },
    { path = other, row = 1, end_row = 3 },
    { path = other, row = 1, end_row = 2 },
  })
  eq(s:calls("textDocument/references")[1].params.context.includeDeclaration, true)
end

T["rename applies the workspace edit to the source buffer"] = function()
  local buf, path = write("a.txt", { "foo = foo" })
  local s = fake.start(buf, {
    handlers = {
      ["textDocument/rename"] = function(params)
        return {
          changes = {
            [uri(path)] = {
              { range = range(0, 0, 0, 3), newText = params.newName },
              { range = range(0, 6, 0, 9), newText = params.newName },
            },
          },
        }
      end,
    },
  })
  L.rename({ src = buf, row = 0, col = 1 }, "bar")
  wait(function()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "bar = bar"
  end)
  eq(s:calls("textDocument/rename")[1].params.newName, "bar")
end

T["rename prompts with vim.ui.input when no name is given"] = function()
  local buf, path = write("a.txt", { "foo" })
  local prompt_default
  vim.ui.input = function(opts, on_confirm)
    prompt_default = opts.default
    on_confirm("baz")
  end
  fake.start(buf, {
    handlers = {
      ["textDocument/rename"] = function(params)
        return { changes = { [uri(path)] = { { range = range(0, 0, 0, 3), newText = params.newName } } } }
      end,
    },
  })
  L.rename({ src = buf, row = 0, col = 1 })
  wait(function()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "baz"
  end)
  eq(prompt_default, "foo")
end

T["code_action applies an edit chosen through vim.ui.select"] = function()
  local buf, path = write("a.txt", { "abc" })
  local titles
  vim.ui.select = function(items, opts, on_choice)
    titles = vim.tbl_map(opts.format_item, items)
    on_choice(items[2])
  end
  local s = fake.start(buf, {
    handlers = {
      ["textDocument/codeAction"] = {
        { title = "first", edit = { changes = { [uri(path)] = { { range = range(0, 0, 0, 1), newText = "no" } } } } },
        { title = "second", edit = { changes = { [uri(path)] = { { range = range(0, 0, 0, 1), newText = "X" } } } } },
      },
    },
  })
  L.code_action({ src = buf, row = 0, col = 2 })
  wait(function()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "Xbc"
  end)
  eq(titles, { "first", "second" })
  eq(s:calls("textDocument/codeAction")[1].params.range.start, { line = 0, character = 2 })
end

T["no client gives one notice and no error"] = function()
  local buf = write("a.txt", { "abc" })
  local pos = { src = buf, row = 0, col = 0 }
  local cb_called = false
  L.hover(pos)
  L.definition(pos)
  L.implementation(pos)
  L.rename(pos, "x")
  L.code_action(pos)
  L.references(pos, function(h, e)
    cb_called = true
    eq(h, nil)
    eq(type(e), "string")
  end)
  eq(cb_called, true)
  -- one notice per call, never an error
  eq(#notices, 6)
  eq(notices[1]:find("no LSP client", 1, true) ~= nil, true)
end

return T
