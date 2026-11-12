-- mdserver: browse the markdown and HTML files of a project in the browser, as a file
-- tree next to the rendered document. The HTTP server runs inside Neovim
-- (vim.uv), so it stops when Neovim exits.
local Config = require("mdserver.config")
local Http = require("mdserver.http")
local Project = require("mdserver.project")
local Server = require("mdserver.server")
local Vendor = require("mdserver.vendor")

local uv = vim.uv

local M = {}

M.version = require("mdserver.version")

---@class mdserver.State: mdserver.Session
---@field server uv.uv_tcp_t
---@field url string
---@field host string address the server is bound to
---@field timer uv.uv_timer_t debounces buffer change events
---@field pending table<string, true> paths changed since the last refresh
---@field current? string last path the browser was told to follow

---@type mdserver.State?
local state

local AUGROUP = "mdserver"

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "mdserver" })
end

--- Root-relative path of a file buffer inside the served project.
---@param buf integer
---@return string?
local function file_path(buf)
  if not state or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  return Project.relative(state.root, vim.api.nvim_buf_get_name(buf))
end

--- Root-relative path of a document (markdown, HTML) buffer inside the served project.
---@param buf integer
---@return string?
local function buffer_path(buf)
  local path = file_path(buf)
  return path and Project.is_document(path) and path or nil
end

local function flush_changes()
  if not state then
    return
  end
  for path in pairs(state.pending) do
    Server.broadcast(state, "change", { path = path })
  end
  state.pending = {}
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    desc = "mdserver: push buffer changes to the browser",
    callback = function(args)
      local path = buffer_path(args.buf)
      if path and state then
        state.pending[path] = true
        state.timer:stop()
        state.timer:start(Config.options.debounce, 0, vim.schedule_wrap(flush_changes))
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufDelete" }, {
    group = group,
    desc = "mdserver: refresh the file tree",
    callback = function(args)
      if state and buffer_path(args.buf) then
        Server.broadcast(state, "tree", {})
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "mdserver: reload HTML pages when one of their files (css, js, ...) is written",
    callback = function(args)
      local path = file_path(args.buf)
      if path and state and not Project.is_document(path) then
        Server.broadcast(state, "asset", { path = path })
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    desc = "mdserver: the browser follows the current document buffer",
    callback = function(args)
      local path = Config.options.follow and buffer_path(args.buf)
      if path and state and path ~= state.current then
        state.current = path
        Server.broadcast(state, "follow", { path = path })
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "mdserver: stop the server",
    callback = function()
      M.stop({ silent = true })
    end,
  })
end

--- Same project, same port: browser tabs and bookmarks keep working across restarts.
---@param root string
---@return integer
local function default_port(root)
  local hash = 0
  for i = 1, #root do
    hash = (hash * 31 + root:byte(i)) % 1000
  end
  return 8100 + hash
end

---@param url string
local function open_url(url)
  local cmd = Config.options.browser
  if cmd then
    vim.system(vim.list_extend(vim.deepcopy(cmd), { url }), { detach = true })
  else
    vim.ui.open(url)
  end
end

---@param opts? mdserver.Config|{}
function M.setup(opts)
  Config.setup(opts)
end

---@return boolean
function M.is_running()
  return state ~= nil
end

---@return string? url of the running server
function M.url()
  return state and state.url
end

---@return string? host address the running server is bound to
function M.host()
  return state and state.host
end

--- Point the browser at the current document buffer, or the project page.
---@param s mdserver.State
local function show(s)
  local url = s.url .. "/" .. Http.encode_path(buffer_path(0) or "")
  if Config.options.open_browser then
    open_url(url)
  end
  notify(url)
end

--- Open the browser on the current document buffer, starting the server if needed.
--- The server is (re)bound to the configured host, or to all interfaces with
--- `global`; the served root does not change.
---@param opts? { global?: boolean } bind to 0.0.0.0 instead of the configured host
function M.open(opts)
  local host = opts and opts.global and "0.0.0.0" or Config.options.host
  if state and state.host == host then
    return show(state)
  end
  M.start(state and state.root, { host = host })
end

--- Start serving `root` (default: the project of the current buffer) and open
--- the browser. A running server keeps its host unless `opts.host` is given.
---@param root? string
---@param opts? { host?: string } address to bind
function M.start(root, opts)
  root = root and (uv.fs_realpath(vim.fs.normalize(root)) or vim.fs.normalize(root)) or Project.detect_root(0)
  local host = opts and opts.host or state and state.host or Config.options.host
  if state and state.root == root and state.host == host then
    return show(state)
  end
  M.stop({ silent = true })

  local missing = Vendor.missing()
  if #missing > 0 then
    notify(
      ("browser libraries are not installed (%s).\nRun `:Lazy build mdserver` or `:MdServer install`."):format(
        table.concat(missing, ", ")
      ),
      vim.log.levels.WARN
    )
  end

  ---@type mdserver.Session
  local session = { root = root, streams = {} }
  local handler = Server.handler(session)
  local port = Config.options.port or default_port(root)
  local server, err = Http.listen(host, port, handler)
  if not server and not Config.options.port then
    -- the derived port is taken, let the OS pick one
    server, err = Http.listen(host, 0, handler)
  end
  if not server then
    return notify(("cannot listen on %s:%d: %s"):format(host, port, err), vim.log.levels.ERROR)
  end

  local display = host
  if display == "0.0.0.0" or display == "::" then
    display = uv.os_gethostname()
  elseif display:find(":") then
    display = "[" .. display .. "]"
  end
  local s = session --[[@as mdserver.State]]
  s.server = server
  s.host = host
  s.url = ("http://%s:%d"):format(display, server:getsockname().port)
  s.timer = assert(uv.new_timer())
  s.pending = {}
  state = s
  state.current = buffer_path(0)
  create_autocmds()
  if not Http.is_loopback(host) then
    notify(("listening on %s: %s is reachable from the network"):format(host, root), vim.log.levels.WARN)
  end
  show(s)
end

---@param opts? { silent?: boolean }
function M.stop(opts)
  if not state then
    return
  end
  local s = state
  state = nil
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  s.timer:stop()
  Http.close(s.timer)
  for _, client in ipairs(s.streams) do
    Http.close(client)
  end
  Http.close(s.server)
  if not (opts and opts.silent) then
    notify("stopped")
  end
end

function M.toggle()
  if state then
    M.stop()
  else
    M.start()
  end
end

function M.status()
  if state then
    notify(("%s serving %s (%d browser tab(s))"):format(state.url, state.root, #state.streams))
  else
    notify("not running")
  end
end

--- Install the browser libraries, like build.lua. Blocks until the downloads finish.
---@param opts? { force?: boolean }
function M.install(opts)
  local lines = {}
  local ok, err = pcall(Vendor.install, {
    force = opts and opts.force,
    log = function(msg)
      table.insert(lines, msg)
    end,
  })
  notify(table.concat(lines, "\n") .. (ok and "" or "\n" .. err), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end

return M
