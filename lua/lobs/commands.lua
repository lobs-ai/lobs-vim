-- lobs.nvim — command registration
local M = {}

--- Format a timestamp as a relative time string
---@param ts number Unix timestamp
---@return string
local function time_ago(ts)
  if not ts then return "unknown" end
  local diff = os.time() - ts
  if diff < 60 then return "just now" end
  if diff < 3600 then return string.format("%dm ago", math.floor(diff / 60)) end
  if diff < 86400 then return string.format("%dh ago", math.floor(diff / 3600)) end
  return string.format("%dd ago", math.floor(diff / 86400))
end

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
    local s = client:status()
    local parts = {
      string.format("State: %s", s.state),
      string.format("Server: %s", s.server),
    }
    if s.session then
      table.insert(parts, string.format("Session: %s", s.session))
    end
    if s.resumed then
      table.insert(parts, "Resumed: yes")
    end
    if s.waiting then
      table.insert(parts, "Waiting: yes")
    end
    if s.auth ~= "none" then
      table.insert(parts, "Auth: " .. s.auth)
    end
    vim.notify("Lobs: " .. table.concat(parts, " | "), vim.log.levels.INFO)
  end, { desc = "Show Lobs connection status" })

  cmd("LobsConnect", function()
    require("lobs").client():connect(function(err)
      if err then
        vim.notify("Lobs: " .. err, vim.log.levels.ERROR)
      end
    end)
  end, { desc = "Connect to Lobs server" })

  cmd("LobsDisconnect", function()
    require("lobs").client():disconnect()
    vim.notify("Lobs: disconnected", vim.log.levels.INFO)
  end, { desc = "Disconnect from Lobs server" })

  cmd("LobsSessions", function()
    local sessions = require("lobs.sessions")
    local all = sessions.list_sessions()

    if #all == 0 then
      vim.notify("Lobs: No saved sessions", vim.log.levels.INFO)
      return
    end

    -- Build items for vim.ui.select
    local items = {}
    local labels = {}
    for _, s in ipairs(all) do
      table.insert(items, s)
      local project_name = vim.fn.fnamemodify(s.project_root, ":t")
      local label = string.format(
        "%s  %s  %s  (%s)",
        s.session_key,
        project_name,
        s.title or "",
        time_ago(s.last_used)
      )
      table.insert(labels, label)
    end

    vim.ui.select(labels, {
      prompt = "Lobs Sessions (select to switch, or press d to delete):",
      format_item = function(item) return item end,
    }, function(choice, idx)
      if not choice or not idx then return end
      local selected = items[idx]
      if not selected then return end

      -- Ask what to do with the session
      vim.ui.select({ "Switch to this session", "Delete this session", "Cancel" }, {
        prompt = "Action for " .. selected.session_key .. ":",
      }, function(action, action_idx)
        if not action or action_idx == 3 then return end

        if action_idx == 1 then
          -- Switch session
          local client = require("lobs").client()
          local chat = require("lobs").chat()

          -- Disconnect and reconnect with the selected session
          client.session_key = selected.session_key
          client._resumed_session = true

          -- Clear chat messages so history will populate them
          chat._messages = {}
          chat._loading_history = true
          chat:_render()

          if client._connected then
            client:disconnect()
          end
          client:connect(function(err)
            if err then
              vim.notify("Lobs: " .. err, vim.log.levels.ERROR)
            end
          end)
        elseif action_idx == 2 then
          -- Delete session
          sessions.delete_session(selected.session_key)
          vim.notify("Lobs: Deleted session " .. selected.session_key, vim.log.levels.INFO)
        end
      end)
    end)
  end, { desc = "Manage Lobs sessions" })

  cmd("LobsAuth", function(args)
    local subcmd = args.args
    if subcmd == "clear" then
      require("lobs.auth").clear_cache()
    elseif subcmd == "status" then
      local config = require("lobs").config
      local cf = config.cloudflare or {}
      if not cf.enabled then
        vim.notify("Lobs: Cloudflare Access not enabled", vim.log.levels.INFO)
        return
      end
      require("lobs.auth").check_status(config, function(ok)
        if ok then
          vim.notify("Lobs: Auth token valid", vim.log.levels.INFO)
        else
          vim.notify("Lobs: No valid token — run :LobsConnect", vim.log.levels.WARN)
        end
      end)
    else
      -- Default: force re-auth
      require("lobs.auth").clear_cache()
      require("lobs").client():connect(function(err)
        if err then
          vim.notify("Lobs: " .. err, vim.log.levels.ERROR)
        end
      end)
    end
  end, {
    nargs = "?",
    complete = function() return { "clear", "status" } end,
    desc = "Manage Lobs auth (clear | status | <default: re-login>)",
  })
end

return M
