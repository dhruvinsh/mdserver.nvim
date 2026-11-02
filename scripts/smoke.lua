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

-- A small project: nested docs and an image.
local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/docs/guide", "p")
vim.fn.writefile({ "# Top", "", "[intro](docs/guide/intro.md#setup)" }, project .. "/README.md")
vim.fn.writefile(
  { "# Intro", "", "## Setup", "", "```mermaid", "graph LR", "  A --> B", "```" },
  project .. "/docs/guide/intro.md"
)
vim.fn.writefile({ "not an image" }, project .. "/docs/pic.png")

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
---@return { code: integer, body: string, headers: string }
local function request(path, method)
  local headers = vim.fn.tempname()
  local cmd = { "curl", "-s", "--path-as-is", "-D", headers, "-X", method or "GET", url .. path }
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
check(ok and vim.deep_equal(data.files, { "README.md", "docs/guide/intro.md" }), "tree lists the markdown files")
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
check(request("/_mdserver/app/app.css").code == 200, "app files")
check(request("/docs/pic.png").headers:find("image/png", 1, true), "project files keep their type")
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
