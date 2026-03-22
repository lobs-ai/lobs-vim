-- lobs.nvim — local tool executor
-- Executes tools on the user's machine when the server delegates via WebSocket.
local M = {}
M.__index = M

---@class LobsToolExecutor
---@field _project_root string
---@field _config table

function M.new()
  local self = setmetatable({}, M)
  self._project_root = require("lobs.context").get_project_root()
  self._config = require("lobs").config
  return self
end

-- Map server tool names (PascalCase) to our handler keys (lowercase)
M._tool_aliases = {
  Read = "read",
  Write = "write",
  Edit = "edit",
  Grep = "grep",
  Glob = "glob",
}

--- Dispatch to the right tool handler
---@param tool_name string
---@param input table
---@param callback function(result: string, is_error: boolean)
function M:execute(tool_name, input, callback)
  -- Normalize: server may send "Read" but our handlers are keyed "read"
  local key = self._tool_aliases[tool_name] or tool_name:lower()
  local handler = self._handlers[key]
  if not handler then
    callback("Unknown tool: " .. tool_name, true)
    return
  end

  -- Validate paths are within project root (for file tools)
  if self._file_tools[key] and input.path then
    local ok, err = self:_validate_path(input.path)
    if not ok then
      callback("Path access denied: " .. err, true)
      return
    end
  end

  handler(self, input, callback)
end

--- Tool handlers table
M._handlers = {}

--- Which tools involve file paths that need sandboxing
M._file_tools = {
  read = true,
  write = true,
  edit = true,
  ls = true,
}

--- Validate a path is within the project root
---@param path string
---@return boolean, string|nil
function M:_validate_path(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local root = self._project_root

  if abs:sub(1, #root) ~= root then
    return false, string.format("'%s' is outside project root '%s'", path, root)
  end
  return true, nil
end

--- Resolve a path relative to project root
---@param path string
---@return string
function M:_resolve_path(path)
  if vim.fn.fnamemodify(path, ":p") == path then
    return path -- Already absolute
  end
  return self._project_root .. "/" .. path
end

-- read tool
M._handlers.read = function(self, input, callback)
  local path = self:_resolve_path(input.path)
  local ok, content = pcall(function()
    local lines = vim.fn.readfile(path)
    if input.offset and input.limit then
      local start = input.offset
      local stop = math.min(start + input.limit - 1, #lines)
      lines = vim.list_slice(lines, start, stop)
    end
    return table.concat(lines, "\n")
  end)

  if ok then
    callback(content, false)
  else
    callback("Failed to read file: " .. tostring(content), true)
  end
end

-- write tool
M._handlers.write = function(self, input, callback)
  local path = self:_resolve_path(input.path)

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  local ok, err = pcall(function()
    local lines = vim.split(input.content, "\n")
    vim.fn.writefile(lines, path)
  end)

  if ok then
    -- Reload any open buffer with this file
    M._reload_buffer(path)
    callback("Successfully wrote to " .. input.path, false)
  else
    callback("Failed to write file: " .. tostring(err), true)
  end
end

-- edit tool (search and replace)
M._handlers.edit = function(self, input, callback)
  local path = self:_resolve_path(input.path)

  local ok, result = pcall(function()
    local lines = vim.fn.readfile(path)
    local content = table.concat(lines, "\n")

    local old = input.old_string
    local new = input.new_string

    local idx = content:find(old, 1, true)
    if not idx then
      error("old_string not found in file")
    end

    content = content:sub(1, idx - 1) .. new .. content:sub(idx + #old)
    vim.fn.writefile(vim.split(content, "\n"), path)
    return "Edit applied successfully"
  end)

  if ok then
    M._reload_buffer(path)
    callback(result, false)
  else
    callback("Edit failed: " .. tostring(result), true)
  end
end

-- exec tool
M._handlers.exec = function(self, input, callback)
  local cmd = input.command
  local cwd = input.cwd and self:_resolve_path(input.cwd) or self._project_root
  local timeout = input.timeout or 30000

  vim.system(
    { "bash", "-c", cmd },
    {
      text = true,
      cwd = cwd,
      timeout = timeout,
    },
    function(result)
      vim.schedule(function()
        local output = (result.stdout or "") .. (result.stderr or "")
        if result.code ~= 0 then
          output = output .. "\n[exit code: " .. (result.code or "?") .. "]"
        end
        callback(output, result.code ~= 0)
      end)
    end
  )
end

-- ls tool
M._handlers.ls = function(self, input, callback)
  local path = input.path and self:_resolve_path(input.path) or self._project_root

  vim.system(
    { "ls", "-la", path },
    { text = true },
    function(result)
      vim.schedule(function()
        callback(result.stdout or "", result.code ~= 0)
      end)
    end
  )
end

-- grep tool
M._handlers.grep = function(self, input, callback)
  local args = { "rg", "--no-heading", "--line-number" }

  if input.include then
    table.insert(args, "--glob")
    table.insert(args, input.include)
  end

  table.insert(args, input.pattern)
  table.insert(args, input.path and self:_resolve_path(input.path) or self._project_root)

  vim.system(
    args,
    { text = true },
    function(result)
      vim.schedule(function()
        callback(result.stdout or "", false) -- grep returns 1 for no matches, which is fine
      end)
    end
  )
end

-- glob tool
M._handlers.glob = function(self, input, callback)
  vim.system(
    { "fd", "--glob", input.pattern, self._project_root },
    { text = true },
    function(result)
      vim.schedule(function()
        callback(result.stdout or "", result.code ~= 0)
      end)
    end
  )
end

-- find_files tool
M._handlers.find_files = function(self, input, callback)
  local args = { "fd" }

  if input.pattern then
    table.insert(args, input.pattern)
  end

  if input.extension then
    table.insert(args, "-e")
    table.insert(args, input.extension)
  end

  if input.type then
    table.insert(args, "-t")
    table.insert(args, input.type)
  end

  if input.max_depth then
    table.insert(args, "--max-depth")
    table.insert(args, tostring(input.max_depth))
  end

  table.insert(args, input.path and self:_resolve_path(input.path) or self._project_root)

  vim.system(
    args,
    { text = true },
    function(result)
      vim.schedule(function()
        callback(result.stdout or "", result.code ~= 0)
      end)
    end
  )
end

-- code_search tool
M._handlers.code_search = function(self, input, callback)
  local args = { "rg", "--no-heading", "--line-number" }

  if input.context_lines then
    table.insert(args, "-C")
    table.insert(args, tostring(input.context_lines))
  end

  if input.language then
    table.insert(args, "--type")
    table.insert(args, input.language)
  end

  if input.word_match then
    table.insert(args, "-w")
  end

  if input.max_results then
    table.insert(args, "--max-count")
    table.insert(args, tostring(input.max_results))
  end

  table.insert(args, input.pattern)
  table.insert(args, input.path and self:_resolve_path(input.path) or self._project_root)

  vim.system(
    args,
    { text = true },
    function(result)
      vim.schedule(function()
        callback(result.stdout or "", false)
      end)
    end
  )
end

--- Reload a buffer from disk if it's open in Neovim
---@param abs_path string
function M._reload_buffer(abs_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == abs_path then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("checktime")
        end)
        break
      end
    end
  end
end

return M
