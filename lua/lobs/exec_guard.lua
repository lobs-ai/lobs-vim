-- lobs.nvim — exec command approval system
-- Protects against dangerous commands by requiring user approval.
-- Safe commands (read-only, dev tools) run without prompting.
-- Dangerous commands prompt once; user can approve once or for the session.
local M = {}

--- Commands that are always safe (read-only, dev tools, build tools)
M.safe_commands = {
  -- filesystem read-only
  "ls", "cat", "head", "tail", "wc", "find", "fd", "tree", "du", "df",
  "stat", "file", "which", "whereis", "type", "realpath", "readlink",
  "basename", "dirname", "mkdir",
  -- search / text processing (read-only use)
  "grep", "rg", "ag", "ack", "awk",
  -- git
  "git",
  -- build/dev tools
  "node", "npm", "npx", "yarn", "pnpm", "bun", "deno",
  "cargo", "rustc", "rustup",
  "python", "python3", "pip", "pip3", "uv", "poetry",
  "go", "make", "cmake", "gcc", "g++", "clang", "clang++",
  "lua", "luarocks",
  "ruby", "gem", "bundle",
  "java", "javac", "mvn", "gradle",
  "docker", "docker-compose",
  -- shell builtins / harmless
  "echo", "printf", "date", "env", "printenv", "uname", "hostname",
  "pwd", "true", "false", "test", "[",
  -- text processing (output only, no file modification)
  "jq", "yq", "sort", "uniq", "cut", "tr", "tee",
  "xargs", "comm", "diff", "md5sum", "sha256sum", "shasum",
  -- editors/pagers (non-interactive in script context)
  "less", "more",
  -- network
  "curl", "wget",
  -- archive (read-only listing is common; extraction needs files but is generally safe)
  "tar", "gzip", "gunzip", "zip", "unzip",
  -- misc dev
  "ssh", "scp",
  "sqlite3",
  "touch",
  -- lobs
  "lobs",
}

--- Commands that are always blocked (never allow)
M.blocked_commands = {
  "sudo", "su", "shutdown", "reboot", "poweroff", "halt",
  "mkfs", "fdisk", "dd",
  ":(){ :|:& };:", -- fork bomb pattern
}

-- Session-approved commands (reset on plugin reload / new nvim session)
local _session_approved = {}

-- Build lookup tables for O(1) checks
local _safe_set = {}
local _blocked_set = {}

local function _build_sets()
  _safe_set = {}
  _blocked_set = {}
  for _, cmd in ipairs(M.safe_commands) do
    _safe_set[cmd] = true
  end
  for _, cmd in ipairs(M.blocked_commands) do
    _blocked_set[cmd] = true
  end
end

_build_sets()

--- Extract the base command from a command string.
--- Handles env vars, paths, subshells, redirections.
---@param cmd_str string
---@return string
local function extract_base_command(cmd_str)
  -- Strip leading whitespace
  local s = cmd_str:match("^%s*(.-)%s*$")
  if not s or s == "" then return "" end

  -- Strip leading env var assignments (FOO=bar cmd ...)
  while s:match("^[A-Za-z_][A-Za-z0-9_]*=") do
    s = s:match("^[A-Za-z_][A-Za-z0-9_]*=%S*%s+(.*)$") or s
    if s == cmd_str then break end -- prevent infinite loop
  end

  -- Get the first token
  local token = s:match("^(%S+)")
  if not token then return "" end

  -- Strip path prefix: /usr/bin/rm -> rm
  local base = token:match("([^/]+)$") or token

  return base
end

--- Split a shell command string into individual commands.
--- Handles &&, ||, ;, |, and subshells $(...).
---@param command string
---@return string[] list of individual command strings
local function split_commands(command)
  local commands = {}

  -- Extract commands from $(...) subshells first
  for subcmd in command:gmatch("%$%((.-)%)") do
    for _, c in ipairs(split_commands(subcmd)) do
      table.insert(commands, c)
    end
  end

  -- Extract commands from backtick subshells
  for subcmd in command:gmatch("`(.-)`") do
    for _, c in ipairs(split_commands(subcmd)) do
      table.insert(commands, c)
    end
  end

  -- Split on &&, ||, ;
  local s = command
  -- Handle || before | to avoid misparse
  s = s:gsub("||", "\0OR\0")
  s = s:gsub("&&", "\0AND\0")
  s = s:gsub(";", "\0SEMI\0")

  for part in s:gmatch("[^\0]+") do
    -- Skip the operator tokens
    if part ~= "OR" and part ~= "AND" and part ~= "SEMI" then
      -- For pipes, extract each segment
      for pipe_part in part:gmatch("[^|]+") do
        local trimmed = pipe_part:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
          -- Strip subshell expressions (already extracted above)
          trimmed = trimmed:gsub("%$%b()", "")
          trimmed = trimmed:gsub("`.-`", "")
          trimmed = trimmed:match("^%s*(.-)%s*$")
          if trimmed and trimmed ~= "" then
            table.insert(commands, trimmed)
          end
        end
      end
    end
  end

  return commands
end

--- Check if a full command string needs approval.
--- Returns: "safe", "blocked", or "needs_approval"
--- Also returns the list of commands that need approval.
---@param command string The full shell command
---@return string status ("safe"|"blocked"|"needs_approval")
---@return string[] unapproved list of base commands needing approval
function M.check(command)
  local parts = split_commands(command)
  local needs_approval = {}
  local seen = {}

  for _, part in ipairs(parts) do
    local base = extract_base_command(part)
    if base == "" then goto continue end

    -- Check blocked first
    if _blocked_set[base] then
      return "blocked", { base }
    end

    -- Check safe
    if _safe_set[base] then goto continue end

    -- Check session-approved
    if _session_approved[base] then goto continue end

    -- Needs approval
    if not seen[base] then
      table.insert(needs_approval, base)
      seen[base] = true
    end

    ::continue::
  end

  if #needs_approval == 0 then
    return "safe", {}
  end

  return "needs_approval", needs_approval
end

--- Approve a command for the rest of this session
---@param base_command string
function M.approve_session(base_command)
  _session_approved[base_command] = true
end

--- Check if a command is session-approved
---@param base_command string
---@return boolean
function M.is_session_approved(base_command)
  return _session_approved[base_command] == true
end

--- Clear session approvals (e.g. on session switch)
function M.clear_session_approvals()
  _session_approved = {}
end

--- Get current session approvals (for display)
---@return string[]
function M.get_session_approvals()
  local result = {}
  for cmd, _ in pairs(_session_approved) do
    table.insert(result, cmd)
  end
  table.sort(result)
  return result
end

--- Rebuild lookup sets (call if safe_commands is modified at runtime)
function M.rebuild()
  _build_sets()
end

return M
