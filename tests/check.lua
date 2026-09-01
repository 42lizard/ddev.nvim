local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

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

local prompt
vim.ui.select = function(_, options)
  prompt = options.prompt
end

require("ddev").setup({ translations = { menu_prompt = "Choose:" } })
vim.cmd("DdevMenu")
assert(prompt == "Choose:")

vim.cmd("Ddev version")
assert(opened.cmd == "ddev version")
assert(opened.direction == "float")

local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/.ddev", "p")
vim.fn.writefile({}, project .. "/.ddev/config.yaml")
vim.api.nvim_buf_set_name(0, project .. "/index.php")
vim.cmd("Ddev start")
assert(opened.cmd == "ddev start")
assert(vim.uv.fs_realpath(opened.dir) == vim.uv.fs_realpath(project))
vim.fn.delete(project, "rf")

print("ddev.nvim check passed")
