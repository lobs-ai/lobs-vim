-- lobs.nvim — Cloudflare Access authentication
-- Uses `cloudflared access tcp` to create a local proxy that handles
-- all CF Access auth automatically (browser login on first use).
--
-- Flow:
--   1. Start `cloudflared access tcp` proxy on a random local port
--   2. If no token cached, cloudflared opens browser for login
--   3. Proxy handles auth transparently — websocat connects to localhost
--   4. Token cached by cloudflared (~24h), auto-refreshes
local M = {}

---@class CfProxy
---@field port number Local port the proxy listens on
---@field process vim.SystemObj|nil
---@field ready boolean

---@type CfProxy|nil
M._proxy = nil

--- Find a free port by binding to 0 and reading back the port
---@return number
local function find_free_port()
  -- Use a random high port; cloudflared will error if it's taken
  -- and we can retry. This avoids needing luasocket.
  return 49152 + math.random(0, 16383)
end

--- Start the cloudflared access proxy for the given hostname.
--- Calls callback(port, err) when the proxy is ready or failed.
---@param config table
---@param callback fun(port: number|nil, err: string|nil)
function M.ensure_proxy(config, callback)
  local cf = config.cloudflare or {}
  if not cf.enabled then
    callback(nil, nil)
    return
  end

  -- Already running?
  if M._proxy and M._proxy.process and M._proxy.ready then
    callback(M._proxy.port, nil)
    return
  end

  -- Kill existing proxy if it's in a bad state
  M.stop_proxy()

  if vim.fn.executable("cloudflared") ~= 1 then
    callback(nil, "cloudflared not found. Install: brew install cloudflared")
    return
  end

  -- Extract hostname from server URL
  local hostname = config.server:match("wss?://([^/:]+)")
  if not hostname then
    callback(nil, "Can't extract hostname from: " .. config.server)
    return
  end

  local port = find_free_port()
  local listener = "localhost:" .. port

  vim.notify("Lobs: Starting auth proxy...", vim.log.levels.INFO)

  local ready = false
  local proxy = {
    port = port,
    process = nil,
    ready = false,
  }

  proxy.process = vim.system(
    {
      "cloudflared", "access", "tcp",
      "--hostname", hostname,
      "--url", listener,
      "--log-level", "error",
    },
    {
      text = true,
      stderr = function(_, data)
        if not data or data == "" then return end
        vim.schedule(function()
          local trimmed = data:gsub("%s+$", "")
          -- cloudflared prints connection info to stderr
          if trimmed ~= "" then
            -- If it mentions "failed" or "error", notify
            if trimmed:lower():match("failed") or trimmed:lower():match("error") then
              vim.notify("Lobs auth: " .. trimmed, vim.log.levels.ERROR)
            end
          end
        end)
      end,
    },
    function(_result)
      -- Process exited
      vim.schedule(function()
        if M._proxy == proxy then
          M._proxy = nil
        end
      end)
    end
  )

  M._proxy = proxy

  -- cloudflared takes a moment to start listening.
  -- Poll the port until it's accepting connections or timeout.
  local attempts = 0
  local max_attempts = 30 -- 3 seconds
  local function check_ready()
    attempts = attempts + 1
    -- Try connecting to the port
    vim.system(
      { "bash", "-c", string.format("echo | nc -w 1 localhost %d 2>/dev/null", port) },
      { text = true },
      function(result)
        vim.schedule(function()
          if result.code == 0 then
            proxy.ready = true
            ready = true
            vim.notify("Lobs: Connected through Cloudflare Access", vim.log.levels.INFO)
            callback(port, nil)
          elseif attempts >= max_attempts then
            M.stop_proxy()
            callback(nil, "Auth proxy failed to start (timeout). Run: cloudflared access login https://" .. hostname)
          else
            vim.defer_fn(check_ready, 100)
          end
        end)
      end
    )
  end

  -- Give cloudflared a moment to start before first check
  vim.defer_fn(check_ready, 200)
end

--- Stop the cloudflared proxy
function M.stop_proxy()
  if M._proxy and M._proxy.process then
    pcall(function() M._proxy.process:kill("SIGTERM") end)
  end
  M._proxy = nil
end

--- Clear auth (stop proxy, next connect will re-auth)
function M.clear_cache()
  M.stop_proxy()
  vim.notify("Lobs: Auth cleared — will re-authenticate on next connect", vim.log.levels.INFO)
end

--- Check if auth proxy is running
---@return boolean
function M.is_authenticated()
  return M._proxy ~= nil and M._proxy.ready
end

return M
