-- Only the :MdServer command is defined at startup, lua/mdserver/ is loaded on first use.
if vim.g.loaded_mdserver then
  return
end
vim.g.loaded_mdserver = true

---@type table<string, fun(arg?: string, bang: boolean)>
local actions = {
  start = function(root)
    require("mdserver").start(root)
  end,
  stop = function()
    require("mdserver").stop()
  end,
  toggle = function()
    require("mdserver").toggle()
  end,
  open = function()
    require("mdserver").open()
  end,
  status = function()
    require("mdserver").status()
  end,
  install = function(_, bang)
    require("mdserver").install({ force = bang })
  end,
}

vim.api.nvim_create_user_command("MdServer", function(opts)
  local action = opts.fargs[1] or "open"
  if not actions[action] then
    return vim.notify("MdServer: unknown action " .. action, vim.log.levels.ERROR)
  end
  actions[action](opts.fargs[2], opts.bang)
end, {
  nargs = "*",
  bang = true,
  complete = function(arg, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    if #words > (arg == "" and 1 or 2) then
      return words[2] == "start" and vim.fn.getcompletion(arg, "dir") or {}
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arg)
    end, vim.tbl_keys(actions))
  end,
  desc = "mdserver: start [root] | stop | toggle | open | status | install[!]",
})
