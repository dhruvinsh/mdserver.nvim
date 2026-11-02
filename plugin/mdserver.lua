-- Only the :MdServer command is defined at startup, lua/mdserver/ is loaded on first use.
if vim.g.loaded_mdserver then
  return
end
vim.g.loaded_mdserver = true

---@type table<string, fun(args: string[], bang: boolean)>
local actions = {
  start = function(args)
    require("mdserver").start(args[1])
  end,
  stop = function()
    require("mdserver").stop()
  end,
  toggle = function()
    require("mdserver").toggle()
  end,
  open = function(_, bang)
    require("mdserver").open({ global = bang })
  end,
  status = function()
    require("mdserver").status()
  end,
  install = function(_, bang)
    require("mdserver").install({ force = bang })
  end,
}

-- The bang is accepted on the command (`:MdServer! open`) and on the action
-- (`:MdServer open!`): Neovim only parses the former, the latter reads better.
vim.api.nvim_create_user_command("MdServer", function(opts)
  local action = opts.fargs[1] or "open"
  local bang = opts.bang
  if action:sub(-1) == "!" then
    action, bang = action:sub(1, -2), true
  end
  if not actions[action] then
    return vim.notify("MdServer: unknown action " .. action, vim.log.levels.ERROR)
  end
  actions[action](vim.list_slice(opts.fargs, 2), bang)
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
  desc = "mdserver: start [root] | stop | toggle | open[!] | status | install[!]",
})
