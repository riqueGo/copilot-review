---@alias CopilotReview.HunkStatus "pending"|"accepted"|"declined"

---@class CopilotReview.Hunk
---@field old_start number Start line in original file
---@field old_count number Number of lines in original
---@field new_start number Start line in new file
---@field new_count number Number of lines in new
---@field old_lines string[] Original lines for the hunk
---@field new_lines string[] New lines for the hunk
---@field status CopilotReview.HunkStatus

---@class CopilotReview.FileChange
---@field filename string Absolute or relative file path
---@field filetype string File type (lua, python, etc.)
---@field blocks table[] Original CopilotChat blocks
---@field hunks CopilotReview.Hunk[] Parsed individual hunks
---@field bufnr number|nil Buffer number if file is open

---@class CopilotReview.ReviewState
---@field files CopilotReview.FileChange[] Ordered list of files with changes
---@field current_file number Index into files (1-based)
---@field current_hunk number Index into current file's hunks (1-based)
---@field total_hunks number Total hunks across all files
---@field timestamp number When the review was created

local M = {}

---@type CopilotReview.ReviewState|nil
M._state = nil

local REVIEW_UPDATED_EVENT = "CopilotReviewUpdated"
local VALID_HUNK_STATUS = {
  pending = true,
  accepted = true,
  declined = true,
}

---@param path string
---@return string
local function normalize_path(path)
  if path == nil or path == "" then
    return ""
  end

  return vim.fn.fnamemodify(path, ":p")
end

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

---@param path string
---@return number|nil
local function find_open_buffer(path)
  local absolute = normalize_path(path)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and normalize_path(name) == absolute then
        return bufnr
      end
    end
  end

  return nil
end

---@param path string
---@return string[], number|nil
local function read_original_lines(path)
  local bufnr = find_open_buffer(path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
  end

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path), nil
  end

  return {}, nil
end

---@param lines string[]
---@return string
local function join_lines(lines)
  if #lines == 0 then
    return ""
  end

  return table.concat(lines, "\n") .. "\n"
end

---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end

  return lines
end

---@param count string
---@return number
local function parse_count(count)
  if count == nil or count == "" then
    return 1
  end

  return tonumber(count) or 1
end

---@param filename string
---@param fallback string|nil
---@return string
local function detect_filetype(filename, fallback)
  if fallback and fallback ~= "" then
    return fallback
  end

  return vim.filetype.match({ filename = filename }) or vim.fn.fnamemodify(filename, ":e")
end

---@param original_lines string[]
---@param patched_text string
---@return string
local function build_unified_diff(original_lines, patched_text)
  return vim.diff(join_lines(original_lines), patched_text or "", {
    result_type = "unified",
    ctxlen = 3,
  })
end

---@param diff_text string
---@return CopilotReview.Hunk[]
function M.compute_hunks_from_diff(diff_text)
  local hunks = {}
  local current = nil

  for _, line in ipairs(split_lines(diff_text or "")) do
    local old_start, old_count, new_start, new_count =
      line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@.*$")

    if old_start then
      if current then
        table.insert(hunks, current)
      end

      current = {
        old_start = tonumber(old_start) or 0,
        old_count = parse_count(old_count),
        new_start = tonumber(new_start) or 0,
        new_count = parse_count(new_count),
        old_lines = {},
        new_lines = {},
        status = "pending",
      }
    elseif current then
      local prefix = line:sub(1, 1)
      local content = line:sub(2)

      if prefix == " " then
        table.insert(current.old_lines, content)
        table.insert(current.new_lines, content)
      elseif prefix == "-" then
        table.insert(current.old_lines, content)
      elseif prefix == "+" then
        table.insert(current.new_lines, content)
      elseif prefix == "\\" then
        -- Ignore "\ No newline at end of file".
      end
    end
  end

  if current then
    table.insert(hunks, current)
  end

  return hunks
end

---@param changes table[]|nil
---@return CopilotReview.ReviewState
function M.create_review(changes)
  local files = {}
  local total_hunks = 0

  for _, change in ipairs(changes or {}) do
    local filename = change.filename or ""
    local path = normalize_path(filename)
    local original_lines, bufnr = read_original_lines(path)
    local hunks = {}

    for _, block in ipairs(change.blocks or {}) do
      local diff_text

      if block.filetype == "diff" then
        diff_text = block.content or ""
      else
        diff_text = build_unified_diff(original_lines, block.content or "")
      end

      vim.list_extend(hunks, M.compute_hunks_from_diff(diff_text))
    end

    if #hunks > 0 then
      total_hunks = total_hunks + #hunks
      table.insert(files, {
        filename = filename ~= "" and filename or path,
        filetype = detect_filetype(path, change.filetype),
        blocks = change.blocks or {},
        hunks = hunks,
        bufnr = bufnr,
      })
    end
  end

  M._state = {
    files = files,
    current_file = #files > 0 and 1 or 0,
    current_hunk = #files > 0 and 1 or 0,
    total_hunks = total_hunks,
    timestamp = os.time(),
  }

  emit(REVIEW_UPDATED_EVENT, {
    action = "create",
    state = M._state,
  })

  return M._state
end

---@return CopilotReview.ReviewState|nil
function M.get_state()
  return M._state
end

function M.clear()
  M._state = nil
  emit(REVIEW_UPDATED_EVENT, { action = "clear" })
end

---@return CopilotReview.FileChange|nil
function M.get_current_file()
  local state = M._state
  if not state or state.current_file < 1 then
    return nil
  end

  return state.files[state.current_file]
end

---@return CopilotReview.Hunk|nil
function M.get_current_hunk()
  local file = M.get_current_file()
  local state = M._state
  if not file or not state or state.current_hunk < 1 then
    return nil
  end

  return file.hunks[state.current_hunk]
end

---@param status CopilotReview.HunkStatus
function M.mark_hunk(status)
  local hunk = M.get_current_hunk()
  if not hunk then
    return
  end

  if not VALID_HUNK_STATUS[status] then
    vim.notify("CopilotReview: invalid hunk status '" .. tostring(status) .. "'", vim.log.levels.ERROR)
    return
  end

  hunk.status = status
  emit(REVIEW_UPDATED_EVENT, {
    action = "mark",
    status = status,
    state = M._state,
  })
end

---@return {total: number, accepted: number, declined: number, pending: number, files_count: number}
function M.get_summary()
  local summary = {
    total = 0,
    accepted = 0,
    declined = 0,
    pending = 0,
    files_count = 0,
  }

  local state = M._state
  if not state then
    return summary
  end

  summary.files_count = #state.files

  for _, file in ipairs(state.files) do
    for _, hunk in ipairs(file.hunks) do
      summary.total = summary.total + 1

      if hunk.status == "accepted" then
        summary.accepted = summary.accepted + 1
      elseif hunk.status == "declined" then
        summary.declined = summary.declined + 1
      else
        summary.pending = summary.pending + 1
      end
    end
  end

  return summary
end

return M
