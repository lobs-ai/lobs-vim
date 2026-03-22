-- lobs.nvim — command registration
local M = {}

function M.register()
  local cmd = vim.api.nvim_create_user_command

  cmd("LobsToggle", function()
    require("lobs").chat():toggle()
  end, { desc = "Toggle Lobs chat sidebar" })

  cmd("LobsChat", function()
    require("lobs").chat():open()
    require("lobs").chat():focus_input()
  end, { desc = "Open Lobs chat and focus input" })

  cmd("LobsSend", function()
    require("lobs").chat():send()
  end, { desc = "Send current chat input" })

  cmd("LobsAsk", function(args)
    local lobs = require("lobs")
    local chat = lobs.chat()
    chat:open()

    local selection = require("lobs.context").get_visual_selection()
    if selection then
      local prompt = args.args ~= "" and args.args or nil
      chat:ask_about_code(selection, prompt)
    else
      chat:focus_input()
    end
  end, { range = true, nargs = "?", desc = "Ask Lobs about selected code" })

  cmd("LobsNewSession", function()
    require("lobs").chat():new_session()
  end, { desc = "Start a new Lobs chat session" })

  cmd("LobsAcceptAll", function()
    require("lobs.diff").accept_all()
  end, { desc = "Accept all pending Lobs changes" })

  cmd("LobsRejectAll", function()
    require("lobs.diff").reject_all()
  end, { desc = "Reject all pending Lobs changes" })

  cmd("LobsStatus", function()
    local client = require("lobs").client()
    local status = client:status()
    local parts = {
      string.format("State: %s", status.state),
      string.format("Server: %s", status.server),
    }
    if status.session then
      table.insert(parts, string.format("Session: %s", status.session))
    end
    vim.notify("Lobs: " .. table.concat(parts, " | "), vim.log.levels.INFO)
  end, { desc = "Show Lobs connection status" })

  cmd("LobsConnect", function()
    require("lobs").client():connect(function(err)
      if err then
        vim.notify("Lobs: failed to connect — " .. err, vim.log.levels.ERROR)
      end
    end)
  end, { desc = "Connect to Lobs server" })

  cmd("LobsDisconnect", function()
    require("lobs").client():disconnect()
    vim.notify("Lobs: disconnected", vim.log.levels.INFO)
  end, { desc = "Disconnect from Lobs server" })
end

return M
