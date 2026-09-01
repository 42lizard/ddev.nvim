# ddev.nvim

Run common [DDEV](https://ddev.com/) commands from Neovim in a floating
[toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) terminal.

## Requirements

- Neovim 0.10 or newer
- DDEV
- toggleterm.nvim

## Installation

With lazy.nvim:

```lua
{
  "42lizard/ddev.nvim",
  dependencies = { "akinsho/toggleterm.nvim" },
  cmd = { "Ddev", "DdevMenu" },
  opts = {},
  keys = {
    { "<leader>d", "<cmd>DdevMenu<cr>", desc = "Open DDEV menu" },
  },
}
```

## Usage

- `:DdevMenu` opens the action menu.
- `:Ddev` without arguments opens the action menu.
- `:Ddev <command>` runs any DDEV command, for example `:Ddev logs -f`.

Project commands run in the nearest parent directory containing
`.ddev/config.yaml`. Global commands (`list`, `poweroff`, and `version`) run in
Neovim's current working directory.

## Translations

All displayed text is English by default. Override only the strings you need:

```lua
{
  "42lizard/ddev.nvim",
  dependencies = { "akinsho/toggleterm.nvim" },
  opts = {
    translations = {
      menu_prompt = "Choose a DDEV action:",
      no_project = "This is not a DDEV project.",
      start = "Boot",
      stop = "Shut down",
    },
  },
}
```

## DDEV Language Servers

The optional LSP bridge uses DDEV to manage the project, resolves its web
container, and runs one language server there through an interactive Docker
stdio connection. Paths are mapped between the host project and
`/var/www/html`. The project must contain the selected server executable.

```lua
{
  "42lizard/ddev.nvim",
  dependencies = { "akinsho/toggleterm.nvim" },
  ft = "php", -- Load the plugin before the PHP FileType event.
  opts = {
    lsp = {
      enabled = true,
      server = "phpactor",
    },
  },
}
```

Available presets are:

| Server | Command inside DDEV |
| --- | --- |
| `phpactor` | `vendor/bin/phpactor language-server` |
| `psalm` | `vendor/bin/psalm-language-server` |
| `intelephense` | `node_modules/.bin/intelephense --stdio` |

Use one of the following `opts.lsp` configurations.

### PHPactor

Installing PHPactor as a project dependency can conflict with the versions
locked by an existing application. Install the
[standalone PHAR](https://phpactor.readthedocs.io/en/master/usage/standalone.html)
in the DDEV web container instead. Current PHPactor releases require PHP 8.2
or newer.

To make PHPactor available in every DDEV project, install it once using global
DDEV home additions:

```sh
mkdir -p ~/.ddev/homeadditions/bin
curl -fL https://github.com/phpactor/phpactor/releases/latest/download/phpactor.phar \
  -o ~/.ddev/homeadditions/bin/phpactor
chmod 0755 ~/.ddev/homeadditions/bin/phpactor
```

Restart each running project once and verify the installation:

```sh
ddev restart
ddev exec phpactor status
```

Alternatively, install a pinned PHPactor version per project. Create
`.ddev/web-build/Dockerfile.phpactor`:

```dockerfile
ARG PHPACTOR_VERSION=2026.07.22.0

RUN curl -fsSL \
    "https://github.com/phpactor/phpactor/releases/download/${PHPACTOR_VERSION}/phpactor.phar" \
    -o /usr/local/bin/phpactor \
    && chmod 0755 /usr/local/bin/phpactor
```

Rebuild the web container and verify the project-local installation:

```sh
ddev restart
ddev exec phpactor status
```

Select the container-wide executable explicitly:

```lua
lsp = {
  enabled = true,
  server = "phpactor",
  auto_start = true,
  cmd = { "phpactor", "language-server" },
}
```

Specify the full path (inside the container) to phpactor of nvim cannot find it.



Phpactor does not load project-local configuration until the project is
[trusted](https://phpactor.readthedocs.io/en/master/usage/configuration.html#trusting-configuration).
Trust the DDEV project after reviewing its `.phpactor.json` or `.phpactor.yml`:

```sh
ddev exec --raw -- phpactor config:trust --trust --working-dir=/var/www/html
```

The trust setting may need to be repeated after rebuilding the container. For
development environments that only open trusted repositories, the check can
instead be disabled by adding `config` to the `lsp` table:

```lua
config = {
  init_options = {
    ["language_server.enable_trust_check"] = false,
  },
}
```

### Psalm

Install it with `ddev composer require --dev vimeo/psalm`:

```lua
lsp = {
  enabled = true,
  server = "psalm",
  auto_start = true,
}
```

### Intelephense

Install it with `ddev npm install --save-dev intelephense`:

```lua
lsp = {
  enabled = true,
  server = "intelephense",
  auto_start = true,
  container_root = "/var/www/html",
  config = {
    init_options = { storagePath = "/tmp/intelephense" },
  },
}
```

Only one preset runs per project. Use `cmd` to override its executable and
arguments. Native Neovim LSP options belong in `config`; `container_root`
defaults to `/var/www/html`.

By default, a stopped DDEV project produces a warning. Set `auto_start = true`
to run `ddev start -y` before attaching. Use `:DdevLspStart` to retry and
`:DdevLspRestart` after restarting the container.
