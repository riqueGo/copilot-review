# copilot-review.nvim

A Neovim plugin that enhances [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) with **granular change review**, **accept/decline workflows**, and **task/agent tracking**.

![Neovim](https://img.shields.io/badge/NeoVim-%2357A143.svg?&style=for-the-badge&logo=neovim&logoColor=white)

## ✨ Features

- **Hunk-by-hunk review** — Navigate through individual changes from Copilot Chat responses
- **Per-file accept/decline** — Accept or decline all changes in a file at once
- **Side-by-side diff panel** — Visual diff view with original and modified content
- **Task/agent tracking** — See active tool calls, their status, and parallel chat sessions
- **Bracket-style navigation** — `]r`/`[r` to jump between changes (like `]c` for git hunks)
- **Lualine integration** — Statusline component showing review progress
- **Which-key support** — All keymaps registered with descriptions

## 📦 Requirements

- Neovim >= 0.10
- [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) (required)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (required, for UI panels)
- [which-key.nvim](https://github.com/folke/which-key.nvim) (optional, for keymap hints)
- [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) (optional, for statusline)

## 🚀 Installation

### lazy.nvim

```lua
{
  "riqueGo/copilot-review.nvim",
  dependencies = {
    "CopilotC-Nvim/CopilotChat.nvim",
    "MunifTanjim/nui.nvim",
  },
  opts = {},
  keys = {
    { "<leader>ar", desc = "+AI Review" },
    { "<leader>arr", desc = "Open review panel" },
    { "<leader>ara", desc = "Accept hunk" },
    { "<leader>ard", desc = "Decline hunk" },
    { "<leader>art", desc = "Task panel" },
    { "]r", desc = "Next review hunk" },
    { "[r", desc = "Previous review hunk" },
  },
}
```

## ⌨️ Keymaps

### AI Review commands (`<leader>ar`)

| Keymap | Description |
|--------|-------------|
| `<leader>arr` | Open/toggle the review panel |
| `<leader>ara` | Accept current hunk |
| `<leader>ard` | Decline current hunk |
| `<leader>arA` | Accept all changes in current file |
| `<leader>arD` | Decline all changes in current file |
| `<leader>ary` | Accept ALL changes across all files |
| `<leader>art` | Toggle task/agent tracking panel |
| `<leader>ars` | Show review status summary |

### Navigation (bracket-style)

| Keymap | Description |
|--------|-------------|
| `]r` | Jump to next review hunk |
| `[r` | Jump to previous review hunk |
| `]R` | Jump to next file with changes |
| `[R` | Jump to previous file with changes |

### Inside review panel

| Key | Description |
|-----|-------------|
| `a` | Accept current hunk |
| `d` | Decline current hunk |
| `A` | Accept all hunks in file |
| `D` | Decline all hunks in file |
| `y` | Accept all changes |
| `n` / `]r` | Next hunk |
| `p` / `[r` | Previous hunk |
| `N` / `]R` | Next file |
| `P` / `[R` | Previous file |
| `q` | Close panel |

## ⚙️ Configuration

```lua
require("copilot-review").setup({
  -- Automatically open review panel when CopilotChat responds with changes
  auto_review = false,

  keymaps = {
    -- AI Review group
    review_open = "<leader>arr",
    accept_hunk = "<leader>ara",
    decline_hunk = "<leader>ard",
    accept_file = "<leader>arA",
    decline_file = "<leader>arD",
    accept_all = "<leader>ary",
    task_panel = "<leader>art",
    status = "<leader>ars",

    -- Bracket navigation
    next_hunk = "]r",
    prev_hunk = "[r",
    next_file = "]R",
    prev_file = "[R",

    -- Inside review panel
    review_close = "q",
  },

  ui = {
    review_panel = {
      width = 0.8,         -- 80% of editor width
      position = "right",  -- "right", "left", "bottom", "top"
      border = "rounded",
    },
    task_panel = {
      width = 60,          -- columns
      height = 20,         -- rows
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
})
```

## 📊 Lualine Integration

Add the statusline component to your lualine config:

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("copilot-review.ui.statusline").component,
    },
  },
})
```

This shows:
- `🔍 3 changes (2 files)` — when a review is active
- `⏳ search_files...` — when CopilotChat tools are running
- Nothing when idle

## 🏗️ Architecture

```
copilot-review.nvim
├── lua/copilot-review/
│   ├── init.lua              → Plugin setup, keymaps, user commands
│   ├── config.lua            → Default config + user overrides
│   ├── review.lua            → Change review engine (parse blocks → hunks)
│   ├── navigator.lua         → Navigate between hunks/files
│   ├── actions.lua           → Accept/decline per hunk/file/all
│   ├── tracker.lua           → Tool call + session tracking
│   ├── integrations/
│   │   └── copilot_chat.lua  → Hooks into CopilotChat.nvim API
│   └── ui/
│       ├── review_panel.lua  → Side-by-side diff split (nui.nvim)
│       ├── task_panel.lua    → Floating task/agent panel (nui.nvim)
│       └── statusline.lua    → Lualine component
└── plugin/
    └── copilot-review.lua    → Auto-load registration
```

### How it works

1. **Hooks into CopilotChat** — Wraps the `callback` config to intercept assistant responses
2. **Parses changes** — Extracts code blocks from responses, groups by filename, computes diffs
3. **Splits into hunks** — Each diff is broken into individual hunks for granular review
4. **Presents for review** — Side-by-side diff panel with navigation and accept/decline
5. **Applies changes** — Accepted hunks are applied directly to the source buffers
6. **Tracks progress** — Tool calls and chat sessions are monitored for the task panel

## 🔧 Commands

| Command | Description |
|---------|-------------|
| `:CopilotReview` | Toggle review panel |
| `:CopilotReview open` | Open review panel |
| `:CopilotReview close` | Close review panel |
| `:CopilotReview accept` | Accept current hunk |
| `:CopilotReview decline` | Decline current hunk |
| `:CopilotReview accept-file` | Accept all hunks in file |
| `:CopilotReview decline-file` | Decline all hunks in file |
| `:CopilotReview accept-all` | Accept all changes |
| `:CopilotReview tasks` | Toggle task panel |
| `:CopilotReview status` | Show status |

## 🤝 Why not GitHub Copilot Extensions?

GitHub Copilot Extensions are server-side applications that run on GitHub.com or integrate via the VS Code API. They cannot be used to build Neovim-native plugins. This plugin instead wraps CopilotChat.nvim's Lua API directly for maximum integration and performance.

## 📝 License

MIT — see [LICENSE](LICENSE)
