-- lobs.nvim — highlight group definitions
local M = {}

function M.setup()
  -- Chat role headers
  vim.api.nvim_set_hl(0, "LobsUser", { fg = "#7aa2f7", bold = true })
  vim.api.nvim_set_hl(0, "LobsAssistant", { fg = "#9ece6a", bold = true })

  -- Input area
  vim.api.nvim_set_hl(0, "LobsInput", { bg = "#1a1b26" })

  -- Tool indicators
  vim.api.nvim_set_hl(0, "LobsToolRunning", { fg = "#e0af68" })
  vim.api.nvim_set_hl(0, "LobsToolDone", { fg = "#9ece6a" })
  vim.api.nvim_set_hl(0, "LobsToolError", { fg = "#f7768e" })

  -- Code blocks
  vim.api.nvim_set_hl(0, "LobsCodeBlock", { bg = "#292e42" })

  -- Separator
  vim.api.nvim_set_hl(0, "LobsSeparator", { fg = "#3b4261" })
end

return M
