---@class CopilotReview.Config
---@field auto_review boolean Auto-open review panel when CopilotChat responds with changes
---@field keymaps CopilotReview.Config.Keymaps
---@field ui CopilotReview.Config.UI
---@field icons CopilotReview.Config.Icons

---@class CopilotReview.Config.Keymaps
---@field review_open string
---@field review_close string
---@field accept_hunk string
---@field decline_hunk string
---@field accept_file string
---@field decline_file string
---@field accept_all string
---@field task_panel string
---@field status string
---@field next_hunk string
---@field prev_hunk string
---@field next_file string
---@field prev_file string

---@class CopilotReview.Config.UI
---@field review_panel CopilotReview.Config.UI.ReviewPanel
---@field task_panel CopilotReview.Config.UI.TaskPanel

---@class CopilotReview.Config.UI.ReviewPanel
---@field width number Fractional width of the editor (0-1) or absolute columns (>1)
---@field position "right"|"left"|"bottom"|"top"
---@field border string

---@class CopilotReview.Config.UI.TaskPanel
---@field width number
---@field height number
---@field border string

---@class CopilotReview.Config.Icons
---@field accepted string
---@field declined string
---@field pending string
---@field running string
---@field complete string
---@field failed string
---@field file string
---@field hunk string

local M = {}

---@type CopilotReview.Config
M.defaults = {
  auto_review = false,

  keymaps = {
    -- <leader>ar group — AI Review
    review_open = "<leader>arr",
    accept_hunk = "<leader>ara",
    decline_hunk = "<leader>ard",
    accept_file = "<leader>arA",
    decline_file = "<leader>arD",
    accept_all = "<leader>ary",
    task_panel = "<leader>art",
    status = "<leader>ars",

    -- Bracket-style navigation
    next_hunk = "]r",
    prev_hunk = "[r",
    next_file = "]R",
    prev_file = "[R",

    -- Inside review panel
    review_close = "q",
  },

  ui = {
    review_panel = {
      width = 0.8,
      position = "right",
      border = "rounded",
    },
    task_panel = {
      width = 60,
      height = 20,
      border = "rounded",
    },
  },

  icons = {
    accepted = "✓",
    declined = "✗",
    pending = "●",
    running = "⏳",
    complete = "✅",
    failed = "❌",
    file = "📄",
    hunk = "≋",
  },
}

---@type CopilotReview.Config
M.options = {}

---@param opts? CopilotReview.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
