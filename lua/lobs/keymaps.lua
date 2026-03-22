-- lobs.nvim — keymap registration
local M = {}

function M.register(keymaps)
  local map = vim.keymap.set

  if keymaps.toggle then
    map("n", keymaps.toggle, "<cmd>LobsToggle<cr>", { desc = "Toggle Lobs chat" })
  end

  if keymaps.new_session then
    map("n", keymaps.new_session, "<cmd>LobsNewSession<cr>", { desc = "New Lobs chat" })
  end

  if keymaps.ask_selection then
    map("v", keymaps.ask_selection, "<cmd>LobsAsk<cr>", { desc = "Ask Lobs about selection" })
  end
end

return M
