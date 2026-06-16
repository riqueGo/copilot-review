local Layout = require("nui.layout")
local Popup = require("nui.popup")
local Split = require("nui.split")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local M = {}

M._layout = nil
M._left_popup = nil
M._right_popup = nil
M._status_popup = nil

local ns = vim.api.nvim_create_namespace("copilot-review.review-panel")

local function safe_require(name)
  local ok, module = pcall(require, name)
  if ok then
    return module
  end
  return nil
end

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(value)
  end
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
  end
  return true
end

local function to_lines(value)
  if type(value) == "string" then
    return vim.split(value, "\n", { plain = true })
  end

  if is_list(value) then
    local lines = {}
    for _, line in ipairs(value) do
      table.insert(lines, tostring(line))
    end
    return lines
  end

  return {}
end

local function safe_options()
  local config = safe_require("copilot-review.config")
  return (config and config.options) or {}
end

local function get_review_module()
  return safe_require("copilot-review.review")
end

local function get_review_state()
  local review = get_review_module()
  if not review then
    return nil
  end

  if type(review.get_state) == "function" then
    local ok, state = pcall(review.get_state)
    if ok and type(state) == "table" then
      return state
    end
  end

  return review.state or review._state or review
end

local function get_files(state)
  if type(state) ~= "table" then
    return {}
  end
  return state.files or state.file_changes or state.changes or {}
end

local function get_file_index(state)
  if type(state) ~= "table" then
    return 1
  end
  return tonumber(state.current_file_idx or state.file_idx or state.file_index or 1) or 1
end

local function get_hunk_index(state)
  if type(state) ~= "table" then
    return 1
  end
  return tonumber(state.current_hunk_idx or state.hunk_idx or state.hunk_index or 1) or 1
end

local function get_file_label(file_change)
  return file_change.path or file_change.file or file_change.filename or file_change.name or "unknown"
end

local function get_hunks(file_change)
  if type(file_change) ~= "table" then
    return {}
  end
  return file_change.hunks or file_change.changes or file_change.diff_hunks or {}
end

local function highlight_lines(bufnr, group, start_line, end_line)
  for line = start_line, end_line do
    vim.api.nvim_buf_add_highlight(bufnr, ns, group, line, 0, -1)
  end
end

local function normalize_hunk(file_change, hunk)
  local left, right, left_groups, right_groups = {}, {}, {}, {}

  local function add_pair(left_text, right_text, left_group, right_group)
    table.insert(left, left_text or "")
    table.insert(right, right_text or "")

    local line_index = #left - 1
    if left_group then
      table.insert(left_groups, { group = left_group, line = line_index })
    end
    if right_group then
      table.insert(right_groups, { group = right_group, line = line_index })
    end
  end

  if type(hunk) ~= "table" then
    local fallback = "No hunk details available"
    return { fallback }, { fallback }, {}, {}
  end

  local old_lines = to_lines(hunk.old_lines or hunk.original_lines or hunk.before or hunk.old or hunk.removed)
  local new_lines = to_lines(hunk.new_lines or hunk.modified_lines or hunk.after or hunk.new or hunk.added)
  if #old_lines > 0 or #new_lines > 0 then
    local max_lines = math.max(#old_lines, #new_lines)
    for index = 1, max_lines do
      local old_line = old_lines[index] or ""
      local new_line = new_lines[index] or ""
      local left_group = old_line ~= "" and (new_line == "" and "DiffDelete" or "DiffChange") or nil
      local right_group = new_line ~= "" and (old_line == "" and "DiffAdd" or "DiffChange") or nil
      add_pair(old_line, new_line, left_group, right_group)
    end
    return left, right, left_groups, right_groups
  end

  if is_list(hunk.lines) then
    for _, line in ipairs(hunk.lines) do
      local kind = tostring(line.type or line.kind or line.operation or ""):lower()
      local text = tostring(line.text or line.line or line.content or "")

      if kind == "delete" or kind == "removed" or kind == "remove" or kind == "-" then
        add_pair(text, "", "DiffDelete", "DiffChange")
      elseif kind == "add" or kind == "added" or kind == "+" then
        add_pair("", text, "DiffChange", "DiffAdd")
      else
        add_pair(text, text, nil, nil)
      end
    end
    return left, right, left_groups, right_groups
  end

  local original = to_lines(file_change.original_content or file_change.old_content)
  local modified = to_lines(file_change.modified_content or file_change.new_content)
  if #original > 0 or #modified > 0 then
    local max_lines = math.max(#original, #modified)
    for index = 1, max_lines do
      add_pair(original[index] or "", modified[index] or "", nil, nil)
    end
    return left, right, left_groups, right_groups
  end

  local fallback = "No diff content available"
  return { fallback }, { fallback }, {}, {}
end

local function run_review_action(actions)
  for _, action in ipairs(actions) do
    local module = safe_require(action[1])
    if module and type(module[action[2]]) == "function" then
      local ok = pcall(module[action[2]])
      if ok then
        return true
      end
    end
  end
  return false
end

local function panel_geometry()
  local options = safe_options()
  local ui = options.ui or {}
  local cfg = ui.review_panel or {}
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight

  local function resolve_size(value, max_value)
    if type(value) == "number" then
      if value > 0 and value <= 1 then
        return math.max(20, math.floor(max_value * value))
      end
      return math.min(max_value, math.max(20, math.floor(value)))
    end
    return math.max(20, math.floor(max_value * 0.8))
  end

  local width = resolve_size(cfg.width, math.max(1, columns - 4))
  local height = math.max(10, lines - 4)
  local position = cfg.position or "right"
  local row = 1
  local col = 1

  if position == "right" then
    col = math.max(1, columns - width - 1)
  elseif position == "left" then
    col = 1
  elseif position == "top" then
    width = math.max(20, columns - 2)
    height = math.max(10, math.floor(lines * 0.5))
    row = 1
    col = 1
  elseif position == "bottom" then
    width = math.max(20, columns - 2)
    height = math.max(10, math.floor(lines * 0.5))
    row = math.max(1, lines - height - 1)
    col = 1
  end

  return {
    relative = "editor",
    position = { row = row, col = col },
    size = { width = math.max(20, width), height = math.max(10, height) },
  }
end

function M.open()
  if M._layout then
    M.refresh()
    return
  end

  local options = safe_options()
  local ui = options.ui or {}
  local cfg = ui.review_panel or {}
  local geometry = panel_geometry()

  M._left_popup = Popup({
    border = {
      style = cfg.border or "rounded",
      text = { top = " Original ", top_align = "center" },
    },
    win_options = {
      wrap = false,
      number = false,
      relativenumber = false,
      cursorline = false,
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
    enter = true,
    focusable = true,
  })

  M._right_popup = Popup({
    border = {
      style = cfg.border or "rounded",
      text = { top = " Modified ", top_align = "center" },
    },
    win_options = {
      wrap = false,
      number = false,
      relativenumber = false,
      cursorline = false,
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
    focusable = true,
  })

  M._status_popup = Popup({
    border = {
      style = cfg.border or "rounded",
    },
    win_options = {
      wrap = false,
      number = false,
      relativenumber = false,
      cursorline = false,
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
    focusable = false,
  })

  M._layout = Layout(
    {
      relative = geometry.relative,
      position = geometry.position,
      size = geometry.size,
    },
    Layout.Box({
      Layout.Box({
        Layout.Box(M._left_popup, { size = "50%" }),
        Layout.Box(M._right_popup, { size = "50%" }),
      }, { dir = "row", size = "100%" }),
      Layout.Box(M._status_popup, { size = 4 }),
    }, { dir = "col", size = "100%" })
  )

  M._layout:mount()
  M._setup_panel_keymaps(M._left_popup.bufnr)
  M._setup_panel_keymaps(M._right_popup.bufnr)
  M._setup_panel_keymaps(M._status_popup.bufnr)

  vim.api.nvim_set_current_win(M._left_popup.winid)
  M.refresh()
end

function M.close()
  if M._layout then
    pcall(M._layout.unmount, M._layout)
  end

  M._layout = nil
  M._left_popup = nil
  M._right_popup = nil
  M._status_popup = nil
end

function M.toggle()
  if M._layout then
    M.close()
  else
    M.open()
  end
end

function M.refresh()
  if not M._layout or not M._left_popup or not M._right_popup or not M._status_popup then
    return
  end

  local state = get_review_state()
  local files = get_files(state)
  local file_index = get_file_index(state)

  if not is_list(files) or #files == 0 then
    local message = { "No active review." }
    vim.api.nvim_buf_set_lines(M._left_popup.bufnr, 0, -1, false, message)
    vim.api.nvim_buf_set_lines(M._right_popup.bufnr, 0, -1, false, message)
    M._render_status_bar()
    return
  end

  file_index = math.min(math.max(file_index, 1), #files)
  local file_change = files[file_index]
  local hunks = get_hunks(file_change)
  local hunk_index = get_hunk_index(state)
  if not is_list(hunks) or #hunks == 0 then
    hunk_index = 1
  else
    hunk_index = math.min(math.max(hunk_index, 1), #hunks)
  end

  M._render_diff(file_change, hunk_index)
  M._render_status_bar()
end

function M._render_diff(file_change, hunk_idx)
  if not (M._left_popup and M._right_popup) then
    return
  end

  local hunks = get_hunks(file_change)
  local hunk = is_list(hunks) and hunks[hunk_idx] or nil
  local left_lines, right_lines, left_groups, right_groups = normalize_hunk(file_change or {}, hunk or {})

  vim.api.nvim_buf_clear_namespace(M._left_popup.bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(M._right_popup.bufnr, ns, 0, -1)
  vim.api.nvim_buf_set_lines(M._left_popup.bufnr, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(M._right_popup.bufnr, 0, -1, false, right_lines)

  if #left_lines > 0 then
    highlight_lines(M._left_popup.bufnr, "DiffText", 0, #left_lines - 1)
  end
  if #right_lines > 0 then
    highlight_lines(M._right_popup.bufnr, "DiffText", 0, #right_lines - 1)
  end

  for _, item in ipairs(left_groups) do
    vim.api.nvim_buf_add_highlight(M._left_popup.bufnr, ns, item.group, item.line, 0, -1)
  end
  for _, item in ipairs(right_groups) do
    vim.api.nvim_buf_add_highlight(M._right_popup.bufnr, ns, item.group, item.line, 0, -1)
  end

  local title = " " .. vim.fn.fnamemodify(get_file_label(file_change), ":t") .. " "
  M._left_popup.border:set_text("top", NuiText("Original" .. title, "Title"), "center")
  M._right_popup.border:set_text("top", NuiText("Modified" .. title, "Title"), "center")
end

function M._setup_panel_keymaps(bufnr)
  local keymap = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true, desc = desc })
  end

  keymap("a", function()
    if run_review_action({ { "copilot-review.actions", "accept_hunk" }, { "copilot-review.review", "accept_hunk" } }) then
      M.refresh()
    end
  end, "Accept hunk")

  keymap("d", function()
    if run_review_action({ { "copilot-review.actions", "decline_hunk" }, { "copilot-review.review", "decline_hunk" } }) then
      M.refresh()
    end
  end, "Decline hunk")

  keymap("A", function()
    if run_review_action({ { "copilot-review.actions", "accept_file" }, { "copilot-review.review", "accept_file" } }) then
      M.refresh()
    end
  end, "Accept file")

  keymap("D", function()
    if run_review_action({ { "copilot-review.actions", "decline_file" }, { "copilot-review.review", "decline_file" } }) then
      M.refresh()
    end
  end, "Decline file")

  keymap("n", function()
    if run_review_action({ { "copilot-review.navigator", "next_hunk" }, { "copilot-review.review", "next_hunk" } }) then
      M.refresh()
    end
  end, "Next hunk")

  keymap("]r", function()
    if run_review_action({ { "copilot-review.navigator", "next_hunk" }, { "copilot-review.review", "next_hunk" } }) then
      M.refresh()
    end
  end, "Next hunk")

  keymap("p", function()
    if run_review_action({ { "copilot-review.navigator", "prev_hunk" }, { "copilot-review.review", "prev_hunk" } }) then
      M.refresh()
    end
  end, "Previous hunk")

  keymap("[r", function()
    if run_review_action({ { "copilot-review.navigator", "prev_hunk" }, { "copilot-review.review", "prev_hunk" } }) then
      M.refresh()
    end
  end, "Previous hunk")

  keymap("N", function()
    if run_review_action({ { "copilot-review.navigator", "next_file" }, { "copilot-review.review", "next_file" } }) then
      M.refresh()
    end
  end, "Next file")

  keymap("]R", function()
    if run_review_action({ { "copilot-review.navigator", "next_file" }, { "copilot-review.review", "next_file" } }) then
      M.refresh()
    end
  end, "Next file")

  keymap("P", function()
    if run_review_action({ { "copilot-review.navigator", "prev_file" }, { "copilot-review.review", "prev_file" } }) then
      M.refresh()
    end
  end, "Previous file")

  keymap("[R", function()
    if run_review_action({ { "copilot-review.navigator", "prev_file" }, { "copilot-review.review", "prev_file" } }) then
      M.refresh()
    end
  end, "Previous file")

  keymap("y", function()
    if run_review_action({ { "copilot-review.actions", "accept_all" }, { "copilot-review.review", "accept_all" } }) then
      M.refresh()
    end
  end, "Accept all")

  keymap("q", function()
    M.close()
  end, "Close panel")
end

function M._render_status_bar()
  if not M._status_popup then
    return
  end

  local state = get_review_state()
  local files = get_files(state)
  local file_count = is_list(files) and #files or 0
  local file_index = math.min(math.max(get_file_index(state), 1), math.max(file_count, 1))
  local file_change = file_count > 0 and files[file_index] or nil
  local hunks = get_hunks(file_change)
  local hunk_count = is_list(hunks) and #hunks or 0
  local hunk_index = math.min(math.max(get_hunk_index(state), 1), math.max(hunk_count, 1))
  local file_name = file_change and vim.fn.fnamemodify(get_file_label(file_change), ":t") or "no file"

  local text = ("Hunk %d/%d in file %d/%d (%s) | [a]ccept [d]ecline [A]ccept file [q]uit"):format(
    hunk_index,
    math.max(hunk_count, 1),
    file_index,
    math.max(file_count, 1),
    file_name
  )

  vim.api.nvim_buf_set_lines(M._status_popup.bufnr, 0, -1, false, { "", "", "" })
  vim.api.nvim_buf_clear_namespace(M._status_popup.bufnr, ns, 0, -1)

  local line = NuiLine()
  line:append(NuiText(text, "DiffText"))
  line:render(M._status_popup.bufnr, ns, 2)
end

return M
