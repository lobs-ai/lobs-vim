-- lobs.nvim — local tool proxy
-- Handles file changes made by the remote agent and syncs them with Neovim buffers.
-- In the future, this will handle bidirectional tool execution (agent requests → local execution).
local M = {}
M.__index = M

function M.new()
  local self = setmetatable({}, M)
  self._pending_changes = {}
  return self
end

--- Handle a file change event from the agent (write or edit tool result)
--- Reloads any open buffers that were modified.
---@param event table Tool result event
function M:handle_file_change(event)
  if not event.toolName then return end

  -- Try to extract the file path from the tool input
  local path = nil
  if event.toolInput then
    local ok, input = pcall(vim.fn.json_decode, event.toolInput)
    if ok and input then
      path = input.path
    end
  end

  if not path then return end

  -- Resolve to absolute path
  local abs_path = vim.fn.fnamemodify(path, ":p")

  -- Find and reload any buffer with this file
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == abs_path then
        -- Reload the buffer from disk
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("checktime")
        end)
        vim.notify("Lobs updated: " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.INFO)
        break
      end
    end
  end
end

--- Record a pending file change for diff review
---@param path string
---@param original string
---@param modified string
function M:add_pending_change(path, original, modified)
  table.insert(self._pending_changes, {
    path = path,
    original = original,
    modified = modified,
    timestamp = os.time(),
  })
end

--- Get all pending changes
---@return table[]
function M:get_pending_changes()
  return self._pending_changes
end

--- Clear pending changes
function M:clear_pending_changes()
  self._pending_changes = {}
end

return M
