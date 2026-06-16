if vim.g.loaded_copilot_review then
  return
end
vim.g.loaded_copilot_review = true

vim.api.nvim_create_user_command("CopilotReview", function(args)
  require("copilot-review").command(args)
end, {
  nargs = "?",
  desc = "Copilot Review — AI change review and task tracking",
  complete = function()
    return { "open", "close", "toggle", "accept", "decline", "accept-file", "decline-file", "accept-all", "tasks", "status" }
  end,
})
