# mdserver.nvim

[![CI](https://github.com/dhruvinsh/mdserver.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/dhruvinsh/mdserver.nvim/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dhruvinsh/mdserver.nvim)](https://github.com/dhruvinsh/mdserver.nvim/releases)

Browse every markdown file of a project in the browser: the project's markdown
files as a tree on the left, the rendered document on the right.

- The HTTP server runs **inside Neovim** (`vim.uv`), no node or python process: it
  stops when Neovim exits, and the page shows that it went away.
- Links between documents work: relative (`../x.md`), with a heading (`x.md#setup`),
  root relative (`/docs/x.md`), directories (opens their README/index) and links
  without the extension. Back/forward work, broken links are struck through.
- GitHub flavoured markdown (tables, task lists, front matter), code highlighting
  (highlight.js), mermaid diagrams, light and dark theme.
- Live: shows unsaved edits as you type and follows the markdown buffer you are in.
  "Edit in Neovim" opens the current document in Neovim.
- Lazy by design: `plugin/` only creates the `:MdServer` command.

## Requirements

- Neovim 0.10+
- `curl` (installs the browser libraries)
- `git` (optional: the tree honours `.gitignore`)

## Installation

The plugin renders markdown in the browser with
[marked](https://github.com/markedjs/marked),
[highlight.js](https://highlightjs.org) and [mermaid](https://mermaid.js.org).
They are not part of the repository: `vendor.json` pins their versions and
sha256 checksums, and `build.lua` downloads them into `vendor/` (git ignored)
with `curl`. Run it after installing and after every update, which is what the
snippets below do. Downloads that don't match their checksum fail the build.

Calling `setup()` is optional, the plugin works with the defaults.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "dhruvinsh/mdserver.nvim",
  build = "build.lua", -- runs on install and update
  cmd = "MdServer",
  keys = {
    { "<leader>tm", "<cmd>MdServer toggle<cr>", desc = "Markdown project server" },
  },
  opts = {},
}
```

lazy.nvim would also find `build.lua` without the `build` key, it is spelled
out so the install step is visible. Run it again with `:Lazy build mdserver.nvim`.

### vim.pack (Neovim 0.12+)

```lua
-- before vim.pack.add(), so it also runs on the first install
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    local data = ev.data
    if data.spec.name == "mdserver.nvim" and (data.kind == "install" or data.kind == "update") then
      vim.system({ "nvim", "--clean", "-l", "build.lua" }, { cwd = data.path }):wait()
    end
  end,
})
vim.pack.add({ "https://github.com/dhruvinsh/mdserver.nvim" })
```

### [mini.deps](https://github.com/echasnovski/mini.deps)

```lua
local function build(ctx)
  vim.system({ "nvim", "--clean", "-l", "build.lua" }, { cwd = ctx.path }):wait()
end

MiniDeps.add({
  source = "dhruvinsh/mdserver.nvim",
  hooks = { post_install = build, post_checkout = build },
})
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'dhruvinsh/mdserver.nvim', { 'do': 'nvim --clean -l build.lua' }
```

### Other plugin managers

Run `nvim -l build.lua` in the plugin directory, or `:MdServer install` from
Neovim, after installing and after each update.

### Installing the libraries by hand

- `:MdServer install` downloads the missing or outdated libraries, and
  `:MdServer install!` downloads all of them again.
- From a shell, in the plugin directory: `nvim -l build.lua`, or
  `nvim -l build.lua --force` to download everything again.
- `$MDSERVER_CDN` replaces `https://cdn.jsdelivr.net/npm`, for example an
  internal npm mirror with the same layout. The checksums still apply.

### Checking the installation

`:checkhealth mdserver` checks `curl` and `git`, verifies the checksum of every
installed library and shows whether the server is running. With lazy loading,
the check is found only once the plugin is loaded: run `:MdServer` (or
`:Lazy load mdserver.nvim`) first.

If the page says the renderer is not installed, run one of the install commands
above and reload the page.

## Usage

| Command                   | Action                                                         |
| ------------------------- | -------------------------------------------------------------- |
| `:MdServer`               | start, or open the browser on the current buffer               |
| `:MdServer start [root]`  | serve `root` (default: project root of the current buffer)     |
| `:MdServer stop`          | stop the server                                                |
| `:MdServer toggle`        | start / stop                                                   |
| `:MdServer status`        | URL, root, connected tabs                                      |
| `:MdServer install[!]`    | install the browser libraries (`!` downloads again)            |

In the browser: `/` filter files, `t` toggle the tree, `e` edit in Neovim.

## Configuration

Defaults:

```lua
require("mdserver").setup({
  host = "127.0.0.1",      -- "0.0.0.0" to reach it from another machine
  port = nil,              -- nil: stable port derived from the project root (8100-9099)
  open_browser = true,     -- open the browser on start / :MdServer open
  browser = nil,           -- command to open the URL with, e.g. { "firefox", "--new-tab" }
  follow = true,           -- browser follows the markdown buffer you are in
  root_markers = { ".git", ".hg", ".jj" },
  extensions = { "md", "markdown", "mdx" },
  skip_dirs = { "node_modules", "vendor", "target", "build", "dist", "__pycache__" },
  debounce = 200,          -- ms between a buffer change and the browser refresh
})
```

## Development

Point lazy.nvim at a local checkout:

```lua
{
  dir = "~/Documents/mdserver.nvim",
  build = "build.lua",
  cmd = "MdServer",
  opts = {},
}
```

lazy.nvim doesn't build `dir` plugins on its own, run `make install` (or
`:Lazy build mdserver.nvim`) once.

```sh
make install          # nvim -l build.lua
make test             # smoke test: serves a temporary project, requests every route
make update-vendor    # bump vendor.json to the latest versions (PKGS="marked mermaid@12.2.0")
make lint
```

### Releases and dependencies

- **Releases** are cut by [release-please](https://github.com/googleapis/release-please)
  from [conventional commits](https://www.conventionalcommits.org) on `main`:
  `feat:` bumps the minor version, `fix:` the patch version, `feat!:` or a
  `BREAKING CHANGE:` footer the major version. It keeps a release PR open;
  merging it tags `vX.Y.Z`, updates `CHANGELOG.md` and `lua/mdserver/version.lua`
  and publishes the GitHub release. The first release is `v1.0.0`.
- **Browser libraries**: `.github/workflows/update-vendor.yml` runs every Monday
  (or by hand, optionally for some packages only), updates `vendor.json` with
  `scripts/update-vendor.lua`, installs and smoke tests the new files and opens a
  `fix(deps)` pull request, so an update ships as a patch release.
- **GitHub actions** are kept up to date by Dependabot.
