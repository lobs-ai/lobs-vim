-- lobs.nvim — chat sidebar UI
local NuiSplit = require("nui.split")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local M = {}
M.__index = M

---@class LobsChat
---@field config table
---@field split NuiSplit|nil
---@field chat_buf number|nil
---@field input_buf number|nil
---@field _visible boolean
---@field _messages table[]
---@field _streaming boolean
---@field _disconnect_pending boolean
---@field _loading_history boolean

--- Create a new chat UI
---@param config table
---@return LobsChat
function M.new(config)
  local self = setmetatable({}, M)
  self.config = config
  self.split = nil
  self.chat_buf = nil
  self.input_buf = nil
  self._visible = false
  self._messages = {}
  self._streaming = false
  self._current_stream = ""
  self._disconnect_pending = false
  self._loading_history = false
  self._history_registered = false
  return self
end

--- Toggle the sidebar
function M:toggle()
  if self._visible then
    self:close()
  else
    self:open()
  end
end

--- Open the chat sidebar
function M:open()
  if self._visible then return end

  -- Create the split for the sidebar
  self.split = NuiSplit({
    relative = "editor",
    position = self.config.sidebar_position or "right",
    size = self.config.sidebar_width or 60,
  })

  self.split:mount()
  self._visible = true
  self.chat_buf = self.split.bufnr

  -- Configure chat buffer
  vim.bo[self.chat_buf].filetype = "lobschat"
  vim.bo[self.chat_buf].buftype = "nofile"
  vim.bo[self.chat_buf].swapfile = false
  vim.bo[self.chat_buf].modifiable = false
  vim.wo[self.split.winid].wrap = true
  vim.wo[self.split.winid].linebreak = true
  vim.wo[self.split.winid].number = false
  vim.wo[self.split.winid].relativenumber = false
  vim.wo[self.split.winid].signcolumn = "no"
  vim.wo[self.split.winid].cursorline = false

  -- Create input buffer at the bottom
  self:_create_input_area()

  -- Register history handler on the client
  self:_register_history_handler()

  -- Render existing messages
  self:_render()

  -- Set up keymaps in chat buffer
  self:_setup_keymaps()
end

--- Register the history handler on the client (once)
function M:_register_history_handler()
  if self._history_registered then return end
  self._history_registered = true

  local client = require("lobs").client()
  client:on_history(function(messages)
    vim.schedule(function()
      self._loading_history = false

      if not messages or #messages == 0 then
        self:_render()
        return
      end

      -- Populate _messages from history, but only if we don't already have messages
      -- (avoid duplicating if the user has been chatting)
      if #self._messages == 0 then
        self._messages = {}
        for _, msg in ipairs(messages) do
          table.insert(self._messages, {
            role = msg.role,
            content = msg.content or "",
            timestamp = msg.timestamp,
            tools = nil,
            from_history = true,
          })
        end
      end

      -- If we were in a disconnect-pending state, clear it
      if self._disconnect_pending then
        self._disconnect_pending = false
      end

      self:_render()
    end)
  end)
end

--- Close the sidebar
function M:close()
  if not self._visible then return end

  if self.split then
    self.split:unmount()
    self.split = nil
  end

  -- Clean up input window/buffer
  if self._input_win and vim.api.nvim_win_is_valid(self._input_win) then
    vim.api.nvim_win_close(self._input_win, true)
  end
  if self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf) then
    vim.api.nvim_buf_delete(self.input_buf, { force = true })
  end

  self._visible = false
  self.chat_buf = nil
  self.input_buf = nil
  self._input_win = nil
end

--- Create the input area at the bottom of the sidebar
function M:_create_input_area()
  if not self._visible or not self.split then return end

  -- Create a separate buffer for input
  self.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.input_buf].filetype = "lobsinput"
  vim.bo[self.input_buf].buftype = "nofile"

  -- Split the sidebar window horizontally to create input area at bottom
  local chat_win = self.split.winid
  vim.api.nvim_set_current_win(chat_win)
  vim.cmd("belowright 5split")
  self._input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self._input_win, self.input_buf)

  -- Configure input window
  vim.wo[self._input_win].wrap = true
  vim.wo[self._input_win].number = false
  vim.wo[self._input_win].relativenumber = false
  vim.wo[self._input_win].signcolumn = "no"
  vim.wo[self._input_win].winhighlight = "Normal:LobsInput,NormalNC:LobsInput"

  -- Set placeholder text
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, {})
  vim.api.nvim_buf_set_extmark(self.input_buf, vim.api.nvim_create_namespace("lobs_placeholder"), 0, 0, {
    virt_text = { { "Ask Lobs something...", "Comment" } },
    virt_text_pos = "overlay",
  })

  -- Send on Enter in normal mode in the input buffer
  vim.keymap.set("n", "<CR>", function()
    self:send()
  end, { buffer = self.input_buf, desc = "Send to Lobs" })

  -- Ctrl-Enter to send from insert mode
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    self:send()
  end, { buffer = self.input_buf, desc = "Send to Lobs" })
end

--- Focus the input area
function M:focus_input()
  if self._input_win and vim.api.nvim_win_is_valid(self._input_win) then
    vim.api.nvim_set_current_win(self._input_win)
    vim.cmd("startinsert")
  end
end

--- Send the current input
function M:send()
  if self._streaming then
    vim.notify("Lobs is still responding...", vim.log.levels.WARN)
    return
  end

  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then return end

  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local content = vim.fn.trim(table.concat(lines, "\n"))

  if content == "" then return end

  -- Clear input
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, {})

  -- Clear disconnect-pending state when sending new message
  self._disconnect_pending = false

  -- Add user message
  self:_add_message("user", content)

  -- Gather context and send
  local context = require("lobs.context").build()
  self:_send_to_agent(content, context)
end

--- Ask about specific code
---@param selection table Selection from context.get_visual_selection()
---@param prompt string|nil Optional prompt
function M:ask_about_code(selection, prompt)
  local content = prompt or "Explain this code and suggest improvements:"
  local context = require("lobs.context").build({ selection = selection })

  self:_add_message("user", content)
  self:_send_to_agent(content, context)
end

--- Start a new session
function M:new_session()
  local client = require("lobs").client()
  client:reset_session()
  client:stop_stream()

  self._messages = {}
  self._streaming = false
  self._current_stream = ""
  self._disconnect_pending = false
  self._loading_history = false

  self:_render()
  vim.notify("Started new Lobs session", vim.log.levels.INFO)

  if self._visible then
    self:focus_input()
  end
end

--- Send message to the agent
---@param content string
---@param context table
function M:_send_to_agent(content, context)
  self._streaming = true
  self._current_stream = ""

  -- Add a placeholder for the assistant response
  self:_add_message("assistant", "")
  local msg_idx = #self._messages

  local client = require("lobs").client()

  client:send_message(content, context, {
    on_thinking = function()
      -- No-op: the streaming indicator at the bottom of chat handles this
      self:_render()
    end,

    on_text = function(text)
      self._current_stream = self._current_stream .. text
      self._messages[msg_idx].content = self._current_stream
      self:_render()
    end,

    on_tool_start = function(name, _input)
      local tool_line = string.format("🔧 %s", name)
      if self._messages[msg_idx].tools == nil then
        self._messages[msg_idx].tools = {}
      end
      table.insert(self._messages[msg_idx].tools, { name = name, status = "running" })
      self:_render()
    end,

    on_tool_result = function(name, _result, is_error)
      if self._messages[msg_idx].tools then
        for _, tool in ipairs(self._messages[msg_idx].tools) do
          if tool.name == name and tool.status == "running" then
            tool.status = is_error and "error" or "done"
            break
          end
        end
      end
      self:_render()
    end,

    on_reply = function(text)
      if text and text ~= "" then
        self._messages[msg_idx].content = text
      end
      self:_render()
    end,

    on_done = function()
      self._streaming = false
      self._current_stream = ""
      self._disconnect_pending = false
      self:_render()

      -- Update session timestamp
      local sess_client = require("lobs").client()
      if sess_client.session_key then
        require("lobs.sessions").update_last_used(sess_client.session_key)
      end
    end,

    on_error = function(err)
      self._streaming = false
      self._messages[msg_idx].content = "❌ Error: " .. (err or "unknown")
      self._messages[msg_idx].is_error = true
      self:_render()
    end,

    on_disconnect_pending = function()
      self._disconnect_pending = true
      -- Don't clear streaming — we want to show the pending state
      self:_render()
    end,

    on_stall = function(elapsed)
      -- Show stall indicator without clearing the stream
      if self._streaming and self._messages[msg_idx] then
        self:_render()
      end
    end,

    on_title_update = function(title)
      -- Re-render to show updated title in header
      self:_render()
    end,
  })
end

--- Add a message to the chat
---@param role string "user" or "assistant"
---@param content string
function M:_add_message(role, content)
  table.insert(self._messages, {
    role = role,
    content = content,
    timestamp = os.time(),
    tools = nil,
  })
  self:_render()
end

--- Render all messages to the chat buffer
function M:_render()
  if not self.chat_buf or not vim.api.nvim_buf_is_valid(self.chat_buf) then return end

  vim.bo[self.chat_buf].modifiable = true

  local lines = {}
  local hl_ranges = {} -- { line, col_start, col_end, hl_group }

  -- Session info header
  local client = require("lobs").client()
  if client.session_key then
    local title = client._session_title or client.session_key
    local session_label = "📎 " .. title
    if client._resumed_session then
      session_label = session_label .. " (resumed)"
    end
    table.insert(lines, session_label)
    table.insert(hl_ranges, { #lines, 0, #session_label, "Comment" })
    table.insert(lines, "")
  end

  -- Loading history indicator
  if self._loading_history then
    table.insert(lines, "  ⏳ Loading history...")
    table.insert(hl_ranges, { #lines, 0, -1, "Comment" })
    table.insert(lines, "")
  end

  for _, msg in ipairs(self._messages) do
    -- Role header
    local role_label = msg.role == "user" and "  You" or "  Lobs"
    local role_hl = msg.role == "user" and "LobsUser" or "LobsAssistant"

    -- Add history marker for old messages
    if msg.from_history then
      role_label = role_label .. " (history)"
    end

    table.insert(lines, role_label)
    table.insert(hl_ranges, { #lines, 0, #role_label, role_hl })
    table.insert(lines, string.rep("─", 40))

    -- Tool calls
    if msg.tools then
      for _, tool in ipairs(msg.tools) do
        local icon = tool.status == "running" and "⏳" or (tool.status == "error" and "❌" or "✅")
        table.insert(lines, string.format("  %s %s", icon, tool.name))
      end
      if msg.content and msg.content ~= "" then
        table.insert(lines, "")
      end
    end

    -- Content
    if msg.content and msg.content ~= "" then
      -- Error messages get special treatment
      if msg.is_error then
        for _, line in ipairs(vim.split(msg.content, "\n")) do
          table.insert(lines, "  " .. line)
          table.insert(hl_ranges, { #lines, 0, -1, "ErrorMsg" })
        end
      else
        for _, line in ipairs(vim.split(msg.content, "\n")) do
          table.insert(lines, "  " .. line)
        end
      end
    end

    -- Separator
    table.insert(lines, "")
  end

  -- Status indicators
  if self._disconnect_pending then
    table.insert(lines, "  ⏳ Disconnected — response pending on server...")
    table.insert(hl_ranges, { #lines, 0, -1, "WarningMsg" })
    table.insert(lines, "  Will resume when reconnected.")
    table.insert(hl_ranges, { #lines, 0, -1, "Comment" })
  elseif self._streaming then
    -- Only show indicator if no text has streamed yet (still thinking/waiting)
    if self._current_stream == "" then
      local client_ref = require("lobs").client()
      if client_ref._waiting_for_response and client_ref._last_data_time then
        local elapsed = os.time() - client_ref._last_data_time
        if elapsed >= 30 then
          table.insert(lines, string.format("  ⏳ Still waiting... (%ds)", elapsed))
          table.insert(hl_ranges, { #lines, 0, -1, "WarningMsg" })
        else
          table.insert(lines, "  ⏳ Thinking...")
          table.insert(hl_ranges, { #lines, 0, -1, "Comment" })
        end
      else
        table.insert(lines, "  ⏳ Thinking...")
        table.insert(hl_ranges, { #lines, 0, -1, "Comment" })
      end
    end
  end

  vim.api.nvim_buf_set_lines(self.chat_buf, 0, -1, false, lines)
  vim.bo[self.chat_buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("lobs_chat")
  vim.api.nvim_buf_clear_namespace(self.chat_buf, ns, 0, -1)
  for _, hl in ipairs(hl_ranges) do
    vim.api.nvim_buf_add_highlight(self.chat_buf, ns, hl[4], hl[1] - 1, hl[2], hl[3])
  end

  -- Scroll to bottom
  if self.split and self.split.winid and vim.api.nvim_win_is_valid(self.split.winid) then
    local line_count = vim.api.nvim_buf_line_count(self.chat_buf)
    vim.api.nvim_win_set_cursor(self.split.winid, { line_count, 0 })
  end
end

--- Set up keymaps for the chat buffer
function M:_setup_keymaps()
  if not self.chat_buf then return end

  -- q to close sidebar from chat buffer
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.chat_buf, desc = "Close Lobs chat" })
end

return M
