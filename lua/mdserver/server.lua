-- HTTP routes. Everything outside of PREFIX is a path inside the project:
--
--   /<path>                       markdown/HTML/PDF file or directory -> app page, other files -> raw bytes
--   /_mdserver/raw/<path>         file content (documents from the loaded buffer when there is one);
--                                 the app frames HTML pages and PDFs from here, so relative URLs stay raw
--   /_mdserver/tree               JSON: project name, documents, vendor URLs
--   /_mdserver/events             server-sent events: follow / change / tree
--   /_mdserver/edit?path=<path>   (POST) open the file in Neovim
--   /_mdserver/app/<name>         the page's own files (app/)
--   /_mdserver/vendor/<name>      libraries installed from vendor.json
local Config = require("mdserver.config")
local Http = require("mdserver.http")
local Project = require("mdserver.project")
local Vendor = require("mdserver.vendor")

local uv = vim.uv

local M = {}

M.PREFIX = "/_mdserver/"

local app_dir = Vendor.root .. "/app"

--- Largest answer to an open ended range (`bytes=N-`), players ask for the rest.
local RANGE_CHUNK = 4 * 1024 * 1024

--- ms without changes before a rebuilt PDF reloads: LaTeX and friends write it in pieces.
local PDF_SETTLE = 500

local mime_types = {
  -- pages
  css = "text/css; charset=utf-8",
  htm = "text/html; charset=utf-8",
  html = "text/html; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  mjs = "text/javascript; charset=utf-8",
  pdf = "application/pdf",
  wasm = "application/wasm",
  xml = "application/xml; charset=utf-8",
  -- fonts
  otf = "font/otf",
  ttf = "font/ttf",
  woff = "font/woff",
  woff2 = "font/woff2",
  -- images
  apng = "image/apng",
  avif = "image/avif",
  bmp = "image/bmp",
  gif = "image/gif",
  ico = "image/x-icon",
  jpeg = "image/jpeg",
  jpg = "image/jpeg",
  png = "image/png",
  svg = "image/svg+xml",
  webp = "image/webp",
  -- video
  m4v = "video/mp4",
  mov = "video/quicktime",
  mp4 = "video/mp4",
  ogv = "video/ogg",
  webm = "video/webm",
  -- audio
  flac = "audio/flac",
  m4a = "audio/mp4",
  mp3 = "audio/mpeg",
  oga = "audio/ogg",
  ogg = "audio/ogg",
  opus = "audio/ogg",
  wav = "audio/wav",
}

---@param path string
---@return string
local function mime_type(path)
  if Project.is_markdown(path) then
    return "text/markdown; charset=utf-8"
  elseif Project.is_html(path) then
    return mime_types.html
  end
  return mime_types[vim.fs.ext(path):lower()] or "text/plain; charset=utf-8"
end

--- Versioned URL of a vendor file: the version changes the URL, so the browser may cache it.
---@param name string
---@return string
local function vendor_url(name)
  local file = assert(Vendor.get(name), name)
  return ("%svendor/%s?v=%s"):format(M.PREFIX, name, file.version)
end

---@return string
local function page()
  local html = assert(Project.read_file(app_dir .. "/index.html"), "app/index.html is missing")
  return (html:gsub("{{vendor:([%w%-%._]+)}}", vendor_url))
end

--- Serve a project file. Honours `Range: bytes=a-b`, which video and audio
--- players need to seek (and Safari to play at all).
---@param req mdserver.Request
---@param path string
---@param size integer
local function serve_file(req, path, size)
  local opts = { type = mime_type(path), headers = { ["Accept-Ranges"] = "bytes" } }
  local first, last = (req.headers.range or ""):match("^bytes=(%d*)%-(%d*)$")
  if not first or (first == "" and last == "") then
    return Http.respond(req.client, 200, Project.read_file(path), opts)
  end
  local from, to
  if first == "" then -- suffix: the last N bytes
    from, to = math.max(size - tonumber(last), 0), size - 1
  else
    from = tonumber(first)
    to = math.min(last == "" and from + RANGE_CHUNK - 1 or tonumber(last), size - 1)
  end
  if from > to or from >= size then
    opts.headers["Content-Range"] = "bytes */" .. size
    return Http.respond(req.client, 416, nil, opts)
  end
  local f = io.open(path, "rb")
  if not f then
    return Http.respond(req.client, 404)
  end
  f:seek("set", from)
  local data = f:read(to - from + 1) or ""
  f:close()
  opts.headers["Content-Range"] = ("bytes %d-%d/%d"):format(from, from + #data - 1, size)
  Http.respond(req.client, 206, data, opts)
end

---@class mdserver.Session
---@field root string
---@field streams uv.uv_tcp_t[] open event streams
---@field watchers? table<string, mdserver.Watcher> directories of the PDFs shown in a browser

---@class mdserver.Watcher
---@field handle uv.uv_fs_event_t
---@field timer uv.uv_timer_t
---@field names table<string, string> file name -> root-relative path of the PDFs watched
---@field changed table<string, true> file names changed since the last broadcast

--- Reload the PDF in the browser when another program (LaTeX, typst, the browser's own
--- "save") writes it. Watches its directory: builds often replace the file rather than
--- write to it, which a watch on the file itself would not see.
---@param session mdserver.Session
---@param full string absolute path, inside the root
local function watch_pdf(session, full)
  local dir, name = vim.fs.dirname(full), vim.fs.basename(full)
  session.watchers = session.watchers or {}
  local w = session.watchers[dir]
  if not w then
    local handle, timer = uv.new_fs_event(), uv.new_timer()
    if not (handle and timer) then
      return
    end
    local watcher = { handle = handle, timer = timer, names = {}, changed = {} }
    local ok = handle:start(dir, {}, function(err, file)
      if err or not file or not watcher.names[file] then
        return
      end
      watcher.changed[file] = true
      timer:start(PDF_SETTLE, 0, function()
        vim.schedule(function()
          for f in pairs(watcher.changed) do
            M.broadcast(session, "change", { path = watcher.names[f] })
          end
          watcher.changed = {}
        end)
      end)
    end)
    if not ok then
      Http.close(handle)
      Http.close(timer)
      return
    end
    w = watcher
    session.watchers[dir] = w
  end
  w.names[name] = assert(vim.fs.relpath(session.root, full))
end

--- Stop the PDF watchers.
---@param session mdserver.Session
function M.unwatch(session)
  for _, w in pairs(session.watchers or {}) do
    w.timer:stop()
    Http.close(w.timer)
    Http.close(w.handle)
  end
  session.watchers = nil
end

---@param session mdserver.Session
---@param req mdserver.Request
local function api(session, req, route)
  local client = req.client
  if route == "events" then
    table.insert(session.streams, client)
    return Http.event_stream(client, function()
      for i, c in ipairs(session.streams) do
        if c == client then
          return table.remove(session.streams, i)
        end
      end
    end)
  elseif route == "tree" then
    return Project.list(session.root, function(files)
      Http.respond(
        client,
        200,
        vim.json.encode({
          root = session.root,
          name = vim.fs.basename(session.root),
          files = files,
          html_extensions = Config.options.html_extensions,
          pdf_extensions = Config.options.pdf_extensions,
          mermaid = vendor_url("mermaid.min.js"),
          missing = Vendor.missing(),
        }),
        { type = mime_types.json }
      )
    end)
  elseif route == "edit" then
    if req.method ~= "POST" then
      return Http.respond(client, 405)
    end
    local full = Project.resolve(session.root, req.query.path or "")
    if not full or not vim.uv.fs_stat(full) then
      return Http.respond(client, 404)
    end
    vim.cmd.edit(vim.fn.fnameescape(full))
    return Http.respond(client, 204)
  elseif vim.startswith(route, "raw/") then
    local full = Project.resolve(session.root, route:sub(5))
    if not full then
      return Http.respond(client, 403)
    end
    if Project.is_document(full) then
      local data = Project.read(full)
      return Http.respond(client, data and 200 or 404, data, { type = data and mime_type(full) or nil })
    end
    -- PDFs and the assets of framed HTML pages (styles, scripts, media): like project files
    local stat = vim.uv.fs_stat(full)
    if not stat or stat.type ~= "file" then
      return Http.respond(client, 404)
    end
    if Project.is_pdf(full) then
      watch_pdf(session, full)
    end
    return serve_file(req, full, stat.size)
  elseif vim.startswith(route, "app/") then
    local name = vim.fs.basename(route)
    local data = Project.read_file(app_dir .. "/" .. name)
    return Http.respond(client, data and 200 or 404, data, { type = mime_type(name) })
  elseif vim.startswith(route, "vendor/") then
    local file = Vendor.get(vim.fs.basename(route))
    local data = file and Project.read_file(Vendor.path(file))
    if not data then
      return Http.respond(client, 404, "not installed, run :MdServer install")
    end
    local cache = req.query.v == file.version and "max-age=31536000, immutable" or nil
    return Http.respond(client, 200, data, { type = mime_type(file.name), cache = cache })
  end
  Http.respond(client, 404)
end

---@param session mdserver.Session
---@return fun(req: mdserver.Request)
function M.handler(session)
  return function(req)
    if vim.startswith(req.path, M.PREFIX) then
      return api(session, req, req.path:sub(#M.PREFIX + 1))
    end
    -- Project path: files other than documents (images, ...) are served as they are, the
    -- app handles the rest (markdown, HTML and PDF files, directories, paths it resolves itself).
    local full = Project.resolve(session.root, req.path:sub(2))
    if not full then
      return Http.respond(req.client, 403)
    end
    local stat = vim.uv.fs_stat(full)
    if stat and stat.type == "file" and not Project.is_listed(full) then
      return serve_file(req, full, stat.size)
    end
    Http.respond(req.client, 200, page(), { type = mime_types.html })
  end
end

---@param session mdserver.Session
---@param event string
---@param data table
function M.broadcast(session, event, data)
  for i = #session.streams, 1, -1 do
    local client = session.streams[i]
    if client:is_closing() then
      table.remove(session.streams, i)
    else
      Http.send_event(client, event, data)
    end
  end
end

return M
