local config = require("copilot-review.config")

---@class CopilotReview.Actions
local M = {}

---@param message string
---@param level integer
local function notify(message, level)
  vim.notify(message, level)
end

---@return CopilotReview.Config.Icons
local function get_icons()
  return vim.tbl_deep_extend("force", {}, config.defaults.icons or {}, config.options.icons or {})
end

---@param path string
---@return string
local function normalize_path(path)
  if path == nil or path == "" then
    return ""
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  local normalized = vim.fs and vim.fs.normalize(absolute) or absolute
  return normalized:gsub("/", "\\"):lower()
end

---@param filename string
---@return string
local function display_name(filename)
  return vim.fn.fnamemodify(filename, ":t")
end

---@return table|nil, table|nil
local function get_review_state()
  local ok, review = pcall(require, "copilot-review.review")
  if not ok then
    notify("CopilotReview: review state is unavailable", vim.log.levels.ERROR)
    return nil, nil
  end

  local state = type(review.get_state) == "function" and review.get_state() or review.state or review._state
  if type(state) ~= "table" then
    notify("CopilotReview: invalid review state", vim.log.levels.ERROR)
    return review, nil
  end

  return review, state
end

---@return table|nil
local function get_navigator()
  local ok, navigator = pcall(require, "copilot-review.navigator")
  if not ok then
    return nil
  end

  return navigator
end

---@param state table
---@return CopilotReview.FileChange[]
local function get_files(state)
  return state.files or state.file_changes or state.changes or {}
end

---@param state table
---@param files CopilotReview.FileChange[]
---@return integer
local function get_current_file_index(state, files)
  local candidates = {
    state.current_file_idx,
    state.current_file_index,
    state.file_index,
    state.current_file,
    state.current and state.current.file,
  }

  for _, candidate in ipairs(candidates) do
    if type(candidate) == "number" and files[candidate] then
      return candidate
    end

    if type(candidate) == "table" then
      for index, file_change in ipairs(files) do
        if file_change == candidate then
          return index
        end
      end
    end

    if type(candidate) == "string" then
      local target = normalize_path(candidate)
      for index, file_change in ipairs(files) do
        if normalize_path(file_change.filename) == target then
          return index
        end
      end
    end
  end

  return files[1] and 1 or 0
end

---@param state table
---@param index integer
local function set_current_file_index(state, index)
  state.current_file_idx = index
  state.current_file_index = index
  state.file_index = index
  state.current_file = index
  state.current = state.current or {}
  state.current.file = index
end

---@param state table
---@param index integer
local function set_current_hunk_index(state, index)
  state.current_hunk_idx = index
  state.current_hunk_index = index
  state.hunk_index = index
  state.current_hunk = index
  state.current = state.current or {}
  state.current.hunk = index
end

---@param file_change CopilotReview.FileChange
---@param hunk_index integer
---@param hunk CopilotReview.Hunk
local function set_file_selection(file_change, hunk_index, hunk)
  file_change.current_hunk_idx = hunk_index
  file_change.current_hunk_index = hunk_index
  file_change.current_hunk = hunk
end

---@param file_change CopilotReview.FileChange
---@return CopilotReview.Hunk[]
local function get_hunks(file_change)
  return file_change.hunks or {}
end

---@param hunk CopilotReview.Hunk
---@return boolean
local function is_pending(hunk)
  return (hunk.status or "pending") == "pending"
end

---@param file_change CopilotReview.FileChange
---@param state table
---@return integer, CopilotReview.Hunk|nil
local function get_current_hunk(file_change, state)
  local hunks = get_hunks(file_change)
  local candidates = {
    state.current_hunk_idx,
    state.current_hunk_index,
    state.hunk_index,
    state.current_hunk,
    state.current and state.current.hunk,
    file_change.current_hunk_idx,
    file_change.current_hunk_index,
    file_change.current_hunk,
  }

  for _, candidate in ipairs(candidates) do
    if type(candidate) == "number" and hunks[candidate] then
      return candidate, hunks[candidate]
    end

    if type(candidate) == "table" then
      for index, hunk in ipairs(hunks) do
        if hunk == candidate then
          return index, index > 0 and hunk or nil
        end
      end
    end
  end

  for index, hunk in ipairs(hunks) do
    if is_pending(hunk) then
      return index, hunk
    end
  end

  return 0, nil
end

---@param file_change CopilotReview.FileChange
---@param start_index integer
---@return integer, CopilotReview.Hunk|nil
local function find_pending_hunk(file_change, start_index)
  local hunks = get_hunks(file_change)
  for index = math.max(start_index, 1), #hunks do
    if is_pending(hunks[index]) then
      return index, hunks[index]
    end
  end

  return 0, nil
end

---@param state table
---@param preferred_file integer
---@param preferred_hunk integer
---@return boolean
local function advance_to_next_pending(state, preferred_file, preferred_hunk)
  local files = get_files(state)
  if #files == 0 then
    return false
  end

  for file_index = math.max(preferred_file, 1), #files do
    local hunk_start = file_index == preferred_file and preferred_hunk or 1
    local hunk_index = find_pending_hunk(files[file_index], hunk_start)
    if hunk_index > 0 then
      set_current_file_index(state, file_index)
      set_current_hunk_index(state, hunk_index)
      set_file_selection(files[file_index], hunk_index, get_hunks(files[file_index])[hunk_index])

      local navigator = get_navigator()
      if navigator then
        if type(navigator.goto_hunk) == "function" then
          navigator.goto_hunk(file_index, hunk_index)
        elseif type(navigator.focus_current) == "function" then
          navigator.focus_current()
        elseif type(navigator.refresh) == "function" then
          navigator.refresh()
        end
      end

      return true
    end
  end

  for file_index = 1, preferred_file - 1 do
    local hunk_index = find_pending_hunk(files[file_index], 1)
    if hunk_index > 0 then
      set_current_file_index(state, file_index)
      set_current_hunk_index(state, hunk_index)
      set_file_selection(files[file_index], hunk_index, get_hunks(files[file_index])[hunk_index])

      local navigator = get_navigator()
      if navigator then
        if type(navigator.goto_hunk) == "function" then
          navigator.goto_hunk(file_index, hunk_index)
        elseif type(navigator.focus_current) == "function" then
          navigator.focus_current()
        elseif type(navigator.refresh) == "function" then
          navigator.refresh()
        end
      end

      return true
    end
  end

  return false
end

---@param count integer
---@param noun string
---@return string
local function pluralize(count, noun)
  return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

---@param state table
---@return integer, integer, integer
local function summarize(state)
  local accepted, declined, pending = 0, 0, 0

  for _, file_change in ipairs(get_files(state)) do
    for _, hunk in ipairs(get_hunks(file_change)) do
      if hunk.status == "accepted" then
        accepted = accepted + 1
      elseif hunk.status == "declined" then
        declined = declined + 1
      else
        pending = pending + 1
      end
    end
  end

  return accepted, declined, pending
end

---@param state table
local function notify_summary(state)
  local icons = get_icons()
  local accepted, declined, pending = summarize(state)
  local level = pending == 0 and vim.log.levels.INFO or vim.log.levels.WARN
  local prefix = pending == 0 and icons.complete or icons.pending
  notify(
    string.format(
      "%s Review summary: %s accepted, %s declined, %s pending",
      prefix,
      pluralize(accepted, "hunk"),
      pluralize(declined, "hunk"),
      pluralize(pending, "hunk")
    ),
    level
  )
end

---@param file_change CopilotReview.FileChange
---@param applied_hunk CopilotReview.Hunk
local function shift_following_hunks(file_change, applied_hunk)
  local delta = (applied_hunk.new_count or #(applied_hunk.new_lines or {})) - (applied_hunk.old_count or #(applied_hunk.old_lines or {}))
  if delta == 0 then
    return
  end

  local applied_start = applied_hunk.old_start or 1
  for _, hunk in ipairs(get_hunks(file_change)) do
    if hunk ~= applied_hunk and (hunk.old_start or 0) > applied_start then
      hunk.old_start = (hunk.old_start or 0) + delta
    end
  end
end

---@param lines string[]
---@param slice string[]
---@param start_index integer
---@return boolean
local function matches_at(lines, slice, start_index)
  if #slice == 0 then
    return true
  end

  if start_index < 0 or start_index + #slice > #lines then
    return false
  end

  for offset, value in ipairs(slice) do
    if lines[start_index + offset] ~= value then
      return false
    end
  end

  return true
end

---@param lines string[]
---@param hunk CopilotReview.Hunk
---@return integer
local function resolve_start_index(lines, hunk)
  local old_count = hunk.old_count or #(hunk.old_lines or {})
  local expected = old_count == 0 and math.max((hunk.old_start or 0), 0) or math.max((hunk.old_start or 1) - 1, 0)
  local old_lines = hunk.old_lines or {}

  if matches_at(lines, old_lines, expected) then
    return expected
  end

  local min_index = math.max(0, expected - 200)
  local max_index = math.max(0, math.min(#lines, expected + 200))

  for index = min_index, max_index do
    if matches_at(lines, old_lines, index) then
      return index
    end
  end

  return expected
end

---@param filename string
---@return integer
function M._get_buffer(filename)
  local target = normalize_path(filename)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and normalize_path(name) == target then
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      return bufnr
    end
  end

  local bufnr = vim.fn.bufadd(filename)
  vim.fn.bufload(bufnr)
  return bufnr
end

---@param hunk CopilotReview.Hunk
---@param bufnr integer
function M._apply_hunk_to_buffer(hunk, bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local old_count = hunk.old_count or #(hunk.old_lines or {})
  local start_index = resolve_start_index(lines, hunk)
  local end_index = start_index + old_count
  local replacement = vim.deepcopy(hunk.new_lines or {})

  vim.api.nvim_buf_set_lines(bufnr, start_index, end_index, false, replacement)
end

---@return integer|nil, CopilotReview.FileChange|nil, integer|nil, CopilotReview.Hunk|nil, table|nil
local function get_current_selection()
  local _, state = get_review_state()
  if not state then
    return nil, nil, nil, nil, nil
  end

  local files = get_files(state)
  if #files == 0 then
    notify("CopilotReview: no pending file changes", vim.log.levels.WARN)
    return nil, nil, nil, nil, state
  end

  local file_index = get_current_file_index(state, files)
  local file_change = files[file_index]
  if not file_change then
    notify("CopilotReview: could not resolve current file", vim.log.levels.WARN)
    return nil, nil, nil, nil, state
  end

  local hunk_index, hunk = get_current_hunk(file_change, state)
  if hunk and not is_pending(hunk) then
    hunk_index, hunk = find_pending_hunk(file_change, hunk_index + 1)
  end

  if not hunk then
    for next_file = file_index + 1, #files do
      hunk_index, hunk = find_pending_hunk(files[next_file], 1)
      if hunk then
        file_index = next_file
        file_change = files[next_file]
        break
      end
    end
  end

  if not hunk then
    for next_file = 1, file_index - 1 do
      hunk_index, hunk = find_pending_hunk(files[next_file], 1)
      if hunk then
        file_index = next_file
        file_change = files[next_file]
        break
      end
    end
  end

  if not hunk then
    notify_summary(state)
    return nil, nil, nil, nil, state
  end

  set_current_file_index(state, file_index)
  set_current_hunk_index(state, hunk_index)
  set_file_selection(file_change, hunk_index, hunk)
  return file_index, file_change, hunk_index, hunk, state
end

function M.accept_hunk()
  local file_index, file_change, hunk_index, hunk, state = get_current_selection()
  if not (file_index and file_change and hunk_index and hunk and state) then
    return
  end

  local bufnr = file_change.bufnr and vim.api.nvim_buf_is_valid(file_change.bufnr) and file_change.bufnr or M._get_buffer(file_change.filename)
  file_change.bufnr = bufnr

  M._apply_hunk_to_buffer(hunk, bufnr)
  hunk.status = "accepted"
  shift_following_hunks(file_change, hunk)

  local icons = get_icons()
  notify(
    string.format("%s Accepted hunk %d/%d in %s", icons.accepted, hunk_index, #get_hunks(file_change), display_name(file_change.filename)),
    vim.log.levels.INFO
  )

  if not advance_to_next_pending(state, file_index, hunk_index + 1) then
    notify_summary(state)
  end
end

function M.decline_hunk()
  local file_index, file_change, hunk_index, hunk, state = get_current_selection()
  if not (file_index and file_change and hunk_index and hunk and state) then
    return
  end

  hunk.status = "declined"

  local icons = get_icons()
  notify(
    string.format("%s Declined hunk %d/%d in %s", icons.declined, hunk_index, #get_hunks(file_change), display_name(file_change.filename)),
    vim.log.levels.INFO
  )

  if not advance_to_next_pending(state, file_index, hunk_index + 1) then
    notify_summary(state)
  end
end

function M.accept_file()
  local file_index, file_change, _, _, state = get_current_selection()
  if not (file_index and file_change and state) then
    return
  end

  local pending = {}
  for index, hunk in ipairs(get_hunks(file_change)) do
    if is_pending(hunk) then
      table.insert(pending, { index = index, hunk = hunk })
    end
  end

  if #pending == 0 then
    notify("CopilotReview: no pending hunks in " .. display_name(file_change.filename), vim.log.levels.WARN)
    if not advance_to_next_pending(state, file_index + 1, 1) then
      notify_summary(state)
    end
    return
  end

  table.sort(pending, function(a, b)
    if a.hunk.old_start == b.hunk.old_start then
      return a.index > b.index
    end
    return (a.hunk.old_start or 0) > (b.hunk.old_start or 0)
  end)

  local bufnr = file_change.bufnr and vim.api.nvim_buf_is_valid(file_change.bufnr) and file_change.bufnr or M._get_buffer(file_change.filename)
  file_change.bufnr = bufnr

  for _, item in ipairs(pending) do
    M._apply_hunk_to_buffer(item.hunk, bufnr)
    item.hunk.status = "accepted"
  end

  local icons = get_icons()
  notify(
    string.format("%s Accepted all changes in %s (%s)", icons.accepted, display_name(file_change.filename), pluralize(#pending, "hunk")),
    vim.log.levels.INFO
  )

  if not advance_to_next_pending(state, file_index + 1, 1) then
    notify_summary(state)
  end
end

function M.decline_file()
  local file_index, file_change, _, _, state = get_current_selection()
  if not (file_index and file_change and state) then
    return
  end

  local declined = 0
  for _, hunk in ipairs(get_hunks(file_change)) do
    if is_pending(hunk) then
      hunk.status = "declined"
      declined = declined + 1
    end
  end

  local icons = get_icons()
  notify(
    string.format("%s Declined all changes in %s (%s)", icons.declined, display_name(file_change.filename), pluralize(declined, "hunk")),
    vim.log.levels.INFO
  )

  if not advance_to_next_pending(state, file_index + 1, 1) then
    notify_summary(state)
  end
end

function M.accept_all()
  local _, state = get_review_state()
  if not state then
    return
  end

  local total_accepted = 0
  local touched_files = 0

  for _, file_change in ipairs(get_files(state)) do
    local pending = {}
    for index, hunk in ipairs(get_hunks(file_change)) do
      if is_pending(hunk) then
        table.insert(pending, { index = index, hunk = hunk })
      end
    end

    if #pending > 0 then
      touched_files = touched_files + 1
      table.sort(pending, function(a, b)
        if a.hunk.old_start == b.hunk.old_start then
          return a.index > b.index
        end
        return (a.hunk.old_start or 0) > (b.hunk.old_start or 0)
      end)

      local bufnr = file_change.bufnr and vim.api.nvim_buf_is_valid(file_change.bufnr) and file_change.bufnr or M._get_buffer(file_change.filename)
      file_change.bufnr = bufnr

      for _, item in ipairs(pending) do
        M._apply_hunk_to_buffer(item.hunk, bufnr)
        item.hunk.status = "accepted"
        total_accepted = total_accepted + 1
      end
    end
  end

  local icons = get_icons()
  notify(
    string.format("%s Accepted %s across %s", icons.accepted, pluralize(total_accepted, "hunk"), pluralize(touched_files, "file")),
    vim.log.levels.INFO
  )

  notify_summary(state)
end

return M
