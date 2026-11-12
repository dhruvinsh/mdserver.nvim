-- End-to-end check of an installed plugin: serves a temporary project and
-- requests every route with curl. Needs vendor/ (run build.lua first).
--
--   nvim --clean -l scripts/smoke.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local failures = 0
---@param ok any
---@param msg string
local function check(ok, msg)
  print((ok and "ok    " or "FAIL  ") .. msg)
  if not ok then
    failures = failures + 1
  end
end

-- A small project: nested docs, an image, media and an HTML page with its style sheet.
local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/docs/guide", "p")
vim.fn.writefile({ "# Top", "", "[intro](docs/guide/intro.md#setup)" }, project .. "/README.md")
vim.fn.writefile(
  { "# Intro", "", "## Setup", "", "```mermaid", "graph LR", "  A --> B", "```" },
  project .. "/docs/guide/intro.md"
)
vim.fn.writefile({ "not an image" }, project .. "/docs/pic.png")
vim.fn.writefile({ "0123456789" }, project .. "/docs/clip.mp4") -- 11 bytes with the newline
vim.fn.mkdir(project .. "/site", "p")
vim.fn.writefile({ '<link rel="stylesheet" href="style.css"><h1>Site</h1>' }, project .. "/site/index.html")
vim.fn.writefile({ "h1 { color: red }" }, project .. "/site/style.css")

local mdserver = require("mdserver")
mdserver.setup({ open_browser = false, port = 0 })
vim.notify = function() end
mdserver.start(project)
local url = mdserver.url()
check(url ~= nil, "server started")
if not url then
  os.exit(1)
end

---@param path string
---@param method? string
---@param range? string Range header
---@return { code: integer, body: string, headers: string }
local function request(path, method, range)
  local headers = vim.fn.tempname()
  local cmd = { "curl", "-s", "--path-as-is", "-D", headers, "-X", method or "GET", url .. path }
  if range then
    vim.list_extend(cmd, { "-H", "Range: " .. range })
  end
  local res
  vim.system(cmd, { text = true }, function(r)
    res = r
  end)
  -- keep the event loop (and with it the server) running while curl waits
  vim.wait(10000, function()
    return res ~= nil
  end, 10)
  local head = table.concat(vim.fn.readfile(headers), "\n")
  os.remove(headers)
  return { code = tonumber(head:match("^HTTP/%S+ (%d+)")) or 0, body = res and res.stdout or "", headers = head }
end

local vendor = require("mdserver.vendor")

local tree = request("/_mdserver/tree")
local ok, data = pcall(vim.json.decode, tree.body)
check(tree.code == 200 and ok, "tree returns JSON")
check(
  ok and vim.deep_equal(data.files, { "README.md", "docs/guide/intro.md", "site/index.html" }),
  "tree lists the markdown and HTML files"
)
check(ok and vim.deep_equal(data.html_extensions, { "html", "htm" }), "tree has the HTML extensions")
check(ok and #data.missing == 0, "every vendor file is installed")

local page = request("/docs/guide/intro.md")
check(page.code == 200 and page.body:find("/_mdserver/app/app.js", 1, true), "markdown path serves the app")
for _, file in ipairs(vendor.manifest().files) do
  if file.name ~= "mermaid.min.js" then
    local link = ("/_mdserver/vendor/%s?v=%s"):format(file.name, file.version)
    check(page.body:find(link, 1, true), "page links " .. link)
  end
  local res = request(("/_mdserver/vendor/%s?v=%s"):format(file.name, file.version))
  check(res.code == 200 and vim.fn.sha256(res.body) == file.sha256, "serves " .. file.name .. " unchanged")
  check(res.headers:find("immutable", 1, true), file.name .. " is cacheable")
end
check(
  ok and data.mermaid == ("/_mdserver/vendor/mermaid.min.js?v=%s"):format(vendor.get("mermaid.min.js").version),
  "tree links mermaid"
)

check(request("/_mdserver/raw/docs/guide/intro.md").body:find("## Setup", 1, true), "raw markdown")

local html = request("/site/index.html")
check(html.code == 200 and html.body:find("/_mdserver/app/app.js", 1, true), "HTML path serves the app")
html = request("/_mdserver/raw/site/index.html")
check(
  html.code == 200 and html.headers:find("text/html", 1, true) and html.body:find("<h1>Site</h1>", 1, true),
  "raw HTML page"
)
local css = request("/_mdserver/raw/site/style.css")
check(css.code == 200 and css.headers:find("text/css", 1, true), "framed pages load their relative files")
check(request("/site/style.css").headers:find("text/css", 1, true), "page files at their own path")
local raw_part = request("/_mdserver/raw/docs/clip.mp4", nil, "bytes=2-4")
check(raw_part.code == 206 and raw_part.body == "234", "ranges on the raw route")
check(request("/_mdserver/raw/docs").code == 404, "raw directory")
check(request("/_mdserver/app/app.css").code == 200, "app files")
check(request("/docs/pic.png").headers:find("image/png", 1, true), "project files keep their type")
local video = request("/docs/clip.mp4")
check(
  video.headers:find("video/mp4", 1, true) and video.headers:find("Accept-Ranges: bytes", 1, true),
  "video type and ranges"
)
local part = request("/docs/clip.mp4", nil, "bytes=2-4")
check(part.code == 206 and part.body == "234" and part.headers:find("bytes 2-4/11", 1, true), "range")
part = request("/docs/clip.mp4", nil, "bytes=-3")
check(part.code == 206 and part.body == "89\n", "suffix range")
part = request("/docs/clip.mp4", nil, "bytes=8-")
check(part.code == 206 and part.body == "89\n", "open ended range")
check(request("/docs/clip.mp4", nil, "bytes=50-").code == 416, "range past the end")
check(request("/_mdserver/raw/../../../../etc/passwd").code == 403, "paths outside of the root are refused")
check(request("/_mdserver/vendor/../build.lua").code == 404, "only vendor files from the manifest")
check(request("/_mdserver/edit?path=README.md").code == 405, "edit needs POST")
check(request("/_mdserver/edit?path=README.md", "POST").code == 204, "edit opens the file")
check(vim.api.nvim_buf_get_name(0) == vim.uv.fs_realpath(project) .. "/README.md", "file is open in Neovim")

mdserver.stop({ silent = true })
check(not mdserver.is_running(), "server stopped")
vim.fn.delete(project, "rf")

if failures > 0 then
  error(("%d check(s) failed"):format(failures), 0)
end
print("all checks passed")
