local Popup = require("nui.popup")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local M = {}

M._popup = nil
M._timer = nil

local ns = vim.api.nvim_create_namespace("copilot-review.task-panel")

local function safe_require(name)
  local ok, module = pcall(require, name)
  if ok then
    return module
  end
  return nil
end

local function safe_options()
  local config = safe_require("copilot-review.config")
  return (config and config.options) or {}
end

local function line_text(chunks)
  local plain = {}
  for _, chunk in ipairs(chunks) do
    plain[#plain + 1] = chunk[1]
  end
  return table.concat(plain)
end

local function render_chunks(bufnr, row, chunks)
  local line = NuiLine()
  for _, chunk in ipairs(chunks) do
    line:append(NuiText(chunk[1], chunk[2]))
  end
  line:render(bufnr, ns, row)
end

local function trim(text, max_len)
  text = vim.trim(text or "")
  if #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 1) .. "…"
end

local function status_icon(status, icons)
  local map = {
    pending = icons.pending or "●",
    running = icons.running or "⏳",
    complete = icons.complete or "✅",
    failed = icons.failed or "❌",
    idle = "⚪",
  }
  return map[status] or "●"
end

local function status_highlight(status)
  local map = {
    pending = "DiagnosticWarn",
    running = "DiagnosticInfo",
    complete = "DiagnosticOk",
    failed = "DiagnosticError",
    idle = "Comment",
  }
  return map[status] or "Normal"
end

local function start_timer()
  if M._timer then
    return
  end

  local uv = vim.uv or vim.loop
  M._timer = uv.new_timer()
  M._timer:start(0, 1000, vim.schedule_wrap(function()
    if M._popup then
      pcall(M.refresh)
    end
  end))
end

local function stop_timer()
  if M._timer then
    M._timer:stop()
    M._timer:close()
    M._timer = nil
  end
end

function M.open()
  if M._popup then
    M.refresh()
    return
  end

  local options = safe_options()
  local cfg = ((options.ui or {}).task_panel or {})

  M._popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = cfg.border or "rounded",
      text = { top = " AI Tasks ", top_align = "center" },
    },
    position = "50%",
    size = {
      width = cfg.width or 60,
      height = cfg.height or 20,
    },
    win_options = {
      wrap = false,
      number = false,
      relativenumber = false,
      cursorline = false,
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
    },
  })

  M._popup:mount()
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = M._popup.bufnr, nowait = true, silent = true, desc = "Close task panel" })
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = M._popup.bufnr, nowait = true, silent = true, desc = "Close task panel" })

  start_timer()
  M.refresh()
end

function M.close()
  stop_timer()

  if M._popup then
    pcall(M._popup.unmount, M._popup)
  end

  M._popup = nil
end

function M.toggle()
  if M._popup then
    M.close()
  else
    M.open()
  end
end

function M.refresh()
  if not M._popup then
    return
  end

  local tracker = safe_require("copilot-review.tracker")
  if tracker and type(tracker.update) == "function" then
    pcall(tracker.update)
  end

  M._render()
end

function M._render()
  if not M._popup then
    return
  end

  local tracker = safe_require("copilot-review.tracker")
  local options = safe_options()
  local icons = options.icons or {}
  local tool_calls = tracker and tracker.get_tool_calls() or {}
  local sessions = tracker and tracker.get_sessions() or {}
  local bufnr = M._popup.bufnr

  local rows = {
    { { "AI Tasks", "Title" } },
    { { "", "Normal" } },
  }

  if #tool_calls == 0 then
    table.insert(rows, { { "No active tool calls", "Comment" } })
  else
    for _, tool_call in ipairs(tool_calls) do
      local icon = status_icon(tool_call.status, icons)
      local args = trim(tool_call.arguments or "", 26)
      local text = ("%s %s(%s)"):format(icon, tool_call.name or "tool", args)
      table.insert(rows, {
        { icon .. " ", status_highlight(tool_call.status) },
        { trim(text:sub(#icon + 2), 46), "Normal" },
      })
    end
  end

  table.insert(rows, { { "", "Normal" } })
  table.insert(rows, { { "Sessions:", "Title" } })

  if #sessions == 0 then
    table.insert(rows, { { "No CopilotChat sessions found", "Comment" } })
  else
    for index, session in ipairs(sessions) do
      local icon = status_icon(session.status, icons)
      local prompt = trim(session.prompt ~= "" and session.prompt or "Idle session", 42)
      local line = ("%s Chat #%d: \"%s\""):format(icon, index, prompt)
      table.insert(rows, {
        { icon .. " ", status_highlight(session.status) },
        { trim(line:sub(#icon + 2), 48), "Normal" },
      })
    end
  end

  local plain_rows = {}
  for _, row in ipairs(rows) do
    plain_rows[#plain_rows + 1] = line_text(row)
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, plain_rows)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for index, row in ipairs(rows) do
    render_chunks(bufnr, index, row)
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

return M
