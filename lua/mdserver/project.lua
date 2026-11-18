-- The served project: root detection, path checks and the file list (markdown, HTML, PDF).
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
---@param exts string[]
---@return boolean
local function has_extension(path, exts)
  return vim.tbl_contains(exts, vim.fs.ext(path):lower())
end

---@param path string
---@return boolean
function M.is_markdown(path)
  return has_extension(path, Config.options.extensions)
end

---@param path string
---@return boolean
function M.is_html(path)
  return has_extension(path, Config.options.html_extensions)
end

---@param path string
---@return boolean
function M.is_pdf(path)
  return has_extension(path, Config.options.pdf_extensions)
end

--- Text documents the app displays and follows in Neovim: markdown and HTML pages.
---@param path string
---@return boolean
function M.is_document(path)
  return M.is_markdown(path) or M.is_html(path)
end

--- Files the tree shows and the app displays: documents and PDFs.
---@param path string
---@return boolean
function M.is_listed(path)
  return M.is_document(path) or M.is_pdf(path)
end

---@param root string
---@param path string
---@return boolean
local function inside(root, path)
  return vim.fs.relpath(root, path) ~= nil
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
  local rel = vim.fs.relpath(root, uv.fs_realpath(path) or path)
  return rel ~= "." and rel or nil
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
    if kind == "file" and M.is_listed(name) then
      table.insert(files, name)
    end
  end
  return files
end

--- Markdown, HTML and PDF files below the root, sorted. Inside git repositories the list
--- comes from git and honours .gitignore.
---@param root string
---@param callback fun(files: string[])
function M.list(root, callback)
  local cmd = { "git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--" }
  local o = Config.options
  for _, exts in ipairs({ o.extensions, o.html_extensions, o.pdf_extensions }) do
    for _, ext in ipairs(exts) do
      table.insert(cmd, "*." .. ext)
    end
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
