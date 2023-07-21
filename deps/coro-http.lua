--[[lit-meta
  name = "creationix/coro-http"
  version = "3.2.3"
  dependencies = {
    "creationix/coro-net@3.3.0",
    "luvit/http-codec@3.0.0"
  }
  homepage = "https://github.com/luvit/lit/blob/master/deps/coro-http.lua"
  description = "An coro style http(s) client and server helper."
  tags = {"coro", "http"}
  license = "MIT"
  author = { name = "Tim Caswell" }
]]

local httpCodec = require('http-codec')
local net = require('coro-net')

local connections = {}

local REDIRECTION_CODES = {
  [301] = true,
  [302] = true,
  [307] = true,
}
local REDIRECTION_METHODS = {
  HEAD = true,
  GET = true,
}

local function createServer(host, port, onConnect)
  return net.createServer({
    host = host,
    port = port,
    encoder = httpCodec.encoder,
    decoder = httpCodec.decoder,
  }, function (read, write, socket)
    for head in read do
      local parts = {}
      for part in read do
        if #part > 0 then
          parts[#parts + 1] = part
        else
          break
        end
      end
      local body = table.concat(parts)
      head, body = onConnect(head, body, socket)
      write(head)
      if body then write(body) end
      write("")
      if not head.keepAlive then break end
    end
    write()
  end)
end

local function parseUrl(url)
  local protocol, host, hostname, port, path, hash = url:match("^(https?:)//(([^/:#]+):?([0-9]*))(/?[^#]*)(#?.*)$")
  if not protocol then error("Not a valid http url: " .. url) end
  local tls = protocol == "https:"
  port = port and tonumber(port) or (tls and 443 or 80)
  if path == "" then path = "/" end
  if hash == "" then hash = nil end
  return {
    tls = tls,
    host = host,
    hostname = hostname,
    port = port,
    path = path,
    hash = hash,
  }
end

local function getConnection(host, port, tls, timeout)
  for i = #connections, 1, -1 do
    local connection = connections[i]
    if connection.host == host and connection.port == port and connection.tls == tls then
      table.remove(connections, i)
      -- Make sure the connection is still alive before reusing it.
      if not connection.socket:is_closing() then
        connection.reused = true
        connection.socket:ref()
        return connection
      end
    end
  end
  local read, write, socket, updateDecoder, updateEncoder = assert(net.connect {
    host = host,
    port = port,
    tls = tls,
    timeout = timeout,
    encoder = httpCodec.encoder,
    decoder = httpCodec.decoder
  })
  return {
    socket = socket,
    host = host,
    port = port,
    tls = tls,
    read = read,
    write = write,
    updateEncoder = updateEncoder,
    updateDecoder = updateDecoder,
    reset = function ()
      -- This is called after parsing the response head from a HEAD request.
      -- If you forget, the codec might hang waiting for a body that doesn't exist.
      updateDecoder(httpCodec.decoder())
    end
  }
end

local function saveConnection(connection)
  if connection.socket:is_closing() then return end
  connections[#connections + 1] = connection
  connection.socket:unref()
end

---@param options number | {timeout: number, followRedirects: boolean, redirectionCodes: {[integer]: boolean}, redirectionMethods: {[string]: boolean}}
local function normalizeRequest(options)
  local optionsType = type(options)
  if optionsType == "number" then
    options.timeout = options
  elseif optionsType == "table" then
    options = options
  else
    options = {}
  end

  if options.followRedirects == nil or options.followRedirects then
    options.followRedirects = true
  else
    options.followRedirects = false
  end

  if type(options.redirectionCodes) == "table" then
    options.redirectionCodes = options.redirectionCodes
  else
    options.redirectionCodes = REDIRECTION_CODES
  end

  if type(options.redirectionMethods) == "table" then
    options.redirectionMethods = options.redirectionMethods
  else
    options.redirectionMethods = REDIRECTION_METHODS
  end

  return options
end

local function resolveRelativePath(basePath, relativePath)
  -- TODO
end

local function resolveLocation(baseUri, relativeUrl)
  local uri = parseUrl(relativeUrl)
  uri.hostname = uri.hostname or baseUri.hostname
  uri.host = uri.host or baseUri.host
  uri.hash = uri.hash or baseUri.hash
  uri.path = resolveRelativePath(baseUri.path, uri.path)
  if uri.tls ~= baseUri.tls then
    uri.tls = uri.tls
  end
  -- TODO: figure out uri.port
  uri.hash = uri.hash or baseUri.hash
  return string.format("http%s://%s:%d%s%s", uri.tls and "s" or "", uri.host, uri.port, uri.path, uri.hash or "")
end

local function request(method, url, headers, body, options)
  -- resolve the options
  options = normalizeRequest(options)

  -- parse the url and establish a connection (or retrive the cached one)
  local uri = parseUrl(url)
  local connection = getConnection(uri.hostname, uri.port, uri.tls, options.timeout)
  local read, write = connection.read, connection.write

  -- construct the request structure
  local req = {
    method = method,
    path = uri.path,
  }
  -- gather info about the provided headers
  local contentLength, chunked
  local hasHost = false
  if headers then
    for i = 1, #headers do
      local key = headers[i][1]:lower()
      if key == "content-length" then
        contentLength = headers[i][2]
      elseif key == "content-encoding" and headers[i][2]:lower() == "chunked" then
        chunked = true
      elseif key == "host" then
        hasHost = true
      end
      req[#req + 1] = headers[i]
    end
  end

  -- if no Host header, default to uri.host
  if not hasHost then
    req[#req + 1] = {"Host", uri.host}
  end
  -- if body is provided but not a Content-Length header, automatically supply one
  if type(body) == "string" and not (chunked and contentLength) then
    req[#req + 1] = {"Content-Length", #body}
  end

  -- send the request
  write(req)
  if body then write(body) end
  -- receive the response
  local res = read()
  if not res then
    if not connection.socket:is_closing() then
      connection.socket:close()
    end
    -- If we get an immediate close on a reused socket, try again with a new socket.
    -- TODO: think about if this could resend requests with side effects and cause
    -- them to double execute in the remote server.
    if connection.reused then
      return request(method, url, headers, body)
    end
    error("Connection closed")
  end

  -- receive and construct the response body payload
  body = {}
  if req.method == "HEAD" then
    -- if the method is HEAD, there is no body to receive
    connection.reset()
  else
    -- receive the body chunks until reaching end of stream 
    while true do
      local item = read()
      if not item then
        res.keepAlive = false
        break
      end
      if #item == 0 then
        break
      end
      body[#body + 1] = item
    end
  end
  body = table.concat(body)

  -- cache the connection if keepAlive is presented
  -- otherwise send end of stream and (eventually) close it
  if res.keepAlive then
    saveConnection(connection)
  else
    write()
  end

  -- automatically follow some redirects
  if options.redirectionMethods[method] and options.followRedirects and options.redirectionCodes[res.code] then
    for i = 1, #res do
      local key = res[i][1]:lower()
      if key == "location" then
        local location = resolveLocation(uri, res[i][2])
        return request(method, location, headers)
      end
    end
  end

  return res, body
end

return {
  createServer = createServer,
  parseUrl = parseUrl,
  getConnection = getConnection,
  saveConnection = saveConnection,
  request = request,
}
