local config = require("copilot-review.config")

local M = {}

---@param opts? CopilotReview.Config
function M.setup(opts)
  config.setup(opts)
  require("copilot-review.integrations.copilot_chat").setup()
  M._setup_keymaps()
end

function M._setup_keymaps()
  local km = config.options.keymaps
  local map = vim.keymap.set

  -- which-key group registration
  local ok_wk, wk = pcall(require, "which-key")
  if ok_wk then
    wk.add({
      { "<leader>ar", group = "AI Review" },
    })
  end

  -- Review panel
  map("n", km.review_open, function()
    require("copilot-review.ui.review_panel").toggle()
  end, { desc = "Open AI review panel" })

  -- Accept / Decline
  map("n", km.accept_hunk, function()
    require("copilot-review.actions").accept_hunk()
  end, { desc = "Accept current hunk" })

  map("n", km.decline_hunk, function()
    require("copilot-review.actions").decline_hunk()
  end, { desc = "Decline current hunk" })

  map("n", km.accept_file, function()
    require("copilot-review.actions").accept_file()
  end, { desc = "Accept all changes in file" })

  map("n", km.decline_file, function()
    require("copilot-review.actions").decline_file()
  end, { desc = "Decline all changes in file" })

  map("n", km.accept_all, function()
    require("copilot-review.actions").accept_all()
  end, { desc = "Accept ALL changes" })

  -- Task panel
  map("n", km.task_panel, function()
    require("copilot-review.ui.task_panel").toggle()
  end, { desc = "Toggle task/agent panel" })

  -- Status
  map("n", km.status, function()
    require("copilot-review.tracker").show_status()
  end, { desc = "Show AI review status" })

  -- Bracket navigation
  map("n", km.next_hunk, function()
    require("copilot-review.navigator").next_hunk()
  end, { desc = "Next review hunk" })

  map("n", km.prev_hunk, function()
    require("copilot-review.navigator").prev_hunk()
  end, { desc = "Previous review hunk" })

  map("n", km.next_file, function()
    require("copilot-review.navigator").next_file()
  end, { desc = "Next file with changes" })

  map("n", km.prev_file, function()
    require("copilot-review.navigator").prev_file()
  end, { desc = "Previous file with changes" })
end

--- Handle user commands
---@param args table
function M.command(args)
  local subcmd = args.args or ""
  local commands = {
    open = function() require("copilot-review.ui.review_panel").open() end,
    close = function() require("copilot-review.ui.review_panel").close() end,
    toggle = function() require("copilot-review.ui.review_panel").toggle() end,
    accept = function() require("copilot-review.actions").accept_hunk() end,
    decline = function() require("copilot-review.actions").decline_hunk() end,
    ["accept-file"] = function() require("copilot-review.actions").accept_file() end,
    ["decline-file"] = function() require("copilot-review.actions").decline_file() end,
    ["accept-all"] = function() require("copilot-review.actions").accept_all() end,
    tasks = function() require("copilot-review.ui.task_panel").toggle() end,
    status = function() require("copilot-review.tracker").show_status() end,
  }

  if subcmd == "" then
    subcmd = "toggle"
  end

  local cmd = commands[subcmd]
  if cmd then
    cmd()
  else
    vim.notify("CopilotReview: unknown command '" .. subcmd .. "'", vim.log.levels.ERROR)
  end
end

return M
