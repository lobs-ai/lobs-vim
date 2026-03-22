-- lobs.nvim plugin loader
-- Loaded automatically by lazy.nvim / packer / etc.

if vim.g.loaded_lobs then
  return
end
vim.g.loaded_lobs = 1

-- Set up highlights on ColorScheme changes
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("LobsHighlights", { clear = true }),
  callback = function()
    require("lobs.ui.highlights").setup()
  end,
})

-- Initial highlight setup
require("lobs.ui.highlights").setup()
