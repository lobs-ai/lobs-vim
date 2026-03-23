# lobs.nvim

AI coding agent for Neovim. Connects to [lobs-core](https://github.com/lobs-ai/lobs-core) — tools run locally in your editor, reasoning runs on the server.

## Install

**LazyVim / lazy.nvim:**

```lua
return {
  url = "git@github.com:lobs-ai/lobs-vim",
  opts = {
    server = "wss://your-server.example.com",
  },
}
```

Point `server` at your lobs-core instance. First time you connect, your browser opens for a quick email auth. After that it just works (token cached ~24h).

## Requirements

- Neovim ≥ 0.10
- [websocat](https://github.com/vi/websocat) — `brew install websocat`
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/) — `brew install cloudflared` (for remote servers behind CF Access)

## Configuration

```lua
return {
  url = "git@github.com:lobs-ai/lobs-vim",
  opts = {
    -- Server URL (your lobs-core instance)
    server = "wss://your-server.example.com",

    -- Cloudflare Access (auto-detected if using CF tunnels, no secrets needed)
    cloudflare = {
      enabled = nil,  -- nil = auto-detect from URL
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
| `:LobsConnect` | Connect to server |
| `:LobsDisconnect` | Disconnect |
| `:LobsStatus` | Show connection info |
| `:LobsAuth` | Force re-authenticate |
| `:LobsAuth clear` | Clear cached token |

## How it works

lobs-vim opens a WebSocket to lobs-core. When the AI agent needs to read files, run commands, or edit code, those tools execute **locally in your Neovim** — not on the server. The server handles LLM reasoning; your editor handles execution.

### Auth flow

No secrets in your config. Authentication uses `cloudflared` (Cloudflare's CLI):

1. `:LobsConnect` → `cloudflared` checks for a cached token
2. If no token, opens your browser → Cloudflare Access login (email code)
3. Token cached locally (~24h), auto-refreshes when expired
4. All automatic after first login

## License

MIT
