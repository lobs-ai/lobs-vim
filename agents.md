# lobs.nvim — Agent Reference

## What It Is
lobs.nvim is a Neovim plugin that connects directly to lobs-core, bringing agent assistance into the editor. It provides LSP-like features (go-to-definition, find references, inline edits), conversational interaction via a side panel, and project-aware context injection.

## Ecosystem Role
The Neovim client for lobs-core. While lobs-core exposes a REST API and Discord interface, lobs.nvim provides a first-class editor experience. It is the preferred UI for developers who want agent assistance without leaving their IDE.

## Build & Run

```bash
# Install dependencies
npm install

# Build the TypeScript source
npm run build

# Run tests
npm test

# Install the plugin (add to your Neovim plugin manager)
# Then configure in init.nvim:
#   lua require('lobs').setup({ url = 'http://localhost:3000' })

# Environment variables:
# LOBS_API_URL           — lobs-core API URL (default: http://localhost:3000)
# LOBS_API_KEY           — Optional API key for auth
```

## Key Conventions
- **Neovim-only** — Requires Neovim 0.9+; not compatible with vanilla Vim
- **Lua configuration** — Plugin configured via Lua, not Vimscript
- **LSP-like interface** — Provides standard LSP operations (goto, hover, refs, inline-edit)
- **Side panel** — Conversational UI rendered in Neovim floating/floating wins
- **TypeScript core** — Plugin logic in TypeScript, exposed to Lua via compiled JS
- **Local-first** — Connects to local lobs-core by default; supports remote

## Project Structure
```
src/
  lsp/               — LSP protocol implementation (handlers, protocol types)
  panel/             — Side panel UI (conversation view)
  edit/              — Inline edit engine (apply agent suggestions to buffers)
  hooks/             — Neovim hooks (cursor, save, change events)
  core/
    client.ts        — HTTP client for lobs-core API
    state.ts         — Plugin state management
    config.ts        — Configuration loader
lua/
  lobs/              — Lua wrapper around compiled JS
  lobs/setup.lua     — User-facing setup() API
tests/
  lsp.test.ts
  panel.test.ts
package.json
ARCHITECTURE.md     — Detailed system design
```
