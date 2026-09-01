local M = {}

local defaults = {
  no_project = "No DDEV project found: .ddev/config.yaml is missing.",
  menu_prompt = "DDEV action:",
  menu_description = "Open the DDEV action menu",
  command_description = "Run a DDEV command in a terminal",
  start = "Start",
  stop = "Stop",
  restart = "Restart",
  describe = "Describe",
  logs = "Follow logs",
  ssh = "SSH into the web container",
  xdebug = "Toggle Xdebug",
  launch = "Open in browser",
  mysql = "Open MySQL/MariaDB console",
  postgresql = "Open PostgreSQL console",
  composer = "Install Composer dependencies",
  list = "List all DDEV projects",
}

function M.setup(opts)
  opts = opts or {}
  local text = vim.tbl_extend("force", defaults, opts.translations or {})
  local Terminal = require("toggleterm.terminal").Terminal
  local uv = vim.uv or vim.loop

  local function ddev_root(bufnr, quiet)
    local path = vim.api.nvim_buf_get_name(bufnr or 0)

    if path == "" then
      path = uv.cwd()
    elseif vim.fn.isdirectory(path) == 0 then
      path = vim.fs.dirname(path)
    end

    local ddev_dir = vim.fs.find(".ddev", {
      path = path,
      upward = true,
      type = "directory",
    })[1]

    if not ddev_dir or not uv.fs_stat(ddev_dir .. "/config.yaml") then
      if not quiet then
        vim.notify(text.no_project, vim.log.levels.WARN)
      end
      return
    end

    return vim.fs.dirname(ddev_dir)
  end

  local function run(command, global)
    local root = global and uv.cwd() or ddev_root()

    if not root then
      return
    end

    Terminal:new({
      cmd = "ddev " .. command,
      dir = root,
      direction = "float",
      close_on_exit = false,
      float_opts = { border = "rounded" },
      on_open = function()
        vim.cmd("startinsert!")
      end,
    }):toggle()
  end

  local actions = {
    { label = "▶  " .. text.start, command = "start" },
    { label = "■  " .. text.stop, command = "stop" },
    { label = "↻  " .. text.restart, command = "restart" },
    { label = "ℹ  " .. text.describe, command = "describe" },
    { label = "▤  " .. text.logs, command = "logs -f" },
    { label = "⇥  " .. text.ssh, command = "ssh" },
    { label = "⚡  " .. text.xdebug, command = "xdebug toggle" },
    { label = "🌐  " .. text.launch, command = "launch" },
    { label = "🗄  " .. text.mysql, command = "mysql" },
    { label = "🐘  " .. text.postgresql, command = "psql" },
    { label = "📦  " .. text.composer, command = "composer install" },
    { label = "📋  " .. text.list, command = "list", global = true },
  }

  local function open_menu()
    vim.ui.select(actions, {
      prompt = text.menu_prompt,
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if item then
        run(item.command, item.global)
      end
    end)
  end

  vim.api.nvim_create_user_command("DdevMenu", open_menu, {
    desc = text.menu_description,
  })

  vim.api.nvim_create_user_command("Ddev", function(command)
    if command.args == "" then
      open_menu()
      return
    end

    local name = command.args:match("^%S+")
    run(command.args, name == "list" or name == "poweroff" or name == "version")
  end, {
    nargs = "*",
    desc = text.command_description,
    complete = function(arglead)
      local commands = {
        "start",
        "stop",
        "restart",
        "describe",
        "logs",
        "ssh",
        "exec",
        "launch",
        "list",
        "mysql",
        "psql",
        "composer",
        "npm",
        "xdebug",
        "poweroff",
      }

      return vim.tbl_filter(function(command)
        return vim.startswith(command, arglead)
      end, commands)
    end,
  })

  if opts.lsp then
    require("ddev.lsp").setup(opts.lsp, ddev_root)
  end
end

return M
