-- lobs.nvim — AI coding agent for Neovim
-- Connects to lobs-core backend via WebSocket for agentic code editing.
local M = {}

M._started = false

--- Default configuration
M.defaults = {
  -- Server URL (WebSocket). Use wss:// for remote/Cloudflare Access.
  server = "ws://localhost:9420",

  -- Cloudflare Access (auto-detected from server URL, no secrets needed).
  -- Auth uses `cloudflared` CLI with browser-based login.
  cloudflare = {
    enabled = nil, ---@type boolean|nil nil = auto-detect from URL
  },

  -- UI
  sidebar_width = 60,
  sidebar_position = "right", -- "left" or "right"

  -- Context sent with each message
  send_current_file = true,
  send_selection = true,
  max_context_lines = 500,

  -- Keymaps (set to false to disable any)
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

  -- Auto-detect Cloudflare Access from server URL
  if M.config.cloudflare.enabled == nil then
    M.config.cloudflare.enabled = M.config.server:match("wss://.*%.lobslab%.com") ~= nil
  end

  -- Invalidate cached client/chat so they pick up new config
  if M._client then
    M._client:disconnect()
    M._client = nil
  end
  M._chat = nil

  -- Register commands
  require("lobs.commands").register()

  -- Set up keymaps
  require("lobs.keymaps").register(M.config.keymaps)

  M._started = true
end

--- Get the websocket client (lazy init)
function M.client()
  if not M._started then
    -- setup() hasn't been called — shouldn't happen with lazy.nvim
    -- but guard against it
    M.setup({})
  end
  if not M._client then
    M._client = require("lobs.client").new(M.config)
  end
  return M._client
end

--- Get the chat UI
function M.chat()
  if not M._started then
    M.setup({})
  end
  if not M._chat then
    M._chat = require("lobs.ui.chat").new(M.config)
  end
  return M._chat
end

return M
