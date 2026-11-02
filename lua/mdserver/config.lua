local M = {}

---@class mdserver.Config
---@field host string address to bind, "0.0.0.0" makes it reachable from other machines
---@field port? integer nil: a stable port derived from the project root (8100-9099)
---@field open_browser boolean open the browser when the server starts or on `:MdServer open`
---@field browser? string[] command to open the URL with (the URL is appended), default vim.ui.open
---@field follow boolean the browser follows the markdown buffer you are editing
---@field root_markers (string|string[])[] files/directories marking the project root, see vim.fs.root()
---@field extensions string[] file extensions shown in the tree
---@field skip_dirs string[] directories skipped outside of git repositories
---@field debounce integer ms between a buffer change and the browser refresh
M.defaults = {
  host = "127.0.0.1",
  port = nil,
  open_browser = true,
  browser = nil,
  follow = true,
  root_markers = { ".git", ".hg", ".jj" },
  extensions = { "md", "markdown", "mdx" },
  skip_dirs = { "node_modules", "vendor", "target", "build", "dist", "__pycache__" },
  debounce = 200,
}

---@type mdserver.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? mdserver.Config|{}
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
