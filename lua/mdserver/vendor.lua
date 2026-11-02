-- Browser libraries (marked, highlight.js, mermaid) pinned in vendor.json and
-- downloaded into vendor/ at install time, the way markdown-preview.nvim installs
-- its node app. Self contained: build.lua loads this file with dofile, before the
-- plugin is on the runtimepath.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.dir = M.root .. "/vendor"

---@class mdserver.VendorFile
---@field name string file name inside vendor/
---@field package string npm package
---@field version string
---@field path string path inside the package
---@field sha256 string

---@class mdserver.Manifest
---@field cdn string
---@field files mdserver.VendorFile[]

---@param path string
---@return string?
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

---@type mdserver.Manifest?
local manifest

---@return mdserver.Manifest
function M.manifest()
  if not manifest then
    local data = assert(read(M.root .. "/vendor.json"), "mdserver: vendor.json is missing")
    manifest = vim.json.decode(data)
  end
  return manifest
end

---@param name string
---@return mdserver.VendorFile?
function M.get(name)
  for _, file in ipairs(M.manifest().files) do
    if file.name == name then
      return file
    end
  end
end

---@param file mdserver.VendorFile
---@return string
function M.path(file)
  return M.dir .. "/" .. file.name
end

--- Download URL. $MDSERVER_CDN replaces the CDN, e.g. for an internal npm mirror
--- that serves the same layout as jsdelivr/unpkg.
---@param file mdserver.VendorFile
---@return string
function M.url(file)
  local cdn = vim.env.MDSERVER_CDN or M.manifest().cdn
  return ("%s/%s@%s/%s"):format(cdn:gsub("/+$", ""), file.package, file.version, file.path)
end

---@param path string
---@return string?
function M.hash(path)
  local data = read(path)
  return data and vim.fn.sha256(data)
end

--- Names of vendor files that are not installed. Only checks presence, see
--- `verify` for checksums.
---@return string[]
function M.missing()
  local missing = {}
  for _, file in ipairs(M.manifest().files) do
    if not vim.uv.fs_stat(M.path(file)) then
      table.insert(missing, file.name)
    end
  end
  return missing
end

---@param file mdserver.VendorFile
---@return "ok"|"missing"|"mismatch"
function M.verify(file)
  local hash = M.hash(M.path(file))
  if not hash then
    return "missing"
  end
  return hash == file.sha256 and "ok" or "mismatch"
end

---@class mdserver.InstallOpts
---@field force? boolean download even when the installed file matches
---@field log? fun(msg: string)

--- Download every file of the manifest that is missing or outdated, verify its
--- checksum and move it into vendor/. Raises an error when anything failed.
---@param opts? mdserver.InstallOpts
function M.install(opts)
  opts = opts or {}
  local log = opts.log or print
  if vim.fn.executable("curl") == 0 then
    error("mdserver: `curl` is required to install the browser libraries", 0)
  end
  vim.fn.mkdir(M.dir, "p")

  local jobs = {}
  for _, file in ipairs(M.manifest().files) do
    local dest = M.path(file)
    if not opts.force and M.hash(dest) == file.sha256 then
      log(("up to date  %s %s"):format(file.package, file.version))
    else
      local url = M.url(file)
      log("download    " .. url)
      table.insert(jobs, {
        file = file,
        dest = dest,
        part = dest .. ".part",
        proc = vim.system({ "curl", "-sSfL", "--retry", "2", "--connect-timeout", "20", "-o", dest .. ".part", url }),
      })
    end
  end

  local errors = {}
  for _, job in ipairs(jobs) do
    local res = job.proc:wait()
    local hash = res.code == 0 and M.hash(job.part)
    if res.code ~= 0 then
      table.insert(errors, ("%s: %s"):format(job.file.name, vim.trim(res.stderr or "curl failed")))
    elseif hash ~= job.file.sha256 then
      table.insert(
        errors,
        ("%s: checksum mismatch\n  expected %s\n  got      %s"):format(job.file.name, job.file.sha256, hash)
      )
    else
      local ok, err = os.rename(job.part, job.dest)
      if not ok then
        table.insert(errors, ("%s: %s"):format(job.file.name, err))
      end
    end
    os.remove(job.part)
  end

  if #errors > 0 then
    error("mdserver: installing browser libraries failed\n" .. table.concat(errors, "\n"), 0)
  end
  log(("mdserver: browser libraries installed in %s"):format(M.dir))
end

return M
