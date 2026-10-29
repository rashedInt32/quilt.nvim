-- In-process fake LSP server. Load with require or dofile(path).
-- F.start(buf, {encoding="utf-16"|"utf-8", handlers={}, name?, root?}) -> server
-- server.handlers[method] = value | function(params) -> result, err; set any time
-- server.requests = { {method=, params=} ... } in arrival order; server:calls(method) filters
-- server:stop() ends the client; F.stop_all() ends every fake
local F = {}

local counter = 0
local servers = {}

local function capabilities(encoding)
  return {
    positionEncoding = encoding,
    hoverProvider = true,
    definitionProvider = true,
    implementationProvider = true,
    referencesProvider = true,
    renameProvider = true,
    codeActionProvider = { resolveProvider = true },
  }
end

local function make_cmd(server)
  return function(dispatchers)
    local closing = false
    local rpc = {}
    function rpc.request(method, params, callback)
      if method == "initialize" then
        local result = { capabilities = capabilities(server.encoding), offsetEncoding = server.encoding }
        vim.schedule(function()
          callback(nil, result)
        end)
        return true, 1
      end
      if method == "shutdown" then
        vim.schedule(function()
          callback(nil, vim.NIL)
        end)
        return true, 2
      end
      table.insert(server.requests, { method = method, params = params })
      local h = server.handlers[method]
      vim.schedule(function()
        local result, err
        if type(h) == "function" then
          result, err = h(params)
        else
          result = h
        end
        callback(err, result)
      end)
      return true, #server.requests + 2
    end
    function rpc.notify(method, params)
      if method ~= "exit" then
        table.insert(server.notifications, { method = method, params = params })
      else
        closing = true
        dispatchers.on_exit(0, 0)
      end
      return true
    end
    function rpc.is_closing()
      return closing
    end
    function rpc.terminate()
      closing = true
    end
    return rpc
  end
end

---@param buf integer buffer to attach to
---@param opts? { encoding?: string, handlers?: table, name?: string, root?: string }
function F.start(buf, opts)
  opts = opts or {}
  counter = counter + 1
  local server = {
    encoding = opts.encoding or "utf-16",
    handlers = opts.handlers or {},
    requests = {},
    notifications = {},
  }
  function server:calls(method)
    return vim.tbl_filter(function(r)
      return r.method == method
    end, self.requests)
  end
  function server:stop()
    local c = vim.lsp.get_client_by_id(self.client_id)
    if c then
      c:stop(true)
    end
  end
  local id = vim.lsp.start({
    name = opts.name or ("fake" .. counter),
    cmd = make_cmd(server),
    root_dir = opts.root or vim.fn.getcwd(),
  }, { bufnr = buf })
  assert(id, "fake_lsp: vim.lsp.start failed")
  server.client_id = id
  local ok = vim.wait(2000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c ~= nil and c.initialized and c.server_capabilities ~= nil
  end, 5)
  assert(ok, "fake_lsp: client did not initialize")
  table.insert(servers, server)
  return server
end

function F.stop_all()
  for _, s in ipairs(servers) do
    s:stop()
  end
  servers = {}
  vim.wait(500, function()
    return #vim.lsp.get_clients() == 0
  end, 5)
end

return F
