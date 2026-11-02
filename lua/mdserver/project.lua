-- The served project: root detection, path checks and the markdown file list.
local Config = require("mdserver.config")

local uv = vim.uv

local M = {}

---@param buf? integer
---@return string real path of the project root
function M.detect_root(buf)
  local root = vim.fs.root(buf or 0, Config.options.root_markers) or uv.cwd() or "."
  return uv.fs_realpath(root) or root
end

---@param path string
---@return boolean
function M.is_markdown(path)
  local ext = path:match("%.(%w+)$")
  return ext ~= nil and vim.tbl_contains(Config.options.extensions, ext:lower())
end

---@param root string
---@param path string
---@return boolean
local function inside(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Absolute path of a root-relative path, nil when it escapes the root
--- (`..`, or a symlink pointing outside of it).
---@param root string
---@param rel string
---@return string?
function M.resolve(root, rel)
  if rel:find("%z") then
    return nil
  end
  local full = vim.fs.normalize(root .. "/" .. rel)
  if not inside(root, full) then
    return nil
  end
  local real = uv.fs_realpath(full)
  if real and not inside(root, real) then
    return nil
  end
  return full
end

--- Root-relative path of an absolute path, nil when it is outside of the root.
---@param root string
---@param path string
---@return string?
function M.relative(root, path)
  if path == "" then
    return nil
  end
  local real = uv.fs_realpath(path) or vim.fs.normalize(path)
  if real:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return real:sub(#root + 2)
end

---@param path string
---@return string?
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- File content, taken from a loaded buffer when there is one so unsaved edits show.
---@param path string
---@return string?
function M.read(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
    end
  end
  return M.read_file(path)
end

---@param root string
---@return string[]
local function walk(root)
  local skip = {}
  for _, name in ipairs(Config.options.skip_dirs) do
    skip[name] = true
  end
  local files = {}
  for name, kind in
    vim.fs.dir(root, {
      depth = 20,
      skip = function(dir)
        local base = vim.fs.basename(dir)
        return not (base:sub(1, 1) == "." or skip[base])
      end,
    })
  do
    if kind == "file" and M.is_markdown(name) then
      table.insert(files, name)
    end
  end
  return files
end

--- Markdown files below the root, sorted. Inside git repositories the list
--- comes from git and honours .gitignore.
---@param root string
---@param callback fun(files: string[])
function M.list(root, callback)
  local cmd = { "git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--" }
  for _, ext in ipairs(Config.options.extensions) do
    table.insert(cmd, "*." .. ext)
  end

  local function done(files)
    table.sort(files)
    callback(files)
  end

  local ok = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return done(walk(root))
      end
      local files = {}
      for _, name in ipairs(vim.split(res.stdout, "\0", { trimempty = true })) do
        -- --cached also lists files deleted from the work tree, resolve() drops
        -- symlinks pointing outside of the root
        if uv.fs_stat(root .. "/" .. name) and M.resolve(root, name) then
          table.insert(files, name)
        end
      end
      done(files)
    end)
  end)
  if not ok then
    done(walk(root))
  end
end

return M
