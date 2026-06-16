local M = {}

---@class CopilotReview.ToolCall
---@field id string
---@field name? string
---@field arguments? string
---@field status 'pending'|'running'|'completed'
---@field result? string

---@class CopilotReview.Session
---@field bufnr integer
---@field prompt string
---@field status 'active'|'hidden'|'unknown'
---@field source_bufnr? integer

---@class CopilotReview.ChangeBlock
---@field block CopilotChat.ui.chat.Block
---@field diff string
---@field hunks table[]

---@class CopilotReview.ChangeFile
---@field filename string
---@field filetype string
---@field blocks CopilotReview.ChangeBlock[]

M._last_response = nil
M._tool_calls = {}
M._sessions = {}
M._callbacks = {}

M._attached_buffers = {}
M._tool_call_index = {}
M._wrapped_callbacks = setmetatable({}, { __mode = 'k' })
M._setup_wrapped = false
M._setup_done = false
M._last_response_key = nil
M._last_changes_signature = nil
M._augroup = nil

local function deepcopy(value)
  local ok, copy = pcall(vim.deepcopy, value)
  return ok and copy or value
end

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.WARN)
  end)
end

local function get_copilot_chat()
  local ok, chat = pcall(require, 'CopilotChat')
  if not ok then
    return nil
  end
  return chat
end

local function get_constants()
  local ok, constants = pcall(require, 'CopilotChat.constants')
  if not ok then
    return nil
  end
  return constants
end

local function get_diff_utils()
  local ok, diff = pcall(require, 'CopilotChat.utils.diff')
  if not ok then
    return nil
  end
  return diff
end

local function is_absolute_path(path)
  return type(path) == 'string' and (path:match('^%a:[/\\]') ~= nil or path:match('^\\\\') ~= nil)
end

local function normalize_path(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  return vim.fs.normalize(path)
end

local function resolve_path(path, source)
  local normalized = normalize_path(path)
  if not normalized then
    return nil
  end

  if is_absolute_path(normalized) then
    return normalized
  end

  local uv = vim.uv or vim.loop
  local cwd = source and source.cwd and source.cwd() or (uv and uv.cwd() or nil)
  if type(cwd) == 'string' and cwd ~= '' then
    return vim.fs.normalize(vim.fs.joinpath(cwd, normalized))
  end

  return normalized
end

local function message_key(message)
  if type(message) ~= 'table' then
    return nil
  end

  local parts = {
    message.role or '',
    message.content or '',
  }

  if message.tool_calls then
    for _, tool_call in ipairs(message.tool_calls) do
      table.insert(parts, table.concat({ tool_call.id or '', tool_call.name or '', tool_call.arguments or '' }, ':'))
    end
  end

  if message.section and message.section.blocks then
    for _, block in ipairs(message.section.blocks) do
      local header = block.header or {}
      table.insert(parts, table.concat({
        header.filename or '',
        header.filetype or '',
        tostring(header.start_line or ''),
        tostring(header.end_line or ''),
        block.content or '',
      }, ':'))
    end
  end

  return table.concat(parts, '|')
end

local function parse_hunks(diff_text)
  local hunks = {}
  local current_hunk = nil

  for _, line in ipairs(vim.split(diff_text or '', '\n')) do
    if line:match('^@@') then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      local start_old, len_old, start_new, len_new = line:match('@@%s%-(%d+),?(%d*)%s%+(%d+),?(%d*)%s@@')
      current_hunk = {
        start_old = tonumber(start_old),
        len_old = len_old == '' and 1 or tonumber(len_old),
        start_new = tonumber(start_new),
        len_new = len_new == '' and 1 or tonumber(len_new),
        old_snippet = {},
        new_snippet = {},
      }
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      local text = line:sub(2)
      if prefix == '-' then
        table.insert(current_hunk.old_snippet, text)
      elseif prefix == '+' then
        table.insert(current_hunk.new_snippet, text)
      elseif prefix == ' ' then
        table.insert(current_hunk.old_snippet, text)
        table.insert(current_hunk.new_snippet, text)
      end
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

local function is_chat_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local ok_name, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  local ok_ft, filetype = pcall(function()
    return vim.bo[bufnr].filetype
  end)

  if ok_ft and filetype == 'copilot-chat' then
    return true
  end

  if ok_name and name and name:match('copilot%-chat$') then
    return true
  end

  local copilot_chat = get_copilot_chat()
  return copilot_chat and copilot_chat.chat and copilot_chat.chat.bufnr == bufnr or false
end

local function list_messages()
  local copilot_chat = get_copilot_chat()
  if not copilot_chat or not copilot_chat.chat or type(copilot_chat.chat.get_messages) ~= 'function' then
    return {}, nil, nil
  end

  local ok_messages, messages = pcall(copilot_chat.chat.get_messages, copilot_chat.chat)
  if not ok_messages or type(messages) ~= 'table' then
    return {}, copilot_chat, nil
  end

  local ok_source, source = pcall(copilot_chat.chat.get_source, copilot_chat.chat)
  return messages, copilot_chat, ok_source and source or nil
end

local function find_last_assistant_message(messages, require_blocks)
  local constants = get_constants()
  if not constants then
    return nil
  end

  for i = #messages, 1, -1 do
    local message = messages[i]
    if message.role == constants.ROLE.ASSISTANT then
      local has_blocks = message.section and message.section.blocks and #message.section.blocks > 0
      if not require_blocks or has_blocks then
        return message
      end
    end
  end
end

local function find_tool_record(id)
  if not id then
    return nil
  end
  return M._tool_call_index[id]
end

local function upsert_tool_record(tool_call)
  if type(tool_call) ~= 'table' or not tool_call.id then
    return nil, false
  end

  local record = find_tool_record(tool_call.id)
  local created = false
  if not record then
    record = {
      id = tool_call.id,
      name = tool_call.name,
      arguments = tool_call.arguments,
      status = tool_call.status or 'pending',
      result = tool_call.result,
    }
    M._tool_call_index[tool_call.id] = record
    table.insert(M._tool_calls, record)
    created = true
  else
    record.name = tool_call.name or record.name
    record.arguments = tool_call.arguments or record.arguments
    record.status = tool_call.status or record.status
    if tool_call.result ~= nil then
      record.result = tool_call.result
    end
  end

  return record, created
end

local function read_block_lines(block, source)
  local header = block.header or {}
  local filename = header.filename
  if not filename or filename == '' then
    return {}
  end

  local resolved = resolve_path(filename, source)
  local candidates = { resolved, normalize_path(filename) }

  for _, candidate in ipairs(candidates) do
    if candidate and vim.fn.bufexists(candidate) == 1 then
      local bufnr = vim.fn.bufnr(candidate)
      if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end
    end
  end

  if source and source.bufnr and vim.api.nvim_buf_is_valid(source.bufnr) then
    local source_name = normalize_path(vim.api.nvim_buf_get_name(source.bufnr))
    if source_name and resolved and source_name == resolved then
      return vim.api.nvim_buf_get_lines(source.bufnr, 0, -1, false)
    end
  end

  for _, candidate in ipairs(candidates) do
    if candidate and vim.fn.filereadable(candidate) == 1 then
      return vim.fn.readfile(candidate)
    end
  end

  return {}
end

local function make_changes_signature(changes)
  local keys = vim.tbl_keys(changes)
  table.sort(keys)

  local payload = {}
  for _, filename in ipairs(keys) do
    local entry = changes[filename]
    local blocks = {}
    for _, item in ipairs(entry.blocks or {}) do
      table.insert(blocks, {
        filename = item.block.header and item.block.header.filename or '',
        filetype = item.block.header and item.block.header.filetype or '',
        start_line = item.block.header and item.block.header.start_line or 0,
        end_line = item.block.header and item.block.header.end_line or 0,
        diff = item.diff,
      })
    end
    table.insert(payload, { filename = filename, filetype = entry.filetype, blocks = blocks })
  end

  local ok, encoded = pcall(vim.json.encode, payload)
  return ok and encoded or tostring(#payload)
end

function M._emit(event, data)
  local callbacks = M._callbacks[event]
  if not callbacks then
    return
  end

  for _, callback in ipairs(callbacks) do
    local ok, err = pcall(callback, deepcopy(data))
    if not ok then
      notify(('CopilotReview callback failed for %s: %s'):format(event, err), vim.log.levels.ERROR)
    end
  end
end

---@param event 'response_received'|'tool_call_start'|'tool_call_complete'|'changes_detected'
---@param callback fun(data: any)
---@return fun()
function M.on(event, callback)
  if type(event) ~= 'string' or type(callback) ~= 'function' then
    return function() end
  end

  M._callbacks[event] = M._callbacks[event] or {}
  table.insert(M._callbacks[event], callback)

  return function()
    local callbacks = M._callbacks[event]
    if not callbacks then
      return
    end

    for index, registered in ipairs(callbacks) do
      if registered == callback then
        table.remove(callbacks, index)
        break
      end
    end
  end
end

local function refresh_sessions()
  local sessions = {}
  local messages, copilot_chat, source = list_messages()
  local last_user_prompt = ''
  local constants = get_constants()

  if constants then
    for i = #messages, 1, -1 do
      local message = messages[i]
      if message.role == constants.ROLE.USER and type(message.content) == 'string' and vim.trim(message.content) ~= '' then
        last_user_prompt = vim.trim(message.content)
        break
      end
    end
  end

  if copilot_chat and copilot_chat.chat and copilot_chat.chat.bufnr and vim.api.nvim_buf_is_valid(copilot_chat.chat.bufnr) then
    table.insert(sessions, {
      bufnr = copilot_chat.chat.bufnr,
      prompt = last_user_prompt,
      status = copilot_chat.chat.visible and copilot_chat.chat:visible() and 'active' or 'hidden',
      source_bufnr = source and source.bufnr or nil,
    })
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_chat_buffer(bufnr) then
      local known = false
      for _, session in ipairs(sessions) do
        if session.bufnr == bufnr then
          known = true
          break
        end
      end
      if not known then
        table.insert(sessions, {
          bufnr = bufnr,
          prompt = '',
          status = 'unknown',
        })
      end
    end
  end

  M._sessions = sessions
  return sessions
end

local function sync_tool_calls(messages)
  local constants = get_constants()
  if not constants then
    return
  end

  if #messages == 0 then
    M._tool_calls = {}
    M._tool_call_index = {}
    return
  end

  for _, message in ipairs(messages) do
    if message.role == constants.ROLE.ASSISTANT and message.tool_calls then
      for _, tool_call in ipairs(message.tool_calls) do
        local record, created = upsert_tool_record({
          id = tool_call.id,
          name = tool_call.name,
          arguments = tool_call.arguments,
          status = 'running',
        })

        if record and (created or record.status ~= 'completed') then
          record.status = 'running'
        end

        if created then
          M._emit('tool_call_start', { tool_call = deepcopy(record), message = deepcopy(message) })
        end
      end
    elseif message.role == constants.ROLE.TOOL and message.tool_call_id then
      local tool_record = find_tool_record(message.tool_call_id)
      local changed = not tool_record or tool_record.status ~= 'completed' or tool_record.result ~= message.content

      upsert_tool_record({
        id = message.tool_call_id,
        status = 'completed',
        result = message.content,
      })

      tool_record = find_tool_record(message.tool_call_id)
      if tool_record then
        if changed then
          M._emit('tool_call_complete', { tool_call = deepcopy(tool_record), message = deepcopy(message) })
        end
      end
    end
  end
end

function M.get_tool_calls()
  return deepcopy(M._tool_calls)
end

function M.get_sessions()
  return deepcopy(refresh_sessions())
end

function M.get_changes()
  local diff = get_diff_utils()
  if not diff then
    return {}
  end

  local messages, _, source = list_messages()
  local response = find_last_assistant_message(messages, true)
  if not response or not response.section or not response.section.blocks then
    return {}
  end

  local changes = {}

  for _, block in ipairs(response.section.blocks) do
    local header = block.header or {}
    local filename = header.filename
    if filename and filename ~= '' then
      local lines = read_block_lines(block, source)
      local unified_diff = diff.get_diff(block, lines)
      local entry = changes[filename]
      if not entry then
        entry = {
          filename = filename,
          filetype = header.filetype or 'text',
          blocks = {},
        }
        changes[filename] = entry
      end

      table.insert(entry.blocks, {
        block = deepcopy(block),
        diff = unified_diff,
        hunks = parse_hunks(unified_diff),
      })
    end
  end

  return changes
end

local function sync_from_chat(cause)
  local messages, copilot_chat, source = list_messages()
  local last_response = find_last_assistant_message(messages, false)
  local next_key = message_key(last_response)

  if last_response and next_key and next_key ~= M._last_response_key and cause ~= 'callback' then
    M._last_response = deepcopy(last_response)
    M._last_response_key = next_key
    M._emit('response_received', { response = deepcopy(last_response), source = deepcopy(source) })
    if copilot_chat and copilot_chat.chat and copilot_chat.chat.bufnr then
      M._attached_buffers[copilot_chat.chat.bufnr] = true
    end
  elseif not last_response then
    M._last_response = nil
    M._last_response_key = nil
  end

  refresh_sessions()
  sync_tool_calls(messages)

  local changes = M.get_changes()
  if next(changes) == nil then
    M._last_changes_signature = nil
    return
  end

  local signature = make_changes_signature(changes)
  if signature ~= M._last_changes_signature then
    M._last_changes_signature = signature
    M._emit('changes_detected', {
      changes = changes,
      response = deepcopy(M._last_response),
      cause = cause,
    })
  end
end

function M.apply_block(block, bufnr)
  local diff = get_diff_utils()
  if not diff then
    return false, 'CopilotChat.utils.diff is unavailable'
  end

  if (not bufnr or bufnr == 0) and block and block.header and block.header.filename then
    local resolved = resolve_path(block.header.filename)
    if resolved and vim.fn.bufexists(resolved) == 1 then
      bufnr = vim.fn.bufnr(resolved)
    end
  end

  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, 'Target buffer is invalid'
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines = diff.apply_diff(block, lines)
  local modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.bo[bufnr].modifiable = modifiable
  return true
end

local function attach_chat_buffer(bufnr)
  if not is_chat_buffer(bufnr) or M._attached_buffers[bufnr] then
    return
  end

  M._attached_buffers[bufnr] = true

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    group = M._augroup,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        sync_from_chat('buffer_changed')
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = M._augroup,
    buffer = bufnr,
    callback = function()
      M._attached_buffers[bufnr] = nil
      refresh_sessions()
    end,
  })
end

local function make_callback_wrapper(existing_callback)
  if type(existing_callback) == 'function' and M._wrapped_callbacks[existing_callback] then
    return existing_callback
  end

  local wrapper = function(response, source)
    if existing_callback then
      existing_callback(response, source)
    end

    M._last_response = deepcopy(response)
    M._last_response_key = message_key(response)
    M._emit('response_received', {
      response = deepcopy(response),
      source = deepcopy(source),
    })

    vim.schedule(function()
      sync_from_chat('callback')
    end)
  end

  M._wrapped_callbacks[wrapper] = true
  return wrapper
end

local function ensure_hooked()
  local copilot_chat = get_copilot_chat()
  if not copilot_chat then
    return false
  end

  if not M._setup_wrapped and type(copilot_chat.setup) == 'function' then
    local original_setup = copilot_chat.setup
    copilot_chat.setup = function(config)
      config = config or {}
      if type(config.callback) == 'function' then
        config.callback = make_callback_wrapper(config.callback)
      elseif not M._wrapped_callbacks[config.callback] then
        config.callback = make_callback_wrapper(config.callback)
      end

      local result = original_setup(config)
      ensure_hooked()
      vim.schedule(function()
        refresh_sessions()
        for _, session in ipairs(M._sessions) do
          attach_chat_buffer(session.bufnr)
        end
      end)
      return result
    end
    M._setup_wrapped = true
  end

  if copilot_chat.config and not M._wrapped_callbacks[copilot_chat.config.callback] then
    copilot_chat.config.callback = make_callback_wrapper(copilot_chat.config.callback)
  end

  refresh_sessions()
  for _, session in ipairs(M._sessions) do
    attach_chat_buffer(session.bufnr)
  end

  return true
end

function M.setup()
  if M._setup_done then
    vim.schedule(ensure_hooked)
    return
  end

  M._setup_done = true
  M._augroup = vim.api.nvim_create_augroup('CopilotReviewCopilotChat', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufAdd', 'BufEnter', 'BufWinEnter', 'FileType' }, {
    group = M._augroup,
    callback = function(ev)
      if ev.buf and is_chat_buffer(ev.buf) then
        attach_chat_buffer(ev.buf)
      end
      vim.schedule(ensure_hooked)
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    group = M._augroup,
    pattern = { 'VeryLazy', 'LazyLoad', 'LazyDone' },
    callback = function()
      vim.schedule(ensure_hooked)
    end,
  })

  vim.schedule(function()
    if not ensure_hooked() then
      return
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      attach_chat_buffer(bufnr)
    end

    sync_from_chat('setup')
  end)
end

return M
