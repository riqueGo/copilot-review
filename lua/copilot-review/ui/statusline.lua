local M = {}

local function safe_require(name)
  local ok, module = pcall(require, name)
  if ok then
    return module
  end
  return nil
end

function M.get()
  local tracker = safe_require("copilot-review.tracker")
  if not tracker or type(tracker.get_status_string) ~= "function" then
    return ""
  end

  local ok, status = pcall(tracker.get_status_string)
  if ok and type(status) == "string" then
    return status
  end

  return ""
end

function M.has_review()
  return M.get() ~= ""
end

M.component = {
  function()
    return M.get()
  end,
  cond = function()
    return M.has_review()
  end,
  color = { fg = "#7aa2f7" },
}

return M
