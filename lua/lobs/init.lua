-- lobs.nvim — main entry point
local M = {}

M._started = false

--- Default configuration
M.defaults = {
  server = "ws://localhost:9420",
  token = "",
  -- UI
  sidebar_width = 60,
  sidebar_position = "right", -- "left" or "right"
  -- Context
  send_current_file = true,
  send_selection = true,
  max_context_lines = 500,
  -- Keymaps
  keymaps = {
    toggle = "<leader>aa",
    new_session = "<leader>ac",
    ask_selection = "<leader>as",
  },
}

M.config = vim.deepcopy(M.defaults)

--- Setup the plugin
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

  -- Register commands
  require("lobs.commands").register()

  -- Set up keymaps
  require("lobs.keymaps").register(M.config.keymaps)

  -- Connect to server (lazy — connects on first use)
  M._started = true
end

--- Get the websocket client (lazy init)
function M.client()
  if not M._client then
    M._client = require("lobs.client").new(M.config)
  end
  return M._client
end

--- Get the chat UI
function M.chat()
  if not M._chat then
    M._chat = require("lobs.ui.chat").new(M.config)
  end
  return M._chat
end

return M
