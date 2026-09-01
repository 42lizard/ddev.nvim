local M = {}

local presets = {
  phpactor = { "vendor/bin/phpactor", "language-server" },
  psalm = { "vendor/bin/psalm-language-server" },
  intelephense = { "node_modules/.bin/intelephense", "--stdio" },
}

local state = {
  options = nil,
  pending = {},
  root_for_buf = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "ddev.nvim" })
end

local function strip_trailing_slash(path)
  return path == "/" and path or path:gsub("/+$", "")
end

local function replace_prefix(value, from, to)
  if value == from then
    return to
  end

  local next_character = value:sub(#from + 1, #from + 1)
  if value:sub(1, #from) == from and from:sub(-1) == "/" then
    return to .. "/" .. value:sub(#from + 1)
  end
  if value:sub(1, #from) == from and (next_character == "/" or next_character == "\\") then
    return to .. value:sub(#from + 1)
  end

  return value
end

local function translate(value, from, to)
  if type(value) == "string" then
    local translated = replace_prefix(value, vim.uri_from_fname(from), vim.uri_from_fname(to))
    return replace_prefix(translated, from, to)
  end

  if type(value) ~= "table" then
    return value
  end

  local translated = {}
  for key, item in pairs(value) do
    translated[translate(key, from, to)] = translate(item, from, to)
  end
  return setmetatable(translated, getmetatable(value))
end

local function rpc_client(dispatchers, root, container_root, runtime, server_command, spawn_options)
  local incoming = {
    notification = function(method, params)
      return dispatchers.notification(method, translate(params, container_root, root))
    end,
    server_request = function(method, params)
      local result, err = dispatchers.server_request(method, translate(params, container_root, root))
      return translate(result, root, container_root), translate(err, root, container_root)
    end,
    on_error = dispatchers.on_error,
    on_exit = dispatchers.on_exit,
  }
  local command = {
    "docker",
    "exec",
    "-i",
    "--user",
    runtime.user,
    "--workdir",
    container_root,
    runtime.container,
  }
  vim.list_extend(command, server_command)
  local rpc = vim.lsp.rpc.start(command, incoming, {
    cwd = root,
    detached = spawn_options.detached,
    env = spawn_options.env,
  })

  return {
    request = function(method, params, callback, notify_reply_callback)
      local outgoing = translate(params, root, container_root)
      if method == "initialize" then
        outgoing.processId = vim.NIL
      end
      return rpc.request(method, outgoing, function(err, result, ...)
        return callback(
          translate(err, container_root, root),
          translate(result, container_root, root),
          ...
        )
      end, notify_reply_callback)
    end,
    notify = function(method, params)
      return rpc.notify(method, translate(params, root, container_root))
    end,
    is_closing = rpc.is_closing,
    terminate = rpc.terminate,
  }
end

local function validate(options)
  if type(options.enabled) ~= "boolean" then
    error("ddev.nvim: lsp.enabled must be a boolean")
  end
  if not options.enabled then
    return
  end
  if not presets[options.server] then
    error("ddev.nvim: unknown LSP server " .. tostring(options.server))
  end
  if type(options.auto_start) ~= "boolean" then
    error("ddev.nvim: lsp.auto_start must be a boolean")
  end
  if type(options.container_root) ~= "string" or options.container_root:sub(1, 1) ~= "/" then
    error("ddev.nvim: lsp.container_root must be an absolute container path")
  end
  if options.cmd then
    if type(options.cmd) ~= "table" or #options.cmd == 0 then
      error("ddev.nvim: lsp.cmd must be a non-empty list")
    end
    for _, argument in ipairs(options.cmd) do
      if type(argument) ~= "string" then
        error("ddev.nvim: every lsp.cmd argument must be a string")
      end
    end
  end
  if type(options.config) ~= "table" then
    error("ddev.nvim: lsp.config must be a table")
  end
end

local function matching_clients(root)
  local clients = {}
  local name = "ddev-" .. state.options.server
  for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
    if client.config.root_dir == root and not client.is_stopped() then
      table.insert(clients, client)
    end
  end
  return clients
end

local function build_config(root, runtime)
  local options = state.options
  local server_command = vim.deepcopy(options.cmd or presets[options.server])
  local config = vim.deepcopy(options.config)
  local spawn_options = { detached = config.detached, env = config.cmd_env }

  config.name = "ddev-" .. options.server
  config.root_dir = root
  config.workspace_folders = nil
  config.cmd_cwd = root
  config.cmd = function(dispatchers)
    return rpc_client(dispatchers, root, options.container_root, runtime, server_command, spawn_options)
  end

  return config
end

local function start_client(root, bufnr, runtime)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "php" then
    return
  end

  vim.lsp.start(build_config(root, runtime), {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == config.name
        and client.config.root_dir == config.root_dir
        and not client.is_stopped()
    end,
  })
end

local function complete_request(root, request)
  if state.pending[root] ~= request then
    return
  end
  state.pending[root] = nil
  for bufnr in pairs(request.buffers) do
    start_client(root, bufnr, request.runtime)
  end
end

local function system(command, root, callback)
  vim.system(command, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function resolve_runtime(root, request)
  system({
    "docker",
    "ps",
    "--filter",
    "label=com.ddev.approot=" .. root,
    "--filter",
    "label=com.docker.compose.service=web",
    "--format",
    "{{.Names}}",
  }, root, function(result)
    if state.pending[root] ~= request then
      return
    end

    local container = (result.stdout or ""):match("^%s*([^%s]+)%s*$")
    if result.code ~= 0 or not container then
      state.pending[root] = nil
      notify("Failed to find the DDEV web container.", vim.log.levels.ERROR)
      return
    end

    system({ "docker", "exec", container, "printenv", "DDEV_USER" }, root, function(user_result)
      if state.pending[root] ~= request then
        return
      end

      local user = (user_result.stdout or ""):match("^%s*([^%s]+)%s*$")
      if user_result.code ~= 0 or not user then
        state.pending[root] = nil
        notify("Failed to determine the DDEV web user.", vim.log.levels.ERROR)
        return
      end

      request.runtime = { container = container, user = user }
      complete_request(root, request)
    end)
  end)
end

local function check_project(root, request)
  system({ "ddev", "exec", "--raw", "--", "true" }, root, function(result)
    if state.pending[root] ~= request then
      return
    end
    if result.code == 0 then
      resolve_runtime(root, request)
      return
    end
    if not state.options.auto_start then
      state.pending[root] = nil
      notify("DDEV project is not running. Run ddev start or :DdevLspStart after starting it.")
      return
    end

    system({ "ddev", "start", "-y" }, root, function(start_result)
      if state.pending[root] ~= request then
        return
      end
      if start_result.code == 0 then
        resolve_runtime(root, request)
        return
      end
      state.pending[root] = nil
      local detail = (start_result.stderr or start_result.stdout or ""):gsub("%s+$", "")
      notify("Failed to start DDEV" .. (detail == "" and "." or ": " .. detail), vim.log.levels.ERROR)
    end)
  end)
end

function M.start(bufnr, quiet)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or (bufnr or vim.api.nvim_get_current_buf())
  if vim.bo[bufnr].filetype ~= "php" then
    if not quiet then
      notify("DDEV LSP only attaches to PHP buffers.")
    end
    return
  end

  local root = state.root_for_buf(bufnr, quiet)
  if not root then
    return
  end

  local clients = matching_clients(root)
  if clients[1] then
    vim.lsp.buf_attach_client(bufnr, clients[1].id)
    return
  end

  local request = state.pending[root]
  if request then
    request.buffers[bufnr] = true
    return
  end

  local command = state.options.cmd or presets[state.options.server]
  if not state.options.cmd and not (vim.uv or vim.loop).fs_stat(root .. "/" .. command[1]) then
    notify("DDEV LSP executable not found: " .. command[1] .. ". Install it or set lsp.cmd.")
    return
  end

  request = { buffers = { [bufnr] = true } }
  state.pending[root] = request
  check_project(root, request)
end

function M.restart(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or (bufnr or vim.api.nvim_get_current_buf())
  local root = state.root_for_buf(bufnr, false)
  if not root then
    return
  end

  state.pending[root] = nil
  for _, client in ipairs(matching_clients(root)) do
    client.stop(true)
  end
  vim.schedule(function()
    M.start(bufnr, false)
  end)
end

function M.setup(options, root_for_buf)
  options = vim.tbl_deep_extend("force", {
    enabled = false,
    server = "phpactor",
    auto_start = false,
    container_root = "/var/www/html",
    config = {},
  }, options or {})
  validate(options)
  options.container_root = strip_trailing_slash(options.container_root)
  state.options = options
  state.root_for_buf = root_for_buf
  state.pending = {}

  local group = vim.api.nvim_create_augroup("DdevLsp", { clear = true })
  pcall(vim.api.nvim_del_user_command, "DdevLspStart")
  pcall(vim.api.nvim_del_user_command, "DdevLspRestart")
  if not options.enabled then
    return
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "php",
    callback = function(event)
      M.start(event.buf, true)
    end,
  })
  vim.api.nvim_create_user_command("DdevLspStart", function()
    M.start(0, false)
  end, { desc = "Start the configured DDEV language server" })
  vim.api.nvim_create_user_command("DdevLspRestart", function()
    M.restart(0)
  end, { desc = "Restart the configured DDEV language server" })

  if vim.bo.filetype == "php" then
    vim.schedule(function()
      M.start(0, true)
    end)
  end
end

return M
