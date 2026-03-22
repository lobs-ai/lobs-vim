-- lobs.nvim — session persistence
-- Saves/loads session data to disk so sessions survive Neovim restarts.
local M = {}

local _data = nil
local _data_path = nil

--- Get the path to the sessions JSON file
---@return string
local function data_path()
  if not _data_path then
    _data_path = vim.fn.stdpath("data") .. "/lobs-sessions.json"
  end
  return _data_path
end

--- Load session data from disk
---@return table
local function load_data()
  if _data then return _data end

  local path = data_path()
  local f = io.open(path, "r")
  if not f then
    _data = { sessions = {}, project_map = {} }
    return _data
  end

  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if ok and type(decoded) == "table" then
    _data = {
      sessions = decoded.sessions or {},
      project_map = decoded.project_map or {},
    }
  else
    _data = { sessions = {}, project_map = {} }
  end

  return _data
end

--- Write session data to disk
local function persist()
  local path = data_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  local data = load_data()
  local json = vim.fn.json_encode(data)

  local f = io.open(path, "w")
  if f then
    f:write(json)
    f:close()
  end
end

--- Save a session
---@param session_key string
---@param project_root string
---@param title string|nil
function M.save_session(session_key, project_root, title)
  local data = load_data()

  data.sessions[session_key] = {
    project_root = project_root,
    created_at = data.sessions[session_key] and data.sessions[session_key].created_at or os.time(),
    last_used = os.time(),
    title = title or ("vim:" .. vim.fn.fnamemodify(project_root, ":t")),
  }

  data.project_map[project_root] = session_key
  persist()
end

--- Get the last session key for a project root
---@param project_root string
---@return string|nil session_key
function M.get_session_for_project(project_root)
  local data = load_data()
  local key = data.project_map[project_root]
  if key and data.sessions[key] then
    return key
  end
  -- Clean up stale mapping
  if key then
    data.project_map[project_root] = nil
    persist()
  end
  return nil
end

--- List all sessions sorted by last_used (most recent first)
---@return table[] Array of { session_key, project_root, created_at, last_used, title }
function M.list_sessions()
  local data = load_data()
  local result = {}

  for key, info in pairs(data.sessions) do
    table.insert(result, {
      session_key = key,
      project_root = info.project_root,
      created_at = info.created_at,
      last_used = info.last_used,
      title = info.title,
    })
  end

  table.sort(result, function(a, b)
    return (a.last_used or 0) > (b.last_used or 0)
  end)

  return result
end

--- Delete a session
---@param session_key string
function M.delete_session(session_key)
  local data = load_data()
  local info = data.sessions[session_key]
  if info then
    -- Remove project_map entry if it points to this session
    if info.project_root and data.project_map[info.project_root] == session_key then
      data.project_map[info.project_root] = nil
    end
    data.sessions[session_key] = nil
    persist()
  end
end

--- Update last_used timestamp for a session
---@param session_key string
function M.update_last_used(session_key)
  local data = load_data()
  if data.sessions[session_key] then
    data.sessions[session_key].last_used = os.time()
    persist()
  end
end

--- Clear the project mapping (for new session creation)
---@param project_root string
function M.clear_project_mapping(project_root)
  local data = load_data()
  data.project_map[project_root] = nil
  persist()
end

--- Reset cached data (forces reload from disk)
function M.reset_cache()
  _data = nil
end

return M
