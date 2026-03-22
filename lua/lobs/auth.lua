-- lobs.nvim — Cloudflare Access authentication
-- Uses `cloudflared` CLI for browser-based login. No secrets in config.
--
-- Flow:
--   1. First connect: `cloudflared access login <url>` opens browser
--   2. User authenticates via email code (one click)
--   3. JWT cached locally by cloudflared
--   4. Token sent as CF_Authorization cookie on WebSocket upgrade
--   5. On expiry, browser opens again automatically
local M = {}

--- Get the Access URL from config (HTTPS version of the server URL)
---@param config table
---@return string
local function get_access_url(config)
  local cf = config.cloudflare or {}
  if cf.url then return cf.url end
  -- Convert ws(s)://host → https://host (strip path)
  local url = config.server:gsub("^wss://", "https://"):gsub("^ws://", "http://")
  return url:match("^https?://[^/]+") or url
end

--- Check if a string looks like a JWT (three base64url segments)
---@param s string
---@return boolean
local function looks_like_jwt(s)
  return s:match("^[A-Za-z0-9_%-]+%.[A-Za-z0-9_%-]+%.[A-Za-z0-9_%-]+$") ~= nil
end

--- Extract a JWT from cloudflared output (may contain error text too)
---@param stdout string
---@return string|nil
local function extract_token(stdout)
  if not stdout then return nil end
  -- cloudflared access token outputs just the JWT, possibly with whitespace
  local trimmed = stdout:gsub("^%s+", ""):gsub("%s+$", "")
  if looks_like_jwt(trimmed) then
    return trimmed
  end
  -- If there's extra output, search line by line
  for line in stdout:gmatch("[^\r\n]+") do
    local lt = line:gsub("^%s+", ""):gsub("%s+$", "")
    if looks_like_jwt(lt) then
      return lt
    end
  end
  return nil
end

--- Get a valid CF Access token. Async — calls callback(token, err).
---@param config table
---@param callback fun(token: string|nil, err: string|nil)
function M.get_token(config, callback)
  local cf = config.cloudflare or {}
  if not cf.enabled then
    callback(nil, nil)
    return
  end

  if vim.fn.executable("cloudflared") ~= 1 then
    callback(nil, "cloudflared not found. Install: brew install cloudflared")
    return
  end

  local url = get_access_url(config)

  -- Try non-interactive token fetch first (works if previously logged in)
  vim.system(
    { "cloudflared", "access", "token", url },
    { text = true },
    function(result)
      vim.schedule(function()
        local token = extract_token(result.stdout or "")
        if token then
          callback(token, nil)
        else
          -- No cached token — need interactive login
          M._interactive_login(url, callback)
        end
      end)
    end
  )
end

--- Run interactive cloudflared login (opens browser)
---@param url string
---@param callback fun(token: string|nil, err: string|nil)
function M._interactive_login(url, callback)
  vim.notify("Lobs: Opening browser for authentication...", vim.log.levels.INFO)

  vim.system(
    { "cloudflared", "access", "login", "--auto-close", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local err = (result.stderr or ""):gsub("%s+$", "")
          if err == "" then err = "login failed" end
          callback(nil, "Auth failed: " .. err)
          return
        end

        -- Login succeeded — fetch the token
        vim.system(
          { "cloudflared", "access", "token", url },
          { text = true },
          function(token_result)
            vim.schedule(function()
              local token = extract_token(token_result.stdout or "")
              if token then
                callback(token, nil)
              else
                callback(nil, "Login succeeded but couldn't retrieve token")
              end
            end)
          end
        )
      end)
    end
  )
end

--- Check if we can get a token without user interaction
---@param config table
---@param callback fun(ok: boolean)
function M.check_status(config, callback)
  local cf = config.cloudflare or {}
  if not cf.enabled then
    callback(true)
    return
  end
  if vim.fn.executable("cloudflared") ~= 1 then
    callback(false)
    return
  end
  local url = get_access_url(config)
  vim.system(
    { "cloudflared", "access", "token", url },
    { text = true },
    function(result)
      vim.schedule(function()
        callback(extract_token(result.stdout or "") ~= nil)
      end)
    end
  )
end

--- Clear cloudflared's cached token
function M.clear_cache()
  -- cloudflared stores tokens in ~/.cloudflared/
  -- We can't easily clear just one, but re-login will overwrite
  vim.notify("Lobs: Next connect will re-authenticate", vim.log.levels.INFO)
end

return M
