-- lobs.nvim — Cloudflare Access authentication
-- Uses `cloudflared` CLI for browser-based login. No secrets in config.
--
-- Flow:
--   1. First connect: `cloudflared access login <url>` opens browser
--   2. User authenticates via email code (one click)
--   3. JWT cached locally by cloudflared + our own cache with expiry tracking
--   4. Subsequent connects use cached token until expiry (~24h)
--   5. On expiry, browser opens again automatically
local M = {}

local CACHE_DIR = vim.fn.stdpath("cache") .. "/lobs"
local TOKEN_FILE = CACHE_DIR .. "/cf_token"

--- Get the Access URL from config (HTTPS version of the server URL)
---@param config table
---@return string
local function get_access_url(config)
  local cf = config.cloudflare or {}
  if cf.url then
    return cf.url
  end
  -- Convert ws(s)://host/path → https://host
  local url = config.server:gsub("^wss://", "https://"):gsub("^ws://", "http://")
  -- Strip path — CF Access authenticates against the hostname
  return url:match("^https?://[^/]+") or url
end

--- Check if a string looks like a JWT (three base64url-encoded segments)
---@param s string
---@return boolean
local function looks_like_jwt(s)
  return s:match("^[A-Za-z0-9_%-]+%.[A-Za-z0-9_%-]+%.[A-Za-z0-9_%-]+$") ~= nil
end

--- Read cached token from disk
---@return string|nil token, number|nil expiry_ts
local function read_cached_token()
  local f = io.open(TOKEN_FILE, "r")
  if not f then return nil, nil end
  local content = f:read("*a")
  f:close()

  -- Format: <token>\n<expiry_timestamp>
  local token, expiry_str = content:match("^(.+)\n(%d+)$")
  if not token then
    token = content:gsub("%s+$", "")
  end
  if not looks_like_jwt(token) then return nil, nil end
  return token, expiry_str and tonumber(expiry_str) or nil
end

--- Write token to cache
---@param token string
---@param expiry_ts number|nil
local function write_cached_token(token, expiry_ts)
  vim.fn.mkdir(CACHE_DIR, "p")
  local f = io.open(TOKEN_FILE, "w")
  if not f then return end
  if expiry_ts then
    f:write(token .. "\n" .. tostring(expiry_ts))
  else
    f:write(token)
  end
  f:close()
  vim.fn.setfperm(TOKEN_FILE, "rw-------")
end

--- Decode JWT payload to get expiry (without verification)
---@param token string
---@return number|nil expiry_ts
local function jwt_expiry(token)
  local parts = vim.split(token, ".", { plain = true })
  if #parts < 2 then return nil end

  local payload_b64 = parts[2]
  -- Base64url → base64: add padding, swap chars
  local pad = 4 - (#payload_b64 % 4)
  if pad < 4 then
    payload_b64 = payload_b64 .. string.rep("=", pad)
  end
  payload_b64 = payload_b64:gsub("-", "+"):gsub("_", "/")

  local ok, decoded = pcall(vim.base64.decode, payload_b64)
  if not ok or not decoded then return nil end

  local json_ok, payload = pcall(vim.fn.json_decode, decoded)
  if not json_ok or not payload then return nil end

  return payload.exp
end

--- Check if a token is still valid (not expired)
---@param token string
---@param expiry_ts number|nil
---@return boolean
local function is_token_valid(token, expiry_ts)
  if not token or token == "" then return false end
  local exp = expiry_ts or jwt_expiry(token)
  if not exp then return true end -- can't determine expiry, try it
  return exp > (os.time() + 60) -- 60s buffer
end

--- Extract a clean token from cloudflared output
---@param stdout string
---@return string|nil
local function extract_token(stdout)
  if not stdout then return nil end
  -- cloudflared may output multiple lines; the token is the JWT line
  for line in stdout:gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if looks_like_jwt(trimmed) then
      return trimmed
    end
  end
  return nil
end

--- Get a valid CF Access token, refreshing if needed.
--- Async — calls callback(token, err) when done.
---@param config table
---@param callback fun(token: string|nil, err: string|nil)
function M.get_token(config, callback)
  local cf = config.cloudflare or {}
  if not cf.enabled then
    callback(nil, nil)
    return
  end

  -- Check our own cache first
  local token, expiry = read_cached_token()
  if token and is_token_valid(token, expiry) then
    callback(token, nil)
    return
  end

  local url = get_access_url(config)

  -- Check if cloudflared is available
  if vim.fn.executable("cloudflared") ~= 1 then
    callback(nil, "cloudflared not found. Install: brew install cloudflared")
    return
  end

  -- Try non-interactive token fetch (works if previously logged in)
  vim.system(
    { "cloudflared", "access", "token", url },
    { text = true },
    function(result)
      vim.schedule(function()
        local new_token = extract_token(result.stdout or "")
        if new_token then
          local new_expiry = jwt_expiry(new_token)
          write_cached_token(new_token, new_expiry)
          callback(new_token, nil)
        else
          -- No cached cloudflared token — need interactive login
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
          callback(nil, "Auth failed: " .. err .. "\nManual fallback: cloudflared access login " .. url)
          return
        end

        -- Login succeeded — fetch the token
        vim.system(
          { "cloudflared", "access", "token", url },
          { text = true },
          function(token_result)
            vim.schedule(function()
              local new_token = extract_token(token_result.stdout or "")
              if new_token then
                local new_expiry = jwt_expiry(new_token)
                write_cached_token(new_token, new_expiry)
                callback(new_token, nil)
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

--- Clear cached token (force re-auth on next connect)
function M.clear_cache()
  os.remove(TOKEN_FILE)
  vim.notify("Lobs: Auth cache cleared — will re-authenticate on next connect", vim.log.levels.INFO)
end

return M
