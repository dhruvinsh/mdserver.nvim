-- Minimal HTTP/1.1 server on vim.uv: GET/POST, one request per connection,
-- plus server-sent event streams. Request handlers run on the main loop.
local uv = vim.uv

local M = {}

local MAX_HEADER = 16 * 1024

local reasons = {
  [200] = "OK",
  [204] = "No Content",
  [206] = "Partial Content",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [416] = "Range Not Satisfiable",
  [500] = "Internal Server Error",
}

---@param handle uv.uv_handle_t
function M.close(handle)
  if not handle:is_closing() then
    handle:close()
  end
end

---@param s string
---@return string
function M.decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---@param s string path, `/` is kept
---@return string
function M.encode_path(s)
  return (s:gsub("[^%w%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

---@param query string
---@return table<string, string>
function M.parse_query(query)
  local params = {}
  for key, value in query:gmatch("([^&=]+)=?([^&]*)") do
    params[M.decode(key)] = M.decode((value:gsub("+", " ")))
  end
  return params
end

---@class mdserver.Request
---@field method string
---@field path string decoded path
---@field query table<string, string>
---@field headers table<string, string> lower-cased names
---@field client uv.uv_tcp_t

---@class mdserver.ResponseOpts
---@field type? string Content-Type
---@field cache? string Cache-Control, default "no-store"
---@field headers? table<string, string|integer> extra headers

---@param client uv.uv_tcp_t
---@param status integer
---@param body? string
---@param opts? mdserver.ResponseOpts
function M.respond(client, status, body, opts)
  if client:is_closing() then
    return
  end
  body = body or ""
  opts = opts or {}
  local head = {
    ("HTTP/1.1 %d %s"):format(status, reasons[status] or ""),
    "Content-Type: " .. (opts.type or "text/plain; charset=utf-8"),
    "Content-Length: " .. #body,
    "Cache-Control: " .. (opts.cache or "no-store"),
    "X-Content-Type-Options: nosniff",
    "Connection: close",
  }
  for name, value in pairs(opts.headers or {}) do
    table.insert(head, name .. ": " .. value)
  end
  vim.list_extend(head, { "", "" })
  client:write(table.concat(head, "\r\n") .. body, function()
    client:shutdown(function()
      M.close(client)
    end)
  end)
end

--- Turn the connection into an event stream.
---@param client uv.uv_tcp_t
---@param on_close fun()
function M.event_stream(client, on_close)
  client:write(table.concat({
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-store",
    "Connection: keep-alive",
    "",
    "retry: 2000",
    "",
    "",
  }, "\r\n"))
  -- Only EOF is expected from here on: the browser went away.
  client:read_start(function(err, chunk)
    if err or not chunk then
      M.close(client)
      vim.schedule(on_close)
    end
  end)
end

---@param client uv.uv_tcp_t
---@param event string
---@param data table
function M.send_event(client, event, data)
  if not client:is_closing() then
    client:write(("event: %s\ndata: %s\n\n"):format(event, vim.json.encode(data)))
  end
end

---@param client uv.uv_tcp_t
---@param handler fun(req: mdserver.Request)
local function on_connection(client, handler)
  local buf = ""
  client:read_start(function(err, chunk)
    if err or not chunk then
      return M.close(client)
    end
    buf = buf .. chunk
    if not buf:find("\r\n\r\n", 1, true) then
      if #buf > MAX_HEADER then
        M.close(client)
      end
      return
    end
    client:read_stop()
    local method, target = buf:match("^(%u+) (%S+) HTTP/%d%.%d\r\n")
    if not method then
      return M.respond(client, 400)
    end
    if method ~= "GET" and method ~= "POST" then
      return M.respond(client, 405)
    end
    local headers = {}
    for name, value in buf:sub(1, buf:find("\r\n\r\n", 1, true)):gmatch("\r\n([%w%-]+):%s*([^\r]*)") do
      headers[name:lower()] = value
    end
    local path, query = target:match("^([^?#]*)%??([^#]*)")
    ---@type mdserver.Request
    local req = {
      method = method,
      path = M.decode(path),
      query = M.parse_query(query),
      headers = headers,
      client = client,
    }
    -- uv callbacks run in a fast event, most of the API needs the main loop
    vim.schedule(function()
      local ok, e = pcall(handler, req)
      if not ok then
        vim.notify("mdserver: " .. tostring(e), vim.log.levels.ERROR)
        M.respond(client, 500)
      end
    end)
  end)
end

--- Listen on host:port, port 0 picks a free one.
---@param host string
---@param port integer
---@param handler fun(req: mdserver.Request)
---@return uv.uv_tcp_t? server
---@return string? error
function M.listen(host, port, handler)
  local server = assert(uv.new_tcp())
  local ok, err = server:bind(host, port)
  if ok then
    ok, err = server:listen(64, function(listen_err)
      if listen_err then
        return
      end
      local client = uv.new_tcp()
      if client and server:accept(client) then
        on_connection(client, handler)
      elseif client then
        M.close(client)
      end
    end)
  end
  if not ok then
    M.close(server)
    return nil, err
  end
  return server
end

return M
