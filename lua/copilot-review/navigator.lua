local review = require("copilot-review.review")

local M = {}

local NAVIGATED_EVENT = "CopilotReviewNavigated"
local highlight_ns = vim.api.nvim_create_namespace("copilot-review-current-hunk")

---@param event string
---@param data table|nil
local function emit(event, data)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = event,
      modeline = false,
      data = data,
    })
  end)
end

---@return CopilotReview.ReviewState|nil
local function get_active_state()
  local state = review.get_state()
  if not state or #state.files == 0 then
    vim.notify("CopilotReview: no active review", vim.log.levels.WARN)
    return nil
  end

  return state
end

---@param file CopilotReview.FileChange
---@return string
local function resolve_filename(file)
  return vim.fn.fnamemodify(file.filename, ":p")
end

---@param bufnr number
---@param hunk CopilotReview.Hunk
local function highlight_hunk(bufnr, hunk)
  vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)

  local start_line = hunk.new_start > 0 and hunk.new_start or hunk.old_start
  local line_count = math.max(hunk.new_count, hunk.old_count, 1)
  local end_line = start_line + line_count - 1

  for line = start_line - 1, end_line - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, highlight_ns, line, 0, {
      line_hl_group = "Visual",
      priority = 200,
    })
  end

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
    end
  end, 1200)
end

---@param action string
local function finish_navigation(action)
  emit(NAVIGATED_EVENT, {
    action = action,
    state = review.get_state(),
  })
end

function M.jump_to_current()
  local state = get_active_state()
  if not state then
    return
  end

  local file = review.get_current_file()
  local hunk = review.get_current_hunk()
  if not file or not hunk then
    vim.notify("CopilotReview: no current hunk", vim.log.levels.WARN)
    return
  end

  local filename = resolve_filename(file)
  vim.cmd.edit(vim.fn.fnameescape(filename))

  local bufnr = vim.api.nvim_get_current_buf()
  file.bufnr = bufnr

  local target_line = hunk.new_start > 0 and hunk.new_start or hunk.old_start
  target_line = math.max(target_line, 1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  target_line = math.min(target_line, math.max(line_count, 1))

  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd.normal({ args = { "zz" }, bang = true })

  highlight_hunk(bufnr, hunk)
end

function M.next_hunk()
  local state = get_active_state()
  if not state then
    return
  end

  local file = review.get_current_file()
  if not file then
    vim.notify("CopilotReview: no current file", vim.log.levels.WARN)
    return
  end

  if state.current_hunk < #file.hunks then
    state.current_hunk = state.current_hunk + 1
  elseif state.current_file < #state.files then
    state.current_file = state.current_file + 1
    state.current_hunk = 1
  else
    vim.notify("CopilotReview: already at last hunk", vim.log.levels.INFO)
    return
  end

  M.jump_to_current()
  finish_navigation("next_hunk")
end

function M.prev_hunk()
  local state = get_active_state()
  if not state then
    return
  end

  if state.current_hunk > 1 then
    state.current_hunk = state.current_hunk - 1
  elseif state.current_file > 1 then
    state.current_file = state.current_file - 1
    state.current_hunk = #state.files[state.current_file].hunks
  else
    vim.notify("CopilotReview: already at first hunk", vim.log.levels.INFO)
    return
  end

  M.jump_to_current()
  finish_navigation("prev_hunk")
end

function M.next_file()
  local state = get_active_state()
  if not state then
    return
  end

  if state.current_file >= #state.files then
    vim.notify("CopilotReview: already at last file", vim.log.levels.INFO)
    return
  end

  state.current_file = state.current_file + 1
  state.current_hunk = 1

  M.jump_to_current()
  finish_navigation("next_file")
end

function M.prev_file()
  local state = get_active_state()
  if not state then
    return
  end

  if state.current_file <= 1 then
    vim.notify("CopilotReview: already at first file", vim.log.levels.INFO)
    return
  end

  state.current_file = state.current_file - 1
  state.current_hunk = 1

  M.jump_to_current()
  finish_navigation("prev_file")
end

---@return string
function M.get_position_string()
  local state = review.get_state()
  local file = review.get_current_file()

  if not state or not file or #state.files == 0 then
    return "No active review"
  end

  local name = vim.fn.fnamemodify(file.filename, ":t")
  return string.format(
    "Hunk %d/%d in file %d/%d (%s)",
    state.current_hunk,
    #file.hunks,
    state.current_file,
    #state.files,
    name
  )
end

return M
