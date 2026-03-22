-- lobs.nvim — WebSocket protocol message builders
-- Defines the message format for client↔server communication
local M = {}

local _id = 0

--- Generate a unique request ID
---@return string
local function next_id()
  _id = _id + 1
  return "req-" .. _id
end

--- Build a session.open message
---@param opts table { projectRoot: string, sessionKey?: string }
---@return table
function M.session_open(opts)
  return {
    type = "session.open",
    id = next_id(),
    projectRoot = opts.projectRoot,
    sessionKey = opts.sessionKey,
  }
end

--- Build a chat.send message
---@param opts table { sessionKey?: string, content: string, context: table }
---@return table
function M.chat_send(opts)
  return {
    type = "chat.send",
    id = next_id(),
    sessionKey = opts.sessionKey,
    content = opts.content,
    context = opts.context,
  }
end

--- Build a tool.result message (responding to server's tool.request)
---@param opts table { id: string, toolUseId: string, content: string, isError: boolean }
---@return table
function M.tool_result(opts)
  return {
    type = "tool.result",
    id = opts.id,
    toolUseId = opts.toolUseId,
    content = opts.content,
    isError = opts.isError or false,
  }
end

--- Build a diff.resolve message
---@param opts table { diffId: string, accepted: boolean }
---@return table
function M.diff_resolve(opts)
  return {
    type = "diff.resolve",
    id = next_id(),
    diffId = opts.diffId,
    accepted = opts.accepted,
  }
end

--- Build a session.history request message
---@param opts table { sessionKey: string }
---@return table
function M.session_history(opts)
  return {
    type = "session.history",
    id = next_id(),
    sessionKey = opts.sessionKey,
  }
end

return M
