-- lobs.nvim — WebSocket client for lobs-core
-- Uses vim.system + curl for WebSocket transport (Phase 1)
-- Will migrate to libuv TCP implementation later for better control
local M = {}
M.__index = M

local protocol = require("lobs.protocol")

---@class LobsClient
---@field config table
---@field session_key string|nil
---@field _connected boolean
---@field _ws_job vim.SystemObj|nil
---@field _pending table<string, {resolve: function, reject: function, timer: uv_timer_t}>
---@field _handlers table

--- Create a new client
---@param config table
---@return LobsClient
function M.new(config)
  local self = setmetatable({}, M)
  self.config = config
  self.session_key = nil
  self._connected = false
  self._ws_job = nil
  self._pending = {}
  self._handlers = {}
  self._base_url = config.server:gsub("^ws", "http"):gsub("/+$", "")
  self._ws_url = config.server:gsub("/+$", "") .. "/api/vim/ws"
  self._tool_executor = require("lobs.tools").new()
  self._reconnect_timer = nil
  self._reconnect_attempts = 0
  self._max_reconnect_attempts = 10
  self._outgoing_queue = {} -- Messages queued while disconnected
  return self
end

--- Connect to lobs-core via WebSocket
---@param callback function|nil Called when connected
function M:connect(callback)
  if self._connected then
    if callback then callback(nil) end
    return
  end

  -- Use curl for WebSocket (macOS ships with curl that supports --ws)
  -- Fallback: use websocat if available
  local url = self._ws_url
  if self.config.token and self.config.token ~= "" then
    local sep = url:find("?") and "&" or "?"
    url = url .. sep .. "token=" .. self.config.token
  end

  local buf = ""

  self._ws_job = vim.system(
    { "websocat", "--text", url },
    {
      text = true,
      stdout = function(err, data)
        if err or not data then return end
        vim.schedule(function()
          buf = buf .. data
          -- Parse newline-delimited JSON messages
          while true do
            local nl = buf:find("\n")
            if not nl then break end
            local line = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
            if line ~= "" then
              self:_on_message(line)
            end
          end
        end)
      end,
      stderr = function(err, data)
        if data and data ~= "" then
          vim.schedule(function()
            vim.notify("Lobs WS error: " .. data, vim.log.levels.ERROR)
          end)
        end
      end,
    },
    function(result)
      -- Process exited — connection closed
      vim.schedule(function()
        self._connected = false
        self:_on_disconnect()
      end)
    end
  )

  -- Consider connected once the process starts
  -- The server will send a session.opened message to confirm
  self._connected = true
  self._reconnect_attempts = 0

  -- Send session open request
  self:_send(protocol.session_open({
    projectRoot = require("lobs.context").get_project_root(),
    sessionKey = self.session_key,
  }))

  if callback then callback(nil) end
end

--- Send a raw message over WebSocket
---@param msg table
function M:_send(msg)
  if not self._connected or not self._ws_job then
    -- Queue the message for when we reconnect
    table.insert(self._outgoing_queue, msg)
    return
  end

  local json_str = vim.fn.json_encode(msg) .. "\n"
  -- vim.system uses stdin pipe — write via the process's stdin
  self._ws_job:write(json_str)
end

--- Stop any current stream (cancel in-progress response)
function M:stop_stream()
  -- Currently a no-op — in the future, send a cancel message to server
  self._handlers = {}
end

--- Send a chat message
---@param content string
---@param context table
---@param handlers table { on_text, on_tool_start, on_tool_result, on_done, on_error, on_thinking }
function M:send_message(content, context, handlers)
  self._handlers = handlers

  self:connect(function(err)
    if err then
      if handlers.on_error then handlers.on_error(err) end
      return
    end

    self:_send(protocol.chat_send({
      sessionKey = self.session_key,
      content = content,
      context = context,
    }))
  end)
end

--- Handle an incoming WebSocket message
---@param raw string JSON string
function M:_on_message(raw)
  local ok, msg = pcall(vim.fn.json_decode, raw)
  if not ok or not msg or not msg.type then return end

  local t = msg.type

  -- Session management
  if t == "session.opened" then
    self.session_key = msg.sessionKey
    vim.notify("Lobs session: " .. (msg.title or msg.sessionKey), vim.log.levels.INFO)

    -- Flush queued messages
    for _, queued in ipairs(self._outgoing_queue) do
      self:_send(queued)
    end
    self._outgoing_queue = {}

  -- Chat response streaming
  elseif t == "chat.delta" then
    if self._handlers.on_text then
      self._handlers.on_text(msg.content or "")
    end

  elseif t == "chat.status" then
    local status = msg.status
    if status == "thinking" and self._handlers.on_thinking then
      self._handlers.on_thinking()
    elseif status == "tool_running" and self._handlers.on_tool_start then
      self._handlers.on_tool_start(msg.toolName, msg.toolInput)
    elseif status == "tool_done" and self._handlers.on_tool_result then
      self._handlers.on_tool_result(msg.toolName, msg.result, msg.isError)
    elseif status == "done" and self._handlers.on_done then
      self._handlers.on_done()
    elseif status == "error" and self._handlers.on_error then
      self._handlers.on_error(msg.error or "unknown error")
    elseif status == "queued" then
      -- Optionally show queue position
      if self._handlers.on_thinking then
        self._handlers.on_thinking()
      end
    end

  -- Tool delegation: server asking us to execute a tool locally
  elseif t == "tool.request" then
    self:_handle_tool_request(msg)

  -- Diff proposal from agent
  elseif t == "diff.propose" then
    self:_handle_diff_propose(msg)

  -- Error
  elseif t == "error" then
    if self._handlers.on_error then
      self._handlers.on_error(msg.message or "server error")
    end
  end
end

--- Handle a tool execution request from the server
--- The agent wants us to run a tool locally (read, exec, grep, etc.)
---@param msg table
function M:_handle_tool_request(msg)
  local tool_name = msg.tool
  local tool_input = msg.args or msg.input or {}
  local request_id = msg.id
  local tool_use_id = msg.toolUseId

  -- Show in chat that a tool is running
  if self._handlers.on_tool_start then
    self._handlers.on_tool_start(tool_name, tool_input)
  end

  -- Execute the tool locally
  self._tool_executor:execute(tool_name, tool_input, function(result, is_error)
    -- Show result in chat
    if self._handlers.on_tool_result then
      self._handlers.on_tool_result(tool_name, result, is_error)
    end

    -- Send result back to server
    self:_send(protocol.tool_result({
      id = request_id,
      toolUseId = tool_use_id,
      content = result,
      isError = is_error or false,
    }))
  end)
end

--- Handle a diff proposal from the agent
---@param msg table
function M:_handle_diff_propose(msg)
  local diff = require("lobs.diff")
  diff.show_proposal(msg, function(accepted)
    self:_send(protocol.diff_resolve({
      diffId = msg.diffId,
      accepted = accepted,
    }))
  end)
end

--- Handle WebSocket disconnection
function M:_on_disconnect()
  if self._reconnect_attempts >= self._max_reconnect_attempts then
    vim.notify("Lobs: connection lost, giving up after " .. self._max_reconnect_attempts .. " attempts", vim.log.levels.ERROR)
    return
  end

  self._reconnect_attempts = self._reconnect_attempts + 1
  local delay = math.min(1000 * math.pow(2, self._reconnect_attempts - 1), 30000)

  vim.notify(string.format("Lobs: reconnecting in %ds (attempt %d)...", delay / 1000, self._reconnect_attempts), vim.log.levels.WARN)

  self._reconnect_timer = vim.defer_fn(function()
    self:connect()
  end, delay)
end

--- Disconnect
function M:disconnect()
  if self._ws_job then
    self._ws_job:kill("SIGTERM")
    self._ws_job = nil
  end
  self._connected = false
  if self._reconnect_timer then
    -- Cancel reconnect
    self._reconnect_timer = nil
  end
end

--- Get connection status
function M:status()
  return {
    state = self._connected and "connected" or "disconnected",
    server = self._ws_url,
    session = self.session_key,
  }
end

--- Reset session (for new session)
function M:reset_session()
  self.session_key = nil
  self:_send(protocol.session_open({
    projectRoot = require("lobs.context").get_project_root(),
  }))
end

return M
