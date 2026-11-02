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

---@param cmd string[]
---@return string
local function run(cmd)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error(("%s failed: %s"):format(table.concat(cmd, " "), res.stderr), 0)
  end
  return res.stdout
end

---@param package string
---@return string
local function latest(package)
  local data = run({ "curl", "-sSfL", "https://data.jsdelivr.com/v1/packages/npm/" .. package .. "/resolved" })
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
    run({ "curl", "-sSfL", "-o", tmp, url })
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

-- Keep the hand-written layout of vendor.json.
local out = { "{", ('  "cdn": %s,'):format(vim.json.encode(manifest.cdn)), '  "files": [' }
for i, file in ipairs(manifest.files) do
  table.insert(out, "    {")
  local keys = { "name", "package", "version", "path", "sha256" }
  for k, key in ipairs(keys) do
    table.insert(out, ("      %q: %s%s"):format(key, vim.json.encode(file[key]), k < #keys and "," or ""))
  end
  table.insert(out, "    }" .. (i < #manifest.files and "," or ""))
end
vim.list_extend(out, { "  ]", "}", "" })
local f = assert(io.open(root .. "/vendor.json", "w"))
f:write(table.concat(out, "\n"))
f:close()
local summary = vim.env.MDSERVER_UPDATE_SUMMARY
if summary and summary ~= "" then
  vim.fn.writefile(changes, summary)
end
print(#changes > 0 and "vendor.json updated, run `nvim -l build.lua` to install" or "everything is up to date")
