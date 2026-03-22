-- lobs.nvim — context gathering
-- Collects current file, cursor position, selection, project root, etc.
local M = {}

--- Get the project root (git root or cwd)
---@return string
function M.get_project_root()
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")[1]
  if vim.v.shell_error == 0 and git_root and git_root ~= "" then
    return git_root
  end
  return vim.fn.getcwd()
end

--- Get current buffer context
---@return table|nil
function M.get_current_file()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil end

  local config = require("lobs").config
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Truncate if too long
  local max = config.max_context_lines or 500
  local truncated = false
  if #lines > max then
    lines = vim.list_slice(lines, 1, max)
    truncated = true
  end

  local cursor = vim.api.nvim_win_get_cursor(0)

  return {
    path = name,
    relative_path = vim.fn.fnamemodify(name, ":."),
    filetype = vim.bo[buf].filetype,
    lines = lines,
    content = table.concat(lines, "\n"),
    cursor_line = cursor[1],
    cursor_col = cursor[2],
    total_lines = vim.api.nvim_buf_line_count(buf),
    truncated = truncated,
  }
end

--- Get visual selection text and metadata
---@return table|nil
function M.get_visual_selection()
  local mode = vim.fn.mode()

  -- Get marks for visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line == 0 or end_line == 0 then return nil end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local name = vim.api.nvim_buf_get_name(buf)

  return {
    text = table.concat(lines, "\n"),
    path = name,
    relative_path = vim.fn.fnamemodify(name, ":."),
    filetype = vim.bo[buf].filetype,
    start_line = start_line,
    end_line = end_line,
  }
end

--- Build full context payload for a message
---@param opts table|nil Extra context options
---@return table
function M.build(opts)
  opts = opts or {}
  local config = require("lobs").config
  local ctx = {
    project_root = M.get_project_root(),
    cwd = vim.fn.getcwd(),
  }

  if config.send_current_file then
    ctx.current_file = M.get_current_file()
  end

  if opts.selection then
    ctx.selection = opts.selection
  end

  -- Open buffers (just paths, not contents)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(bufs, vim.fn.fnamemodify(name, ":."))
      end
    end
  end
  ctx.open_buffers = bufs

  return ctx
end

--- Read a file if it exists, return contents or nil
---@param path string
---@param max_lines number|nil
---@return string|nil
local function read_file(path, max_lines)
  local f = io.open(path, "r")
  if not f then return nil end
  local lines = {}
  local count = 0
  for line in f:lines() do
    count = count + 1
    if max_lines and count > max_lines then
      table.insert(lines, "... (truncated)")
      break
    end
    table.insert(lines, line)
  end
  f:close()
  if #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

--- Build project context string for new session injection.
--- Reads README.md, AGENTS.md, git info, directory structure.
---@return string|nil context string, or nil if nothing useful found
function M.build_project_context()
  local root = M.get_project_root()
  local parts = {}

  -- Working directory + project root
  local cwd = vim.fn.getcwd()
  table.insert(parts, "**Working directory:** `" .. cwd .. "`")
  if root ~= cwd then
    table.insert(parts, "**Project root:** `" .. root .. "`")
  end

  -- Git branch
  local branch = vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " branch --show-current 2>/dev/null")[1]
  if vim.v.shell_error == 0 and branch and branch ~= "" then
    table.insert(parts, "**Git branch:** `" .. branch .. "`")
  end

  -- Top-level directory listing (brief)
  local ls_output = vim.fn.systemlist("ls -1 " .. vim.fn.shellescape(root) .. " 2>/dev/null")
  if vim.v.shell_error == 0 and #ls_output > 0 then
    -- Limit to 30 entries
    local entries = {}
    for i = 1, math.min(#ls_output, 30) do
      table.insert(entries, ls_output[i])
    end
    if #ls_output > 30 then
      table.insert(entries, "... (" .. #ls_output .. " total)")
    end
    table.insert(parts, "**Project files:** " .. table.concat(entries, ", "))
  end

  table.insert(parts, "")

  -- README.md (check common casings)
  local readme_names = { "README.md", "readme.md", "Readme.md", "README.rst", "README.txt", "README" }
  for _, name in ipairs(readme_names) do
    local content = read_file(root .. "/" .. name, 200)
    if content then
      table.insert(parts, "### " .. name)
      table.insert(parts, content)
      table.insert(parts, "")
      break
    end
  end

  -- AGENTS.md (common casings)
  local agents_names = { "AGENTS.md", "agents.md", "Agents.md", ".agents.md", "CLAUDE.md", "claude.md", "COPILOT.md" }
  for _, name in ipairs(agents_names) do
    local content = read_file(root .. "/" .. name, 200)
    if content then
      table.insert(parts, "### " .. name)
      table.insert(parts, content)
      table.insert(parts, "")
      break
    end
  end

  -- Only return if we have more than just the directory info
  if #parts <= 3 then return nil end
  return table.concat(parts, "\n")
end

return M
