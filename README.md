# lobs.nvim

AI coding agent for Neovim. Connects to [lobs-core](https://github.com/lobs-ai/lobs-core) — tools run locally in your editor, reasoning runs on the server.

## Install

**LazyVim / lazy.nvim:**

```lua
return {
  url = "git@github.com:lobs-ai/lobs-vim",
  opts = {
    server = "wss://nexus.lobslab.com",
  },
}
```

That's it. On first connect it'll open your browser for Cloudflare Access login (one-time).

### Local development (no auth needed)

```lua
return {
  url = "git@github.com:lobs-ai/lobs-vim",
  opts = {
    server = "ws://localhost:9420",
  },
}
```

## Requirements

- Neovim ≥ 0.10
- [websocat](https://github.com/nickel-lang/websocat) — `brew install websocat`
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/) — `brew install cloudflared` (only for remote servers behind CF Access)

## Configuration

All options with defaults:

```lua
return {
  url = "git@github.com:lobs-ai/lobs-vim",
  opts = {
    -- Server URL
    server = "ws://localhost:9420",

    -- Cloudflare Access (auto-detected for *.lobslab.com)
    cloudflare = {
      enabled = nil,  -- nil = auto-detect, true/false = override
      url = nil,      -- override the auth URL
    },

    -- UI
    sidebar_width = 60,
    sidebar_position = "right",  -- "left" or "right"

    -- Context
    send_current_file = true,
    send_selection = true,
    max_context_lines = 500,

    -- Keymaps (false to disable)
    keymaps = {
      toggle = "<leader>aa",
      new_session = "<leader>ac",
      ask_selection = "<leader>as",
    },
  },
}
```

## Usage

| Command | Description |
|---------|-------------|
| `:LobsToggle` / `<leader>aa` | Open/close chat sidebar |
| `:LobsChat` | Open chat and focus input |
| `:LobsAsk` / `<leader>as` (visual) | Ask about selected code |
| `:LobsNewSession` / `<leader>ac` | Start fresh conversation |
| `:LobsAcceptAll` | Accept all proposed changes |
| `:LobsRejectAll` | Reject all proposed changes |
| `:LobsConnect` | Manually connect to server |
| `:LobsDisconnect` | Disconnect |
| `:LobsStatus` | Show connection info |
| `:LobsAuth` | Re-authenticate (CF Access) |
| `:LobsAuth clear` | Clear cached auth token |
| `:LobsAuth status` | Check if token is valid |

## How it works

lobs-vim opens a WebSocket to lobs-core. When the AI agent needs to read files, run commands, or edit code, those tools execute **locally in your Neovim** — not on the server. The server handles LLM reasoning; your editor handles execution. This means the agent works with your actual project files, respects your local environment, and changes appear in your editor in real-time.

## License

MIT
