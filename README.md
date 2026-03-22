# lobs-vim

Neovim plugin for [Lobs](https://github.com/lobs-ai/lobs-core) — a personal AI agent that can edit your code, run commands, and search the web, all from a chat sidebar in Neovim.

Think Cursor's agent mode, but backed by your own agent infrastructure.

## Features

- **Chat sidebar** — talk to Lobs, get streamed responses with markdown rendering
- **Full agent capabilities** — Lobs can read/write/edit files on your machine, run shell commands, search the web, and use memory
- **Code context** — automatically sends current file, cursor position, and selection as context
- **Diff application** — review and accept/reject file changes the agent proposes
- **Project-aware** — sessions are scoped to your project root

## Requirements

- Neovim >= 0.10
- [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)
- A running [lobs-core](https://github.com/lobs-ai/lobs-core) instance
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (UI components)

## Installation

```lua
-- lazy.nvim
{
  "lobs-ai/lobs-vim",
  dependencies = {
    "MunifTanjim/nui.nvim",
  },
  opts = {
    server = "ws://your-lobs-server:9420",
    token = "your-auth-token",
  },
}
```

## Usage

| Command | Description |
|---------|-------------|
| `:LobsToggle` | Toggle the chat sidebar |
| `:LobsChat` | Open sidebar and focus input |
| `:LobsSend` | Send current input |
| `:LobsAsk` | Ask about selected code (visual mode) |
| `:LobsNewSession` | Start a new chat session |
| `:LobsAcceptAll` | Accept all pending file changes |

## Keybindings

Default keybindings (customizable):

| Key | Mode | Action |
|-----|------|--------|
| `<leader>aa` | n | Toggle sidebar |
| `<leader>ac` | n | New chat session |
| `<leader>as` | v | Ask about selection |
| `<CR>` | n (in input) | Send message |

## License

MIT
