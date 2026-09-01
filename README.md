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
