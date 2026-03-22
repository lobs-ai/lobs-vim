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

return M
