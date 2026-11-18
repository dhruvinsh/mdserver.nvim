-- Bump the libraries pinned in vendor.json: resolves the version, downloads each
-- file and records its sha256. Run `nvim -l build.lua` afterwards to install.
--
--   nvim -l scripts/update-vendor.lua                     # every package to its latest version
--   nvim -l scripts/update-vendor.lua mermaid@12.2.0      # pin one package
--   nvim -l scripts/update-vendor.lua marked              # one package to its latest version
--
-- With $MDSERVER_UPDATE_SUMMARY set, a markdown list of the version changes is
-- written to that file (used as the pull request body by CI).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local vendor = dofile(root .. "/lua/mdserver/vendor.lua")
local manifest = vendor.manifest()

---@param url string
---@return string body
local function get(url)
  local done, err, body
  vim.net.request(url, {}, function(e, res)
    err, body, done = e, res and res.body, true
  end)
  vim.wait(60000, function()
    return done
  end, 50)
  if not done or err then
    error(("%s: %s"):format(url, err and vim.trim(err) or "timed out"), 0)
  end
  return body
end

---@param package string
---@return string
local function latest(package)
  local data = get("https://data.jsdelivr.com/v1/packages/npm/" .. package .. "/resolved")
  return assert(vim.json.decode(data).version, "cannot resolve " .. package)
end

-- package -> requested version (nil: latest)
local wanted = {} ---@type table<string, string|false>
for _, a in ipairs(type(arg) == "table" and arg or {}) do
  local package, version = a:match("^(@?[^@]+)@(.+)$")
  wanted[package or a] = version or false
end
local all = next(wanted) == nil

local versions = {} ---@type table<string, string>
local changes = {} ---@type string[]
local seen = {} ---@type table<string, true>
for _, file in ipairs(manifest.files) do
  if all or wanted[file.package] ~= nil then
    versions[file.package] = versions[file.package] or wanted[file.package] or latest(file.package)
    local version = versions[file.package]
    local tmp = vim.fn.tempname()
    local url = ("%s/%s@%s/%s"):format(manifest.cdn, file.package, version, file.path)
    local err = vendor.download({ { url = url, outpath = tmp } })[1]
    if err then
      error(("%s: %s"):format(url, err), 0)
    end
    local hash = assert(vendor.hash(tmp))
    os.remove(tmp)
    if version ~= file.version or hash ~= file.sha256 then
      print(("%-26s %s -> %s"):format(file.name, file.version, version))
      if not seen[file.package] then
        seen[file.package] = true
        table.insert(
          changes,
          ("- [`%s`](https://www.npmjs.com/package/%s?activeTab=versions): %s → %s"):format(
            file.package,
            file.package,
            file.version,
            version
          )
        )
      end
    else
      print(("%-26s %s (unchanged)"):format(file.name, version))
    end
    file.version, file.sha256 = version, hash
  end
end

-- Sorted keys and a fixed indent: updates only change the lines that changed.
local f = assert(io.open(root .. "/vendor.json", "w"))
f:write(vim.json.encode(manifest, { indent = "  ", sort_keys = true }), "\n")
f:close()
local summary = vim.env.MDSERVER_UPDATE_SUMMARY
if summary and summary ~= "" then
  vim.fn.writefile(changes, summary)
end
print(#changes > 0 and "vendor.json updated, run `nvim -l build.lua` to install" or "everything is up to date")
