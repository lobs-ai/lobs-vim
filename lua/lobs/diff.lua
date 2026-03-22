-- lobs.nvim — diff display, review, and application
local M = {}

--- Pending diff proposals from the agent
M._proposals = {}

--- Show a diff proposal from the agent for user review
---@param msg table The diff.propose message
---@param on_resolve function(accepted: boolean) Called when user accepts/rejects
function M.show_proposal(msg, on_resolve)
  local proposal = {
    id = msg.diffId,
    file = msg.file,
    hunks = msg.hunks,
    on_resolve = on_resolve,
  }

  table.insert(M._proposals, proposal)

  -- Open the file if not already open
  local abs_path = vim.fn.fnamemodify(msg.file, ":p")
  local buf = M._find_or_open_buffer(abs_path)

  if not buf then
    vim.notify("Lobs: couldn't open " .. msg.file .. " for diff", vim.log.levels.ERROR)
    on_resolve(false)
    return
  end

  -- Show inline diff highlights
  M._highlight_hunks(buf, msg.hunks, msg.diffId)

  -- Notify user
  vim.notify(
    string.format("Lobs proposes changes to %s (%d hunk(s)). Use :LobsAcceptAll or :LobsRejectAll", 
      vim.fn.fnamemodify(msg.file, ":."), #msg.hunks),
    vim.log.levels.INFO
  )
end

--- Find an existing buffer or open the file
---@param path string Absolute path
---@return number|nil Buffer number
function M._find_or_open_buffer(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end

  -- Open the file
  local ok = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if ok then
    return vim.api.nvim_get_current_buf()
  end
  return nil
end

--- Highlight hunks in a buffer for review
---@param buf number
---@param hunks table[]
---@param diff_id string
function M._highlight_hunks(buf, hunks, diff_id)
  local ns = vim.api.nvim_create_namespace("lobs_diff_" .. diff_id)

  for _, hunk in ipairs(hunks) do
    local start_line = hunk.startLine - 1 -- 0-indexed

    -- Highlight the affected lines
    for i = start_line, (hunk.endLine or hunk.startLine) - 1 do
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, "DiffDelete", i, 0, -1)
    end

    -- Show replacement as virtual text
    if hunk.replacement then
      local replacement_lines = vim.split(hunk.replacement, "\n")
      local virt_lines = {}
      for _, line in ipairs(replacement_lines) do
        table.insert(virt_lines, { { line, "DiffAdd" } })
      end

      pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line, 0, {
        virt_lines_above = false,
        virt_lines = virt_lines,
      })
    end
  end
end

--- Accept all pending proposals
function M.accept_all()
  if #M._proposals == 0 then
    vim.notify("No pending Lobs changes", vim.log.levels.INFO)
    return
  end

  local count = #M._proposals
  for _, proposal in ipairs(M._proposals) do
    -- Apply the hunks
    M._apply_hunks(proposal.file, proposal.hunks)

    -- Clear highlights
    local ns = vim.api.nvim_create_namespace("lobs_diff_" .. proposal.id)
    local buf = M._find_or_open_buffer(vim.fn.fnamemodify(proposal.file, ":p"))
    if buf then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end

    -- Notify server
    if proposal.on_resolve then
      proposal.on_resolve(true)
    end
  end

  M._proposals = {}
  vim.notify(string.format("Accepted %d change(s)", count), vim.log.levels.INFO)
end

--- Reject all pending proposals
function M.reject_all()
  if #M._proposals == 0 then
    vim.notify("No pending Lobs changes", vim.log.levels.INFO)
    return
  end

  local count = #M._proposals
  for _, proposal in ipairs(M._proposals) do
    -- Clear highlights
    local ns = vim.api.nvim_create_namespace("lobs_diff_" .. proposal.id)
    local buf = M._find_or_open_buffer(vim.fn.fnamemodify(proposal.file, ":p"))
    if buf then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end

    -- Notify server
    if proposal.on_resolve then
      proposal.on_resolve(false)
    end
  end

  M._proposals = {}
  vim.notify(string.format("Rejected %d change(s)", count), vim.log.levels.INFO)
end

--- Apply hunks to a file
---@param file string
---@param hunks table[]
function M._apply_hunks(file, hunks)
  local abs_path = vim.fn.fnamemodify(file, ":p")
  local lines = vim.fn.readfile(abs_path)

  -- Apply hunks in reverse order (bottom-up) to preserve line numbers
  table.sort(hunks, function(a, b) return a.startLine > b.startLine end)

  for _, hunk in ipairs(hunks) do
    local start = hunk.startLine
    local stop = hunk.endLine or hunk.startLine
    local replacement = hunk.replacement and vim.split(hunk.replacement, "\n") or {}

    -- Remove old lines and insert new ones
    for _ = start, stop do
      table.remove(lines, start)
    end
    for i, line in ipairs(replacement) do
      table.insert(lines, start + i - 1, line)
    end
  end

  vim.fn.writefile(lines, abs_path)

  -- Reload buffer
  local buf = M._find_or_open_buffer(abs_path)
  if buf then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("edit!")
    end)
  end
end

return M
