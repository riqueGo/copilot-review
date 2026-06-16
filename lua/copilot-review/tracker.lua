local M = {}

---@class CopilotReview.ToolCall
---@field id string
---@field name string Tool/function name
---@field arguments string JSON arguments
---@field status "pending"|"running"|"complete"|"failed"
---@field result string|nil Tool call result
---@field timestamp number

---@class CopilotReview.Session
---@field bufnr number CopilotChat buffer number
---@field prompt string Last user prompt
---@field status "idle"|"running"|"complete"
---@field tool_calls CopilotReview.ToolCall[]
---@field model string|nil

---@type CopilotReview.ToolCall[]
M._tool_calls = {}

---@type CopilotReview.Session[]
M._sessions = {}

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

local function stringify(value)
  if value == nil then
    return ""
  end

  if type(value) == "string" then
    return value
  end

  if type(value) == "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then
      return encoded
    end
  end

  return tostring(value)
end

local function get_message_text(message)
  if type(message) ~= "table" then
    return ""
  end

  if type(message.content) == "string" then
    return message.content
  end

  if is_list(message.content) then
    local parts = {}
    for _, part in ipairs(message.content) do
      if type(part) == "string" then
        table.insert(parts, part)
      elseif type(part) == "table" then
        if type(part.text) == "string" then
          table.insert(parts, part.text)
        elseif type(part.content) == "string" then
          table.insert(parts, part.content)
        end
      end
    end
    return table.concat(parts, "\n")
  end

  return stringify(message.content or message.text or message.result)
end

local function detect_tool_status(result_message)
  if type(result_message) ~= "table" then
    return "complete"
  end

  local result = stringify(result_message.content or result_message.result or "")
  if result_message.error or result_message.is_error or result:lower():match("^error") then
    return "failed"
  end

  return "complete"
end

local function collect_tool_calls(message)
  local collected = {}

  local function add_tool_call(tool_call)
    if type(tool_call) ~= "table" then
      return
    end

    local id = tool_call.id or tool_call.tool_call_id
    local fn = tool_call["function"] or tool_call.function_call or {}
    local name = tool_call.name or fn.name
    local arguments = tool_call.arguments or fn.arguments or {}

    if id and name then
      table.insert(collected, {
        id = tostring(id),
        name = tostring(name),
        arguments = stringify(arguments),
      })
    end
  end

  if is_list(message.tool_calls) then
    for _, tool_call in ipairs(message.tool_calls) do
      add_tool_call(tool_call)
    end
  end

  if is_list(message.content) then
    for _, part in ipairs(message.content) do
      if type(part) == "table" then
        if is_list(part.tool_calls) then
          for _, tool_call in ipairs(part.tool_calls) do
            add_tool_call(tool_call)
          end
        elseif part.tool_call or part["function"] or part.function_call then
          add_tool_call(part.tool_call or part)
        end
      end
    end
  end

  return collected
end

local function find_chat_objects()
  local chats = {}
  local seen = {}
  local copilot_chat = safe_require("CopilotChat")

  local function add_chat(candidate)
    if type(candidate) ~= "table" or seen[candidate] then
      return
    end

    if type(candidate.get_messages) == "function" or type(candidate.messages) == "table" then
      chats[#chats + 1] = candidate
      seen[candidate] = true
    end
  end

  if type(copilot_chat) == "table" then
    add_chat(copilot_chat.chat)
    add_chat(copilot_chat.current_chat)

    for _, key in ipairs({ "chats", "_chats", "instances", "_instances" }) do
      local value = copilot_chat[key]
      if is_list(value) then
        for _, chat in ipairs(value) do
          add_chat(chat)
        end
      elseif type(value) == "table" then
        for _, chat in pairs(value) do
          add_chat(chat)
        end
      end
    end
  end

  return chats
end

local function scan_copilot_buffers()
  local sessions = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ok_ft, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      local ok_name, name = pcall(vim.api.nvim_buf_get_name, bufnr)
      local ft = ok_ft and (filetype or "") or ""
      local bufname = ok_name and (name or "") or ""
      local marker = (ft .. " " .. bufname):lower()

      if marker:find("copilot") and marker:find("chat") then
        sessions[bufnr] = {
          bufnr = bufnr,
          prompt = "",
          status = "idle",
          tool_calls = {},
          model = nil,
        }
      end
    end
  end

  return sessions
end

local function get_review_state()
  local review = safe_require("copilot-review.review")
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

local function get_review_stats()
  local state = get_review_state()
  if type(state) ~= "table" then
    return 0, 0, false
  end

  local files = state.files or state.file_changes or state.changes or {}
  if not is_list(files) then
    return 0, 0, state.active == true
  end

  local change_count = 0
  for _, file_change in ipairs(files) do
    local hunks = file_change.hunks or file_change.changes or file_change.diff_hunks or {}
    if is_list(hunks) then
      change_count = change_count + #hunks
    else
      change_count = change_count + 1
    end
  end

  return change_count, #files, #files > 0 or state.active == true
end

function M.update()
  local tool_calls = {}
  local tool_calls_by_id = {}
  local sessions_by_buf = scan_copilot_buffers()
  local now = os.time()
  local synthetic_bufnr = -1

  for _, chat in ipairs(find_chat_objects()) do
    local messages = chat.messages or {}
    if type(chat.get_messages) == "function" then
      local ok, chat_messages = pcall(chat.get_messages, chat)
      if ok and is_list(chat_messages) then
        messages = chat_messages
      end
    end

    local bufnr = tonumber(chat.bufnr or chat.buf or chat.buffer or 0) or 0
    if bufnr <= 0 then
      bufnr = synthetic_bufnr
      synthetic_bufnr = synthetic_bufnr - 1
    end

    local session = sessions_by_buf[bufnr] or {
      bufnr = bufnr,
      prompt = "",
      status = "idle",
      tool_calls = {},
      model = chat.model or (chat.config and chat.config.model) or nil,
    }
    session.model = session.model or chat.model or (chat.config and chat.config.model) or nil

    for _, message in ipairs(messages) do
      local role = tostring(message.role or message.type or ""):lower()
      if role == "user" then
        local prompt = vim.trim(get_message_text(message))
        if prompt ~= "" then
          session.prompt = prompt
        end
      elseif role == "assistant" then
        for _, extracted in ipairs(collect_tool_calls(message)) do
          local tool_call = tool_calls_by_id[extracted.id] or {
            id = extracted.id,
            name = extracted.name,
            arguments = extracted.arguments,
            status = "running",
            result = nil,
            timestamp = tonumber(message.timestamp or chat.updated_at or now) or now,
            bufnr = bufnr,
          }

          tool_call.name = extracted.name
          tool_call.arguments = extracted.arguments
          tool_call.status = tool_call.result and tool_call.status or "running"
          tool_calls_by_id[tool_call.id] = tool_call
        end
      elseif role == "tool" or role == "function" then
        local tool_call_id = message.tool_call_id or message.id
        if tool_call_id and tool_calls_by_id[tostring(tool_call_id)] then
          local tool_call = tool_calls_by_id[tostring(tool_call_id)]
          tool_call.result = get_message_text(message)
          tool_call.status = detect_tool_status(message)
        end
      end
    end

    for _, tool_call in pairs(tool_calls_by_id) do
      if tool_call.bufnr == bufnr then
        table.insert(session.tool_calls, tool_call)
      end
    end

    if #session.tool_calls > 0 then
      session.status = "complete"
      for _, tool_call in ipairs(session.tool_calls) do
        if tool_call.status == "running" or tool_call.status == "pending" then
          session.status = "running"
          break
        end
        if tool_call.status == "failed" then
          session.status = "complete"
        end
      end
    elseif session.prompt ~= "" then
      session.status = "complete"
    end

    sessions_by_buf[bufnr] = session
  end

  for _, tool_call in pairs(tool_calls_by_id) do
    table.insert(tool_calls, tool_call)
  end

  table.sort(tool_calls, function(a, b)
    return (a.timestamp or 0) > (b.timestamp or 0)
  end)

  local sessions = {}
  for _, session in pairs(sessions_by_buf) do
    table.sort(session.tool_calls, function(a, b)
      return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    table.insert(sessions, session)
  end

  table.sort(sessions, function(a, b)
    return (a.bufnr or 0) < (b.bufnr or 0)
  end)

  M._tool_calls = tool_calls
  M._sessions = sessions
end

function M.get_tool_calls()
  M.update()
  return M._tool_calls
end

function M.get_sessions()
  M.update()
  return M._sessions
end

function M.get_status_string()
  M.update()

  for _, tool_call in ipairs(M._tool_calls) do
    if tool_call.status == "running" or tool_call.status == "pending" then
      return ("⏳ %s..."):format(tool_call.name)
    end
  end

  local change_count, file_count, active = get_review_stats()
  if active and (change_count > 0 or file_count > 0) then
    return ("🔍 %d changes (%d files)"):format(change_count, file_count)
  end

  return ""
end

function M.show_status()
  M.update()

  local change_count, file_count, active = get_review_stats()
  local running_tools = 0
  for _, tool_call in ipairs(M._tool_calls) do
    if tool_call.status == "running" or tool_call.status == "pending" then
      running_tools = running_tools + 1
    end
  end

  local summary = {}
  if active then
    table.insert(summary, ("%d changes (%d files)"):format(change_count, file_count))
  end
  if running_tools > 0 then
    table.insert(summary, ("%d tool%s running"):format(running_tools, running_tools == 1 and "" or "s"))
  end

  if #summary == 0 then
    table.insert(summary, "idle")
  end

  vim.notify("AI Review: " .. table.concat(summary, " | "), vim.log.levels.INFO)
end

return M
