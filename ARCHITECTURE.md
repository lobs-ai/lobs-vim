# lobs-vim Architecture

## Status: Proposed
## Date: 2026-03-22
## Author: Architect Agent

---

## Problem Statement

Rafe uses Neovim (LazyVim) on his MacBook for coding. His personal AI agent system (lobs-core) runs on a remote server. He wants a Cursor-like coding experience inside Neovim — chat sidebar, inline completions, code actions, and the ability for the agent to read/write files and run commands on his LOCAL machine while also using server-side tools (web search, memory, subagents).

The fundamental challenge: **the agent lives on a remote machine but needs to operate on a local machine's filesystem and shell**. This is NOT a standard client-server relationship — it's a bidirectional one where the "server" (lobs-core) needs to call back into the "client" (Neovim) to execute tools.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Rafe's MacBook (local)                                  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Neovim + LazyVim                                 │    │
│  │  ┌────────────┐ ┌──────────┐ ┌───────────────┐   │    │
│  │  │ Chat Panel │ │ Diff View│ │ Ghost Text    │   │    │
│  │  │ (sidebar)  │ │ (inline) │ │ (completions) │   │    │
│  │  └─────┬──────┘ └────┬─────┘ └───────┬───────┘   │    │
│  │        │              │               │           │    │
│  │  ┌─────┴──────────────┴───────────────┴───────┐   │    │
│  │  │        lobs-vim  (Lua plugin)               │   │    │
│  │  │  ┌──────────┐ ┌───────────┐ ┌───────────┐  │   │    │
│  │  │  │ Protocol │ │ Tool Exec │ │ Completion│  │   │    │
│  │  │  │ Client   │ │ Sandbox   │ │ Engine    │  │   │    │
│  │  │  └─────┬────┘ └─────┬─────┘ └─────┬────┘  │   │    │
│  │  └────────┼─────────────┼─────────────┼───────┘   │    │
│  └───────────┼─────────────┼─────────────┼───────────┘    │
│              │             │             │                 │
│         WebSocket      Local exec   Direct HTTP           │
│         (chat +        (sandboxed)  (to LM Studio         │
│          tools)                      on server)           │
│              │                           │                 │
└──────────────┼───────────────────────────┼─────────────────┘
               │                           │
        ═══════╪═══════════════════════════╪══════ Network
               │                           │
┌──────────────┼───────────────────────────┼─────────────────┐
│  lobs-core server (:9420)                │                  │
│              │                           │                  │
│  ┌───────────┴───────────┐   ┌──────────┴──────────┐       │
│  │ WebSocket Endpoint    │   │ LM Studio (:1234)   │       │
│  │ /api/vim/ws           │   │ (local models)      │       │
│  │                       │   │                     │       │
│  │  - Chat messages      │   │ FIM completions     │       │
│  │  - Tool delegation    │   └─────────────────────┘       │
│  │  - SSE event bridge   │                                  │
│  │  - Session mgmt       │   ┌─────────────────────┐       │
│  └───────────┬───────────┘   │ Server-side tools   │       │
│              │               │ - web_search        │       │
│  ┌───────────┴───────────┐   │ - memory_search     │       │
│  │ Main Agent            │   │ - spawn_agent       │       │
│  │ (existing agent loop) │◄──│ - web_fetch         │       │
│  └───────────────────────┘   │ - imagine           │       │
│                              └─────────────────────┘       │
└────────────────────────────────────────────────────────────┘
```

---

## Communication Protocol Design

### Why WebSocket (not SSE + HTTP)

The existing Nexus chat uses HTTP POST (send message) + SSE (stream events). This works for a web frontend where the server does all the work. But lobs-vim has a **bidirectional requirement**: the server needs to ask the client to execute tools (read files, run commands on the local machine). SSE is server→client only.

**Decision: WebSocket** with a simple JSON-RPC-like protocol.

One WebSocket connection per Neovim instance. Multiplexed for:
1. **Client→Server**: Send chat messages, provide context, report tool results
2. **Server→Client**: Stream responses, request tool execution, send completions

### Inline Completions: Separate Fast Path

Inline completions go **directly to LM Studio** on the server via HTTP. They bypass the main agent entirely — no tool use, no memory search, just fast fill-in-the-middle (FIM) completions. This avoids the latency of the full agent loop for keystroke-triggered suggestions.

### Protocol Messages

All messages are JSON with a `type` field. Each request has an `id` for correlation.

#### Client → Server

```typescript
// Send a chat message
{
  type: "chat.send",
  id: "req-1",
  sessionKey: "vim-abc123",
  content: "refactor this function to use async/await",
  context: {
    file: "/Users/rafe/project/src/main.ts",
    filetype: "typescript",
    selection?: { startLine: 10, endLine: 25, text: "..." },
    cursor: { line: 15, col: 8 },
    // Surrounding buffer context the plugin auto-extracts
    visibleRange: { startLine: 1, endLine: 50 },
    bufferContent?: "...",   // Full file or visible portion
    openBuffers?: ["src/main.ts", "src/utils.ts"],
    gitBranch?: "feat/refactor",
    cwd: "/Users/rafe/project",
  }
}

// Respond to a tool execution request from the server
{
  type: "tool.result",
  id: "req-2",          // Matches the tool.request id
  toolUseId: "toolu_abc",
  content: "file contents here...",
  isError: false
}

// Create/resume a session
{
  type: "session.open",
  id: "req-3",
  projectRoot: "/Users/rafe/project",
  sessionKey?: "vim-abc123"  // Omit to create new
}

// Accept or reject a proposed diff
{
  type: "diff.resolve",
  id: "req-4",
  diffId: "diff-1",
  accepted: true
}
```

#### Server → Client

```typescript
// Streamed text delta (chat response)
{
  type: "chat.delta",
  sessionKey: "vim-abc123",
  content: "Here's how to refactor...",
  timestamp: 1234567890
}

// Agent is thinking / processing
{
  type: "chat.status",
  sessionKey: "vim-abc123",
  status: "thinking" | "tool_running" | "done" | "error",
  toolName?: "exec",
  toolInput?: "npm test"
}

// Request the CLIENT to execute a tool locally
{
  type: "tool.request",
  id: "req-tool-1",
  toolUseId: "toolu_abc",
  tool: "read",
  input: { path: "/Users/rafe/project/src/main.ts" }
}

// Proposed code change (diff)
{
  type: "diff.propose",
  diffId: "diff-1",
  file: "/Users/rafe/project/src/main.ts",
  hunks: [
    {
      startLine: 10,
      endLine: 25,
      original: "function fetchData(url, callback) {...}",
      replacement: "async function fetchData(url) {...}"
    }
  ]
}

// Session created/resumed
{
  type: "session.opened",
  sessionKey: "vim-abc123",
  title: "Refactoring session",
  resumedFrom?: "2026-03-22T10:00:00Z"
}
```

---

## Local Tool Execution Design

This is the crux of the architecture. The agent runs on the server but needs to operate on Rafe's machine.

### Tool Routing: Split Execution Model

When the agent calls a tool, lobs-core decides WHERE to execute it:

```
Agent calls tool ──► Tool Router ──┬── SERVER-SIDE (execute normally)
                                   │   - web_search, web_fetch
                                   │   - memory_search, memory_read, memory_write
                                   │   - spawn_agent, imagine
                                   │   - process, humanize
                                   │
                                   └── CLIENT-SIDE (delegate to plugin)
                                       - read, write, edit
                                       - exec (shell commands)
                                       - ls, grep, glob, find_files
                                       - code_search
```

### How Client-Side Tool Delegation Works

1. Agent loop calls `executeTool("read", { path: "/Users/rafe/project/src/main.ts" }, toolId, cwd)`
2. The **VimToolRouter** (new backend component) intercepts this for vim sessions
3. Instead of executing locally on the server, it sends a `tool.request` message over WebSocket
4. The Neovim plugin receives the request, executes it locally, sends `tool.result` back
5. The VimToolRouter returns the result to the agent loop as if the tool executed normally

The agent loop doesn't know or care — it just sees tool results. The routing is transparent.

```
┌─────────────────────────────────────┐
│ Agent Loop (processConversation)    │
│                                     │
│   calls executeTool("read", ...)    │
│              │                      │
│   ┌──────────▼──────────────────┐   │
│   │ VimToolExecutor             │   │
│   │ (replaces default for vim   │   │
│   │  sessions)                  │   │
│   │                             │   │
│   │  if tool in CLIENT_TOOLS:   │   │
│   │    send tool.request ──────────────► WebSocket ──► Plugin
│   │    await tool.result ◄─────────────── WebSocket ◄── Plugin
│   │    return result            │   │
│   │                             │   │
│   │  else:                      │   │
│   │    executeTool normally     │   │
│   │    (server-side)            │   │
│   └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

### Security: Local Tool Sandbox

The plugin executes tools in a controlled way:

- **`read`**: Only reads files under the project root (or paths explicitly allowed by the user). Respects `.gitignore`. The plugin shows a notification for files outside the project root and asks for confirmation on first access.
- **`write` / `edit`**: Creates a diff proposal (`diff.propose`) instead of writing directly. The user must accept/reject. Only after acceptance does the plugin apply the change. (Optionally, a "trust mode" config lets writes happen automatically.)
- **`exec`**: Runs in the project's working directory. Shows the command in the chat panel. Output is streamed back. Long-running commands have a configurable timeout (default 30s). Dangerous commands (rm -rf, etc.) show a confirmation prompt.
- **`grep` / `glob` / `find_files` / `ls` / `code_search`**: Read-only, scoped to project root. Execute freely.

### Tool Execution Timeout

If the plugin doesn't respond to a `tool.request` within 30 seconds, the server sends an error tool result back to the agent: `"Tool execution timed out — the Neovim client did not respond. The user may have disconnected."` This prevents the agent loop from hanging indefinitely.

---

## Plugin Structure

```
lobs-vim/
├── lua/
│   └── lobs/
│       ├── init.lua              -- Plugin entry point, setup(), lazy.nvim config
│       ├── config.lua            -- Configuration defaults and user overrides
│       ├── client.lua            -- WebSocket client (connection, auth, reconnect)
│       ├── protocol.lua          -- Message serialization, request/response correlation
│       ├── session.lua           -- Session lifecycle (create, resume, list)
│       │
│       ├── chat/
│       │   ├── init.lua          -- Chat panel orchestration
│       │   ├── panel.lua         -- Sidebar buffer/window management
│       │   ├── render.lua        -- Markdown rendering in chat buffer
│       │   ├── input.lua         -- Input area handling (multi-line, submit)
│       │   └── history.lua       -- Chat history navigation, session switching
│       │
│       ├── complete/
│       │   ├── init.lua          -- Completion orchestration
│       │   ├── fim.lua           -- Fill-in-the-middle prompt construction
│       │   ├── ghost.lua         -- Virtual text / ghost text rendering
│       │   └── debounce.lua      -- Request debouncing and cancellation
│       │
│       ├── actions/
│       │   ├── init.lua          -- Code action registration
│       │   ├── refactor.lua      -- Refactor action (selection → agent)
│       │   ├── explain.lua       -- Explain code action
│       │   ├── tests.lua         -- Generate tests action
│       │   └── fix.lua           -- Fix errors/diagnostics action
│       │
│       ├── diff/
│       │   ├── init.lua          -- Diff orchestration
│       │   ├── apply.lua         -- Parse and apply diffs to buffers
│       │   ├── review.lua        -- Inline diff review UI (accept/reject per hunk)
│       │   └── undo.lua          -- Undo applied changes (buffer checkpoints)
│       │
│       ├── tools/
│       │   ├── init.lua          -- Tool execution dispatcher
│       │   ├── read.lua          -- File reading (with gitignore awareness)
│       │   ├── write.lua         -- File writing (via diff proposal)
│       │   ├── edit.lua          -- File editing (search/replace, via diff proposal)
│       │   ├── exec.lua          -- Shell command execution (jobstart)
│       │   ├── grep.lua          -- Ripgrep wrapper
│       │   ├── ls.lua            -- Directory listing
│       │   ├── glob.lua          -- File globbing
│       │   ├── find_files.lua    -- File finder
│       │   └── sandbox.lua       -- Path validation, confirmation prompts
│       │
│       └── util/
│           ├── ws.lua            -- WebSocket implementation (pure Lua or via curl)
│           ├── http.lua          -- HTTP client (for completions, health checks)
│           ├── json.lua          -- JSON encode/decode (vim.json)
│           ├── notify.lua        -- Notification helpers (vim.notify)
│           └── context.lua       -- Buffer/file context extraction
│
├── plugin/
│   └── lobs.lua                  -- Auto-commands, commands registration
│
├── doc/
│   └── lobs-vim.txt              -- Vim help documentation
│
├── ARCHITECTURE.md               -- This document
├── README.md                     -- User-facing docs
└── stylua.toml                   -- Lua formatter config
```

### Dependencies

**Required:**
- Neovim ≥ 0.10 (for `vim.system`, improved virtual text, `vim.json`)
- `lazy.nvim` (plugin manager — for LazyVim compatibility)
- `curl` CLI (for WebSocket via `vim.system` or for HTTP fallback)

**Optional (recommended):**
- `nui.nvim` — for the chat sidebar panel UI (floating/split windows with borders)
- `plenary.nvim` — async primitives, if needed for complex flows
- `nvim-treesitter` — for syntax-aware code context extraction

**No companion binary required.** The plugin is pure Lua. WebSocket is implemented via Neovim's built-in `vim.system` with `curl --no-buffer` for the persistent connection, similar to how copilot.vim handles its LSP connection. For inline completions, standard HTTP requests to LM Studio are sufficient.

### WebSocket Implementation Detail

Neovim doesn't have a built-in WebSocket client. Options:

1. **`vim.system` + `curl --no-buffer`** — Use curl's WebSocket support (`curl --no-buffer -H "Connection: Upgrade" -H "Upgrade: websocket" ...`). Requires curl ≥ 7.86 (macOS ships with a recent enough version via Homebrew). Pros: no dependencies. Cons: curl's WebSocket support is experimental.

2. **`vim.loop` (libuv) raw TCP + WebSocket handshake** — Implement the WebSocket protocol over libuv's TCP stream. This is what several Neovim plugins do. Pros: no external dependencies, full control. Cons: more code to write/maintain.

3. **`websocat` CLI tool** — External binary. Pros: simple. Cons: extra dependency.

**Recommendation: Option 2 (libuv TCP).** It's the most reliable and dependency-free approach. The WebSocket handshake is straightforward (HTTP upgrade + SHA-1 accept key), and libuv's stream API handles the event loop integration naturally. Several reference implementations exist in the Neovim ecosystem. We can vendor a minimal WebSocket implementation (~200-300 lines of Lua).

---

## Backend Changes Needed in lobs-core

### 1. WebSocket Endpoint: `/api/vim/ws`

New file: `src/api/vim-ws.ts`

The HTTP server upgrades connections on this path to WebSocket. This endpoint:

- Authenticates via a token in the `Authorization` header or `?token=` query param
- Creates a `VimSession` object that tracks the connected editor's state
- Bridges the WebSocket to the MainAgent's `handleMessage` / `events` system
- Routes tool execution requests through the WebSocket instead of local execution

```typescript
// Conceptual — not implementation code, just showing the interface
interface VimSession {
  ws: WebSocket;
  sessionKey: string;         // Maps to a chat session in the DB
  channelId: string;          // "vim:<sessionKey>" — unique channel for MainAgent
  projectRoot: string;        // Client's project root path
  pendingToolRequests: Map<string, {
    resolve: (result: ToolResult) => void;
    reject: (error: Error) => void;
    timeout: NodeJS.Timeout;
  }>;
}
```

### 2. VimToolExecutor: Client-Side Tool Routing

New file: `src/runner/tools/vim-executor.ts`

A custom tool executor that intercepts tool calls for vim sessions and routes them to the client:

```typescript
// Tools that should execute on the CLIENT (Neovim) side
const CLIENT_TOOLS = new Set([
  "read", "write", "edit", "exec", "ls", "grep",
  "glob", "find_files", "code_search"
]);

// Tools that stay on the SERVER
const SERVER_TOOLS = new Set([
  "web_search", "web_fetch", "memory_search", "memory_read",
  "memory_write", "spawn_agent", "process", "humanize",
  "imagine", "html_to_pdf"
]);
```

When the agent loop calls `executeTool` for a vim session:
- If `CLIENT_TOOLS`, send `tool.request` over WebSocket, await `tool.result`
- If `SERVER_TOOLS`, execute normally on the server
- The `cwd` for all tool calls is the **client's project root**, not the server's filesystem

### 3. New Session Type: `vim`

Add `"vim"` to the `SessionType` union in `tool-sets.ts`. Vim sessions get the same tools as Nexus sessions but tool execution is routed differently (via the VimToolExecutor).

### 4. Completion Proxy (Optional)

If LM Studio isn't directly reachable from Rafe's MacBook (e.g., it's only listening on localhost on the server), add a proxy endpoint:

```
GET /api/vim/complete
```

That forwards FIM completion requests to LM Studio's `/v1/completions` endpoint. This avoids needing to expose LM Studio's port externally.

### 5. Context-Enhanced System Prompt for Vim Sessions

Vim sessions should get an augmented system prompt that includes:
- The user's current file path and filetype
- The visible code context (sent with each message)
- Instructions about using the tools to read/write files on the user's machine
- Awareness that tool execution happens remotely (on the user's machine, not the server)

---

## Data Flow: Chat

```
User types message in chat panel
         │
         ▼
┌─ Plugin ─────────────────────┐
│ 1. Gather context:           │
│    - Current file + filetype │
│    - Selection (if any)      │
│    - Cursor position         │
│    - Visible range           │
│    - Git branch              │
│    - Open buffers            │
│    - Diagnostics (LSP)       │
│                              │
│ 2. Send via WebSocket:       │
│    { type: "chat.send",      │
│      content: "...",         │
│      context: {...} }        │
└──────────┬───────────────────┘
           │ WebSocket
           ▼
┌─ lobs-core ──────────────────┐
│ 3. VimWsHandler receives msg │
│ 4. Injects context into      │
│    message content:          │
│    "User is editing main.ts  │
│     at line 15. Selection:   │
│     [code]. Question: ..."   │
│                              │
│ 5. Sends to MainAgent via    │
│    handleMessage() with      │
│    channelId "vim:session"   │
│                              │
│ 6. Agent loop runs:          │
│    - LLM processes message   │
│    - May call tools          │
│      └─ CLIENT tools:        │
│         tool.request ──────────────► Plugin executes
│         tool.result  ◄─────────────── Plugin returns
│      └─ SERVER tools:        │
│         execute locally      │
│    - Generates response      │
│                              │
│ 7. Stream events via         │
│    MainAgent.events →        │
│    WebSocket messages         │
│    (thinking, tool_start,    │
│     tool_result, text_delta, │
│     assistant_reply, done)   │
└──────────┬───────────────────┘
           │ WebSocket
           ▼
┌─ Plugin ─────────────────────┐
│ 8. Render in chat panel:     │
│    - "thinking" → spinner    │
│    - "tool_start" → tool UI  │
│    - "text_delta" → stream   │
│      markdown text           │
│    - "assistant_reply" →     │
│      final render            │
│                              │
│ 9. If response contains      │
│    code changes → show diff  │
└──────────────────────────────┘
```

---

## Data Flow: Inline Completions

```
User types in buffer
         │
         ▼ (debounced, ~300ms idle)
┌─ Plugin ─────────────────────────┐
│ 1. Build FIM prompt:             │
│    - Prefix: code before cursor  │
│    - Suffix: code after cursor   │
│    - File path (for lang hint)   │
│    - Neighboring file snippets   │
│      (from open buffers)         │
│                                  │
│ 2. HTTP POST to server:          │
│    /api/vim/complete             │
│    { prefix, suffix, filepath,   │
│      maxTokens: 128,             │
│      temperature: 0.1 }          │
│                                  │
│ 3. Cancel any in-flight request  │
│    before sending new one        │
└──────────┬───────────────────────┘
           │ HTTP
           ▼
┌─ lobs-core ──────────────────────┐
│ 4. Proxy to LM Studio:          │
│    POST :1234/v1/completions     │
│    model: "qwen2.5-coder-7b"    │
│    prompt: FIM-formatted         │
│    stop: ["\n\n", "```"]         │
│                                  │
│ 5. Return completion text        │
└──────────┬───────────────────────┘
           │ HTTP response
           ▼
┌─ Plugin ─────────────────────────┐
│ 6. Show as ghost text:           │
│    - vim.api.nvim_buf_set_extmark│
│      with virt_text_pos="inline" │
│    - Dim/grey color              │
│                                  │
│ 7. Tab to accept, Esc to dismiss│
│    Any other keystroke cancels   │
│    and re-triggers debounce      │
└──────────────────────────────────┘
```

### FIM Prompt Format

Use Qwen's FIM format (or whatever model LM Studio is running):

```
<|fim_prefix|>{code before cursor}<|fim_suffix|>{code after cursor}<|fim_middle|>
```

The plugin constructs this from the current buffer, including ~200 lines of context above and below the cursor. For multi-file context, the prompt can include snippets from open buffers as a "repository context" header.

---

## Data Flow: Code Actions

```
User selects code → triggers action (e.g., <leader>ar for "refactor")
         │
         ▼
┌─ Plugin ─────────────────────────────────────┐
│ 1. Get selection text, file path, filetype   │
│ 2. Build action prompt:                      │
│    "Refactor the following TypeScript code.   │
│     File: src/main.ts (lines 10-25)          │
│     [selected code]                          │
│     Suggest improvements and show as a diff."│
│ 3. Send as chat.send with context            │
└──────────┬───────────────────────────────────┘
           │ (same as chat flow)
           ▼
         Agent processes, may read related files,
         responds with explanation + code changes
           │
           ▼
┌─ Plugin ─────────────────────────────────────┐
│ 4. Parse agent response for code blocks      │
│ 5. If code changes detected:                 │
│    → Create diff.propose for affected file   │
│    → Show inline diff review                 │
│ 6. Chat panel shows the explanation          │
└──────────────────────────────────────────────┘
```

---

## Data Flow: Apply Diffs

When the agent suggests code changes (either via explicit `write`/`edit` tool calls, or via code blocks in chat), the plugin shows a reviewable diff:

```
┌─ Agent calls write/edit tool ────────────────┐
│ VimToolExecutor intercepts:                  │
│ Instead of writing directly, sends           │
│ diff.propose to the plugin                   │
└──────────┬───────────────────────────────────┘
           │ WebSocket
           ▼
┌─ Plugin ─────────────────────────────────────┐
│ 1. Open the target file in a buffer          │
│    (if not already open)                     │
│ 2. Create a diff view:                       │
│    Option A: Inline highlights               │
│      - Deleted lines: red background         │
│      - Added lines: green background         │
│      - Unchanged: normal                     │
│      - Virtual text gutter: [Accept] [Reject]│
│                                              │
│    Option B: Side-by-side split              │
│      - Left: original file (readonly)        │
│      - Right: proposed changes               │
│      - Diff highlights via vim's diff mode   │
│                                              │
│ 3. Keybindings:                              │
│    <CR> or `ga` — Accept all changes         │
│    `gA` — Accept current hunk                │
│    `gr` — Reject all changes                 │
│    `gR` — Reject current hunk                │
│    `]c` / `[c` — Jump between hunks          │
│                                              │
│ 4. On Accept:                                │
│    - Apply changes to buffer                 │
│    - Save file (if auto-save enabled)        │
│    - Send diff.resolve { accepted: true }    │
│    - VimToolExecutor returns success to agent│
│                                              │
│ 5. On Reject:                                │
│    - Discard proposed changes                │
│    - Send diff.resolve { accepted: false }   │
│    - VimToolExecutor returns "User rejected  │
│      the proposed changes" to agent          │
│    - Agent may revise and try again          │
└──────────────────────────────────────────────┘
```

### Diff Detection from Chat Responses

When the agent responds in chat with code blocks (not via tool calls), the plugin detects this pattern:

```markdown
Here's the refactored code:

```typescript
// file: src/main.ts
async function fetchData(url: string): Promise<Data> {
  const response = await fetch(url);
  return response.json();
}
```​
```

The plugin extracts code blocks with file path hints and offers to apply them as diffs. This is a convenience — the primary flow uses the `write`/`edit` tool calls.

---

## Session Model

### One Session Per Project Root

Each unique project root (`cwd`) maps to one persistent session. Sessions survive Neovim restarts.

```lua
-- When Neovim opens:
-- 1. Compute project root (git root or cwd)
-- 2. Look up existing session: GET /api/chat/sessions?label=vim:<project_root>
-- 3. If found: resume (show last N messages in chat panel)
-- 4. If not found: create new session
```

### Session Persistence

Sessions are stored on the lobs-core server (in the existing `chat_sessions` / `chat_messages` tables). The plugin only stores:
- `~/.config/lobs-vim/sessions.json` — mapping of project roots to session keys
- `~/.config/lobs-vim/config.lua` — user preferences

### Multiple Neovim Instances

If two Neovim instances open the same project, they share the session. Both connect via WebSocket to the same `channelId`. Events are broadcast to all connected clients. This means chat history stays synchronized. Tool execution requests go to whichever client is connected (or the most recently active one if multiple).

---

## Authentication

### Token-Based Auth

The plugin stores an API token in `~/.config/lobs-vim/auth.json`:

```json
{
  "server": "https://lobs-core.example.com:9420",
  "token": "lobs_vim_xxxxxxxxxxxxx"
}
```

The token is sent in the WebSocket upgrade request:
```
GET /api/vim/ws HTTP/1.1
Authorization: Bearer lobs_vim_xxxxxxxxxxxxx
Upgrade: websocket
```

And in HTTP requests (completions):
```
Authorization: Bearer lobs_vim_xxxxxxxxxxxxx
```

### Token Generation

A new command in lobs-core: `POST /api/vim/auth` (authenticated via existing admin auth) generates a long-lived token for the vim plugin. The token is scoped to vim operations only.

Alternatively, for simplicity in v1: reuse the existing API auth mechanism (if lobs-core has one), or use a shared secret set via environment variable.

---

## Security Considerations

### 1. Local Tool Execution is the Attack Surface

If someone compromises the WebSocket connection, they could:
- Read arbitrary files on Rafe's machine
- Execute arbitrary commands on Rafe's machine

**Mitigations:**
- TLS (wss://) for the WebSocket connection
- Token authentication on every connection
- **Path sandboxing**: The plugin restricts `read` to the project root and `~/.config` by default. Reads outside this require explicit user confirmation (a prompt in Neovim).
- **Command allowlist** (optional): In paranoid mode, only allow commands matching patterns like `npm *`, `git *`, `make *`, etc.
- **Write-through-diff**: All writes go through the diff review flow by default. The agent cannot silently modify files.
- **Rate limiting**: Max N tool executions per minute to prevent runaway agents.

### 2. Network Security

- The WebSocket should use TLS (wss://) in production
- For local development (same machine), plain ws:// is acceptable
- The token should be generated with sufficient entropy (256-bit random)

### 3. Exec Safety

- Commands run with the user's permissions (not elevated)
- Default timeout of 30 seconds per command
- The plugin logs all executed commands to a local audit log (`~/.local/share/lobs-vim/audit.log`)
- Interactive commands (those requiring stdin) are not supported — the plugin sends empty stdin

---

## User Interface Details

### Chat Panel

- **Position**: Right sidebar, configurable width (default 80 columns)
- **Layout**: Scrollable message history + fixed input area at bottom
- **Input**: Multi-line textarea. `<CR>` in insert mode adds a newline. `<C-CR>` or `<leader>ls` submits. `<C-c>` cancels in-progress response.
- **Rendering**: Messages rendered as markdown using Neovim's treesitter markdown parser. Code blocks get syntax highlighting. Links are clickable (open in browser).
- **Status indicators**: Spinner when agent is thinking. Tool call badges (`🔧 reading src/main.ts`). Token usage in status line.
- **Toggle**: `<leader>lc` opens/closes the chat panel.

### Keybindings (Default)

```
<leader>lc  — Toggle chat panel
<leader>ls  — Submit chat message (from chat input)
<leader>la  — Code action menu (refactor/explain/test/fix)
<leader>lr  — Refactor selection
<leader>le  — Explain selection
<leader>lt  — Generate tests for selection
<leader>lf  — Fix diagnostics at cursor
<leader>ld  — Show/hide diff for pending changes
<C-y>       — Accept inline completion (ghost text)
<C-]>       — Next inline completion suggestion
<C-[>       — Previous inline completion suggestion
<Esc>       — Dismiss inline completion
```

All keybindings are configurable via the setup function.

---

## Implementation Phases

### Phase 1: Foundation (1 week)

**Goal: Chat works end-to-end.**

1. **Backend**: WebSocket endpoint (`/api/vim/ws`), session management, event bridging
2. **Plugin**: WebSocket client, chat panel with basic markdown rendering, message sending
3. **Context**: Plugin sends current file + cursor position with every message
4. **No tool delegation yet** — the agent uses server-side files only (proof of concept)

**Deliverables**: Can have a conversation with the agent from Neovim. Agent can use server-side tools (web search, memory). No file operations on local machine yet.

### Phase 2: Local Tool Execution (1 week)

**Goal: Agent can read/write files and run commands on Rafe's machine.**

1. **Backend**: VimToolExecutor — routes read/exec/grep etc. to client via WebSocket
2. **Plugin**: Tool execution sandbox — `read`, `exec`, `grep`, `ls`, `glob`, `find_files`
3. **Plugin**: `write`/`edit` → diff proposal flow (the core of the Cursor experience)
4. **Diff UI**: Inline diff review with accept/reject per hunk
5. **Path sandboxing**: Restrict file access to project root

**Deliverables**: Full agent coding workflow — "read the file, understand it, modify it, run tests, fix issues."

### Phase 3: Inline Completions (3-5 days)

**Goal: Ghost text suggestions as you type, like Copilot.**

1. **Backend**: Completion proxy endpoint (`/api/vim/complete`) → LM Studio
2. **Plugin**: FIM prompt construction from buffer context
3. **Plugin**: Ghost text rendering via extmarks
4. **Plugin**: Debouncing, cancellation, Tab to accept
5. **Multi-file context**: Include snippets from open buffers in FIM prompt

**Deliverables**: Fast, local-model-powered inline completions that feel responsive.

### Phase 4: Code Actions + Polish (3-5 days)

**Goal: Quick actions on selected code, overall UX polish.**

1. **Code actions**: Refactor, explain, test, fix — selection-based prompts
2. **Diagnostics integration**: "Fix this error" action using LSP diagnostic info
3. **Chat history**: Session switching, search, persistence
4. **Status line**: Connection status, model info, token usage
5. **Documentation**: vim help file, README with setup instructions
6. **Error handling**: Reconnection logic, graceful degradation when server is down

**Deliverables**: Production-ready plugin with comprehensive feature set.

### Phase 5: Advanced Features (ongoing)

- **Streaming code diffs**: Show code changes as they stream in, not just at the end
- **Multi-file operations**: Agent working across multiple files with coordinated diffs
- **Project-wide context**: Automatic codebase indexing for better context
- **Image support**: Show generated images (from `imagine` tool) inline in chat
- **Voice input**: Integration with macOS dictation for voice-to-chat
- **Custom actions**: User-defined code actions with custom prompts

---

## Trade-offs

### WebSocket vs. HTTP+SSE
- **Chose WebSocket** for bidirectional communication (tool delegation requires server→client calls)
- **Trade-off**: More complex connection management (reconnection, heartbeats) vs. simpler SSE
- **Alternative rejected**: Having the plugin poll for tool requests — adds latency, wastes bandwidth

### Pure Lua vs. Companion Binary
- **Chose pure Lua** for zero-dependency installation and LazyVim compatibility
- **Trade-off**: WebSocket implementation in Lua is more work; some operations (like advanced diffing) would be easier in a compiled language
- **Alternative rejected**: A companion Node.js/Go binary — adds install complexity, version management headaches, and fights LazyVim's plugin model

### Diff-First Writes vs. Direct Writes
- **Chose diff-first** for safety — all agent writes go through review by default
- **Trade-off**: Slower workflow for large changes (user must review each diff)
- **Mitigation**: "Trust mode" config option for experienced users who want auto-apply
- **Alternative rejected**: Direct writes with undo — too risky, user may not notice unwanted changes

### Separate Completion Path vs. Through Agent
- **Chose separate HTTP path** direct to LM Studio for completions
- **Trade-off**: Two separate connections/protocols to maintain
- **Rationale**: Completions need <200ms latency. The agent loop has tool use overhead, session management, context loading — unsuitable for keystroke-triggered suggestions. LM Studio FIM is purpose-built for this.

### Session Per Project vs. Per Neovim Instance
- **Chose per project** for continuity across restarts
- **Trade-off**: Multiple instances of the same project share a session (could cause confusion)
- **Mitigation**: Show which client is active; tool requests go to the most recent client

---

## Open Questions

1. **WebSocket library**: Should we vendor a minimal WebSocket implementation (~300 lines) or use an existing Neovim plugin? Leaning toward vendoring for reliability and zero-dependency guarantee.

2. **Markdown rendering depth**: How much markdown do we render? Full spec (tables, images, links) or just headers, bold, code blocks? Start simple, expand as needed.

3. **Trust mode default**: Should `write`/`edit` require diff review by default, or should we trust the agent? For v1, diff review is mandatory. Can add trust mode later.

4. **Multiple LM Studio models**: Should the completion endpoint let the user choose between different LM Studio models? For v1, hardcode the fastest available model. Expose model selection in v2.

5. **Offline mode**: What happens when lobs-core is unreachable? Should the plugin fall back to local-only completions via LM Studio directly? Worth considering for Phase 5.

---

## Appendix: Existing lobs-core Integration Points

### Chat API (existing, reusable for context)
- `POST /api/chat/sessions` — Create session
- `POST /api/chat/sessions/:key/messages` — Send message (existing SSE-based flow)
- `GET /api/chat/sessions/:key/messages` — Get history
- `GET /api/chat/sessions/:key/stream` — SSE event stream

The WebSocket endpoint (`/api/vim/ws`) will internally use the same `MainAgent.handleMessage()` and `MainAgent.events` system that the SSE endpoint uses. The difference is transport (WebSocket vs. HTTP+SSE) and tool routing (client-side vs. server-side).

### MainAgent Integration
- Channel ID format: `vim:<session-key>` (like `nexus:` for web chat)
- Session type: `vim` (new, maps to same tool set as `nexus` but with client-side routing)
- Events: Same `AgentStreamEvent` types, bridged over WebSocket instead of SSE

### Tool Set
Vim sessions use the same tools as Nexus sessions:
```
exec, read, write, edit, ls, grep, glob, find_files, code_search,
web_search, web_fetch, memory_search, memory_read, memory_write,
spawn_agent, process, humanize, imagine, html_to_pdf
```

Split into client-side and server-side execution as described above.
