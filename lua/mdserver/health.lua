local M = {}

function M.check()
  local health = vim.health
  local Vendor = require("mdserver.vendor")

  health.start("mdserver " .. require("mdserver.version") .. ": requirements")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  if vim.fn.executable("curl") == 1 then
    health.ok("`curl` found (installs the browser libraries)")
  else
    health.error("`curl` not found, the browser libraries cannot be installed")
  end
  if vim.fn.executable("git") == 1 then
    health.ok("`git` found (file tree honours .gitignore)")
  else
    health.warn("`git` not found, the file tree walks the file system instead")
  end

  health.start("mdserver: browser libraries (" .. Vendor.dir .. ")")
  local broken = false
  for _, file in ipairs(Vendor.manifest().files) do
    local label = ("%s %s (%s)"):format(file.package, file.version, file.name)
    local status = Vendor.verify(file)
    if status == "ok" then
      health.ok(label)
    else
      broken = true
      health.error(label .. ": " .. (status == "missing" and "not installed" or "checksum mismatch"))
    end
  end
  if broken then
    health.info("Install with `:Lazy build mdserver`, `:MdServer install!` or `nvim -l build.lua --force`")
  end
  if vim.env.MDSERVER_CDN then
    health.info("$MDSERVER_CDN: " .. vim.env.MDSERVER_CDN)
  end

  health.start("mdserver: server")
  local mdserver = require("mdserver")
  local config = require("mdserver.config").options
  if mdserver.is_running() then
    health.ok("running at " .. mdserver.url())
  else
    health.info("not running")
  end
  if config.host ~= "127.0.0.1" and config.host ~= "localhost" and config.host ~= "::1" then
    health.warn(("listening on %s: the project files are reachable from the network"):format(config.host))
  end
end

return M
