-- Installs the browser libraries listed in vendor.json into vendor/.
--
-- lazy.nvim runs this file on install and update (`:Lazy build mdserver` runs it
-- again). Other plugin managers: `:MdServer install`, or from a shell:
--
--   nvim -l build.lua [--force]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local vendor = dofile(root .. "/lua/mdserver/vendor.lua")
local args = type(arg) == "table" and arg or {}
vendor.install({ force = vim.tbl_contains(args, "--force") })
