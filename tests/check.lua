local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local notifications = {}
vim.notify = function(message)
  table.insert(notifications, message)
end

local opened
package.preload["toggleterm.terminal"] = function()
  return {
    Terminal = {
      new = function(_, options)
        return {
          toggle = function()
            opened = options
          end,
        }
      end,
    },
  }
end

local system_commands = {}
local system_results = {}
vim.system = function(command, options, callback)
  table.insert(system_commands, { command = command, options = options })
  local result = table.remove(system_results, 1)
  if not result and command[1] == "docker" and command[2] == "ps" then
    result = { code = 0, stdout = "ddev-test-web\n", stderr = "" }
  elseif not result and command[1] == "docker" and command[2] == "exec" then
    result = { code = 0, stdout = "testuser\n", stderr = "" }
  end
  callback(result or { code = 0, stdout = "", stderr = "" })
  return {}
end

local lsp_configs = {}
local lsp_public
local lsp_incoming
local rpc_spawn
local rpc_outgoing
local clients = {}
local original_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return clients
end
vim.lsp.buf_attach_client = function()
  return true
end
vim.lsp.rpc.start = function(command, dispatchers, options)
  rpc_spawn = { command = command, options = options }
  lsp_incoming = dispatchers
  return {
    request = function(method, params, callback)
      rpc_outgoing = { method = method, params = params }
      callback(nil, { uri = "file:///var/www/html/src/Result.php" }, 42)
      return true, 42
    end,
    notify = function(method, params)
      rpc_outgoing = { method = method, params = params }
      return true
    end,
    is_closing = function()
      return false
    end,
    terminate = function() end,
  }
end
vim.lsp.start = function(config, options)
  table.insert(lsp_configs, { config = config, options = options })
  lsp_public = config.cmd({
    notification = function(method, params)
      rpc_outgoing = { method = method, params = params }
    end,
    server_request = function(_, params)
      return { uri = params.uri }, { data = { uri = params.uri } }
    end,
    on_error = function() end,
    on_exit = function() end,
  })
  return #lsp_configs
end

local prompt
vim.ui.select = function(_, options)
  prompt = options.prompt
end

require("ddev").setup({
  translations = { menu_prompt = "Choose:" },
  lsp = { enabled = true, server = "phpactor" },
})
vim.cmd("DdevMenu")
assert(prompt == "Choose:")

vim.cmd("Ddev version")
assert(opened.cmd == "ddev version")
assert(opened.direction == "float")

local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/.ddev", "p")
project = assert(vim.uv.fs_realpath(project))
vim.fn.writefile({}, project .. "/.ddev/config.yaml")
vim.fn.mkdir(project .. "/vendor/bin", "p")
vim.fn.writefile({}, project .. "/vendor/bin/phpactor")
vim.api.nvim_buf_set_name(0, project .. "/index.php")
vim.cmd("Ddev start")
assert(opened.cmd == "ddev start")
assert(vim.uv.fs_realpath(opened.dir) == vim.uv.fs_realpath(project))
vim.bo.filetype = "php"
vim.wait(1000, function()
  return #lsp_configs == 1
end)

assert(vim.deep_equal(system_commands[1].command, { "ddev", "exec", "--raw", "--", "true" }))
assert(system_commands[1].options.cwd == project)
assert(vim.deep_equal(system_commands[2].command, {
  "docker",
  "ps",
  "--filter",
  "label=com.ddev.approot=" .. project,
  "--filter",
  "label=com.docker.compose.service=web",
  "--format",
  "{{.Names}}",
}))
assert(vim.deep_equal(system_commands[3].command, {
  "docker",
  "exec",
  "ddev-test-web",
  "printenv",
  "DDEV_USER",
}))
assert(lsp_configs[1].config.name == "ddev-phpactor")
assert(lsp_configs[1].config.root_dir == project)
assert(vim.deep_equal(rpc_spawn.command, {
  "docker",
  "exec",
  "-i",
  "--user",
  "testuser",
  "--workdir",
  "/var/www/html",
  "ddev-test-web",
  "vendor/bin/phpactor",
  "language-server",
}))
assert(rpc_spawn.options.cwd == project)

local host_uri = vim.uri_from_fname(project .. "/src/Test.php")
local container_uri = "file:///var/www/html/src/Test.php"
lsp_public.notify("textDocument/didOpen", { textDocument = { uri = host_uri } })
assert(rpc_outgoing.params.textDocument.uri == container_uri)
lsp_public.notify("workspace/didChangeWatchedFiles", { changes = { [host_uri] = project .. "/src/Test.php" } })
assert(rpc_outgoing.params.changes[container_uri] == "/var/www/html/src/Test.php")

local response
lsp_public.request("initialize", { processId = 123, rootUri = host_uri }, function(err, result, request_id)
  response = { err = err, result = result, request_id = request_id }
end)
assert(rpc_outgoing.params.processId == vim.NIL)
assert(rpc_outgoing.params.rootUri == container_uri)
assert(response.result.uri == vim.uri_from_fname(project .. "/src/Result.php"))
assert(response.request_id == 42)

lsp_incoming.notification("textDocument/publishDiagnostics", { uri = container_uri })
assert(rpc_outgoing.params.uri == host_uri)
local server_result, server_error = lsp_incoming.server_request("workspace/applyEdit", { uri = container_uri })
assert(server_result.uri == container_uri)
assert(server_error.data.uri == container_uri)

local lsp = require("ddev.lsp")
local expected_commands = {
  psalm = { "vendor/bin/psalm-language-server" },
  intelephense = { "node_modules/.bin/intelephense", "--stdio" },
}
for server, command in pairs(expected_commands) do
  vim.fn.mkdir(vim.fs.dirname(project .. "/" .. command[1]), "p")
  vim.fn.writefile({}, project .. "/" .. command[1])
  local before = #lsp_configs
  lsp.setup({ enabled = true, server = server }, function()
    return project
  end)
  vim.wait(1000, function()
    return #lsp_configs > before
  end)
  assert(vim.deep_equal(vim.list_slice(rpc_spawn.command, 9), command))
end

local before = #lsp_configs
table.insert(system_results, { code = 1, stdout = "", stderr = "stopped" })
table.insert(system_results, { code = 0, stdout = "", stderr = "" })
lsp.setup({ enabled = true, server = "phpactor", auto_start = true }, function()
  return project
end)
vim.wait(1000, function()
  return #lsp_configs > before
end)
assert(vim.deep_equal(system_commands[#system_commands - 3].command, {
  "ddev",
  "exec",
  "--raw",
  "--",
  "true",
}))
assert(vim.deep_equal(system_commands[#system_commands - 2].command, { "ddev", "start", "-y" }))

local stopped = false
local restart_forced = false
clients = {
  {
    id = 99,
    name = "ddev-phpactor",
    config = { root_dir = project },
    is_stopped = function()
      return stopped
    end,
    stop = function(force)
      restart_forced = restart_forced or force == true
      stopped = true
    end,
  },
}
vim.cmd("DdevLspRestart")
vim.wait(1000, function()
  return stopped and #lsp_configs > before + 1
end)
assert(stopped)
assert(restart_forced)

local notification_count = #notifications
before = #lsp_configs
table.insert(system_results, { code = 1, stdout = "", stderr = "stopped" })
lsp.setup({ enabled = true, server = "phpactor" }, function()
  return project
end)
vim.wait(1000, function()
  return #notifications > notification_count
end)
assert(#lsp_configs == before)
assert(notifications[#notifications]:match("DDEV project is not running"))

local valid = pcall(lsp.setup, { enabled = true, server = "unknown" }, function()
  return project
end)
assert(not valid)
lsp.setup({ enabled = false }, function()
  return project
end)
assert(vim.fn.exists(":DdevLspStart") == 0)

vim.lsp.get_clients = original_get_clients
vim.fn.delete(project, "rf")

print("ddev.nvim check passed")
