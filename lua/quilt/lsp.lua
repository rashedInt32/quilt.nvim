-- LSP requests against a source position, independent of any window cursor.
local M = {}

---@class quilt.Pos
---@field src integer   source bufnr
---@field row integer
---@field col integer   byte column

local function notify(msg, level)
  vim.notify("quilt: " .. msg, level or vim.log.levels.INFO)
end

---@param pos quilt.Pos
---@param method string
---@return vim.lsp.Client[]
local function clients_for(pos, method)
  local list = vim.lsp.get_clients({ bufnr = pos.src, method = method })
  if #list == 0 then
    notify("no LSP client supports " .. method, vim.log.levels.WARN)
  end
  return list
end

local function position(client, pos)
  local enc = client.offset_encoding or "utf-16"
  return { line = pos.row, character = vim.lsp.util.character_offset(pos.src, pos.row, pos.col, enc) }
end

local function params_for(client, pos)
  return { textDocument = { uri = vim.uri_from_bufnr(pos.src) }, position = position(client, pos) }
end

local function report(err)
  notify(err.message or vim.inspect(err), vim.log.levels.ERROR)
end

-- Flatten Location | Location[] | LocationLink[] into { uri, range } items.
local function locations(result)
  if not result or result == vim.NIL then
    return {}
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  local out = {}
  for _, l in ipairs(result) do
    table.insert(out, { uri = l.uri or l.targetUri, range = l.range or l.targetSelectionRange or l.targetRange })
  end
  return out
end

---@param pos quilt.Pos
function M.hover(pos)
  local clients = clients_for(pos, "textDocument/hover")
  local client = clients[1]
  if not client then
    return
  end
  client:request("textDocument/hover", params_for(client, pos), function(err, result)
    if err then
      return report(err)
    end
    local lines = {}
    if result and result ~= vim.NIL and result.contents then
      lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
      lines = vim.split(table.concat(lines, "\n"), "\n", { trimempty = true })
    end
    if #lines == 0 then
      return notify("no hover information")
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", { focus_id = "quilt_hover", border = "rounded" })
  end, pos.src)
end

local function jump(method, pos, opts)
  opts = opts or {}
  local clients = clients_for(pos, method)
  local client = clients[1]
  if not client then
    return
  end
  local enc = client.offset_encoding or "utf-16"
  client:request(method, params_for(client, pos), function(err, result)
    if err then
      return report(err)
    end
    local loc = locations(result)[1]
    if not loc then
      return notify("no location found")
    end
    if opts.on_location then
      local bufnr = vim.uri_to_bufnr(loc.uri)
      vim.fn.bufload(bufnr)
      local row = loc.range.start.line
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local ok, col = pcall(vim.str_byteindex, line, enc, loc.range.start.character, false)
      if opts.on_location(bufnr, row, ok and col or #line) then
        return
      end
    end
    vim.lsp.util.show_document(loc, enc, { focus = true, reuse_win = true })
  end, pos.src)
end

---@param pos quilt.Pos
---@param opts? { on_location?: fun(bufnr: integer, row: integer, col: integer): boolean? }
function M.definition(pos, opts)
  jump("textDocument/definition", pos, opts)
end

---@param pos quilt.Pos
---@param opts? { on_location?: fun(bufnr: integer, row: integer, col: integer): boolean? }
function M.implementation(pos, opts)
  jump("textDocument/implementation", pos, opts)
end

---@param pos quilt.Pos
---@param cb fun(hits: quilt.Hit[]?, err: string?)
function M.references(pos, cb)
  local method = "textDocument/references"
  local clients = clients_for(pos, method)
  if #clients == 0 then
    return cb(nil, "no LSP client supports " .. method)
  end
  local hits, pending, failed = {}, #clients, nil
  for _, client in ipairs(clients) do
    local params = params_for(client, pos)
    params.context = { includeDeclaration = true }
    client:request(method, params, function(err, result)
      if err then
        failed = err.message or "request failed"
      end
      for _, loc in ipairs(locations(result)) do
        local s, e = loc.range.start, loc.range["end"]
        local end_row = e.line + ((e.character == 0 and e.line > s.line) and 0 or 1)
        table.insert(hits, {
          path = vim.uri_to_fname(loc.uri),
          row = s.line,
          end_row = math.max(end_row, s.line + 1),
        })
      end
      pending = pending - 1
      if pending == 0 then
        if #hits == 0 and failed then
          return cb(nil, failed)
        end
        cb(hits)
      end
    end, pos.src)
  end
end

---@param pos quilt.Pos
---@param new_name? string
function M.rename(pos, new_name)
  local clients = clients_for(pos, "textDocument/rename")
  local client = clients[1]
  if not client then
    return
  end
  local function send(name)
    if not name or name == "" then
      return
    end
    local params = params_for(client, pos)
    params.newName = name
    client:request("textDocument/rename", params, function(err, result)
      if err then
        return report(err)
      end
      if result and result ~= vim.NIL then
        vim.lsp.util.apply_workspace_edit(result, client.offset_encoding or "utf-16")
      end
    end, pos.src)
  end
  if new_name then
    return send(new_name)
  end
  local line = vim.api.nvim_buf_get_lines(pos.src, pos.row, pos.row + 1, false)[1] or ""
  local word = vim.fn.matchstr(line, [[\k*\%]] .. (pos.col + 1) .. [[c\k*]])
  vim.ui.input({ prompt = "New name: ", default = word }, send)
end

local function run_action(client, action)
  local enc = client.offset_encoding or "utf-16"
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, enc)
  end
  local command = type(action.command) == "table" and action.command or (action.command and action)
  if command then
    client:exec_cmd(command, { bufnr = nil })
  end
end

---@param pos quilt.Pos
function M.code_action(pos)
  local method = "textDocument/codeAction"
  local clients = clients_for(pos, method)
  if #clients == 0 then
    return
  end
  local diagnostics = {}
  for _, d in ipairs(vim.diagnostic.get(pos.src, { lnum = pos.row })) do
    local lsp_d = d.user_data and d.user_data.lsp
    if lsp_d then
      table.insert(diagnostics, lsp_d)
    end
  end
  local items, pending = {}, #clients
  local function choose()
    if #items == 0 then
      return notify("no code actions available")
    end
    vim.ui.select(items, {
      prompt = "Code action:",
      format_item = function(item)
        return item.action.title
      end,
    }, function(item)
      if not item then
        return
      end
      local client, action = item.client, item.action
      if not action.edit and type(action.command) ~= "table" and client:supports_method("codeAction/resolve") then
        client:request("codeAction/resolve", action, function(err, resolved)
          if err then
            return report(err)
          end
          run_action(client, resolved or action)
        end, pos.src)
      else
        run_action(client, action)
      end
    end)
  end
  for _, client in ipairs(clients) do
    local params = params_for(client, pos)
    params.range = { start = params.position, ["end"] = params.position }
    params.context = { diagnostics = diagnostics }
    client:request(method, params, function(_, result)
      for _, action in ipairs(type(result) == "table" and result or {}) do
        table.insert(items, { client = client, action = action })
      end
      pending = pending - 1
      if pending == 0 then
        choose()
      end
    end, pos.src)
  end
end

return M
