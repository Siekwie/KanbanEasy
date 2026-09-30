-- Tiny non-blocking HTTP/1.1 server on top of LuaSocket (bundled with LÖVE).
-- Polled from love.update; one request per connection (Connection: close).

local socket = require("socket")
local api = require("src.api")

local Server = {}
Server.__index = Server

local MAX_BODY = 4 * 1024 * 1024
local CLIENT_TIMEOUT = 10

local REASONS = {
  [200] = "OK",
  [201] = "Created",
  [204] = "No Content",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [413] = "Payload Too Large",
  [500] = "Internal Server Error",
}

function Server.new(store, opts)
  opts = opts or {}
  local self = setmetatable({}, Server)
  self.store = store
  self.host = opts.host or "127.0.0.1"
  self.port = opts.port or 7420
  self.clients = {}
  self.error = nil
  self.requests = 0
  return self
end

function Server:start()
  -- socket.bind sets SO_REUSEADDR so restarts don't trip over TIME_WAIT connections.
  local sock, err = socket.bind(self.host, self.port, 32)
  if not sock then
    self.error = (err == "address already in use") and ("port " .. self.port .. " in use") or err
    return false
  end
  sock:settimeout(0)
  self.sock = sock
  self.error = nil
  return true
end

function Server:stop()
  for _, c in ipairs(self.clients) do
    c.sock:close()
  end
  self.clients = {}
  if self.sock then
    self.sock:close()
    self.sock = nil
  end
end

function Server:running()
  return self.sock ~= nil
end

local function buildResponse(res, method)
  local body = res.body or ""
  local head = {
    string.format("HTTP/1.1 %d %s", res.status, REASONS[res.status] or "OK"),
    "Content-Type: " .. (res.contentType or "text/plain"),
    "Content-Length: " .. #body,
    "Connection: close",
    "Cache-Control: no-store",
    "",
    "",
  }
  if method == "HEAD" then
    body = ""
  end
  return table.concat(head, "\r\n") .. body
end

--- Try to parse a complete request out of the client's buffer.
local function parseRequest(buf)
  local headerEnd = buf:find("\r\n\r\n", 1, true)
  local sepLen = 4
  if not headerEnd then
    headerEnd = buf:find("\n\n", 1, true)
    sepLen = 2
  end
  if not headerEnd then
    return nil
  end
  local head = buf:sub(1, headerEnd - 1)
  local lines = {}
  for line in (head .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  local method, target = (lines[1] or ""):match("^(%u+)%s+(%S+)")
  if not method then
    return { bad = true }
  end
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.-)%s*$")
    if k then
      headers[k:lower()] = v
    end
  end
  local len = tonumber(headers["content-length"] or "0") or 0
  if len > MAX_BODY then
    return { tooLarge = true }
  end
  local bodyStart = headerEnd + sepLen
  if #buf - bodyStart + 1 < len then
    return nil
  end
  return {
    method = method,
    target = target,
    headers = headers,
    rawBody = buf:sub(bodyStart, bodyStart + len - 1),
  }
end
Server.parseRequest = parseRequest

--- Accept connections, read requests, dispatch, write responses. Returns true if anything happened.
function Server:update()
  if not self.sock then
    return false
  end
  local active = false
  -- Accept all pending connections
  while true do
    local client = self.sock:accept()
    if not client then
      break
    end
    client:settimeout(0)
    table.insert(self.clients, { sock = client, buf = "", out = nil, started = socket.gettime() })
    active = true
  end

  local now = socket.gettime()
  for i = #self.clients, 1, -1 do
    local c = self.clients[i]
    local done = false
    if not c.out then
      local data, err, partial = c.sock:receive(8192)
      local chunk = data or partial
      if chunk and #chunk > 0 then
        c.buf = c.buf .. chunk
        active = true
      end
      local req = parseRequest(c.buf)
      if req then
        local res
        if req.bad then
          res = { status = 400, body = "bad request\n" }
        elseif req.tooLarge then
          res = { status = 413, body = "payload too large\n" }
        else
          local ok, r = pcall(api.handle, self.store, req)
          res = ok and r or { status = 500, body = tostring(r) .. "\n" }
          self.requests = self.requests + 1
        end
        c.out = buildResponse(res, req.method)
        c.sent = 0
        active = true
      elseif err == "closed" then
        done = true
      end
    end
    if c.out then
      local last, err, partialLast = c.sock:send(c.out, c.sent + 1)
      local sentTo = last or partialLast or c.sent
      c.sent = sentTo
      if c.sent >= #c.out or (err and err ~= "timeout") then
        done = true
      end
    end
    if now - c.started > CLIENT_TIMEOUT then
      done = true
    end
    if done then
      c.sock:close()
      table.remove(self.clients, i)
    end
  end
  return active
end

return Server
