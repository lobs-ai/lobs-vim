-- lobs.nvim — Cloudflare Access authentication
-- Handles the CF Access JWT flow: login, token caching, and refresh.
local M = {}

local CACHE_DIR = vim.fn.stdpath("cache") .. "/lobs"
local TOKEN_FILE = CACHE_DIR .. "/cf_token"

--- Get the Access URL from config (HTTP version of the server URL)
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
    -- Old format: just the token, no expiry
    token = content:gsub("%s+$", "")
    return token, nil
  end
  return token, tonumber(expiry_str)
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
  -- Restrictive permissions — token is sensitive
  vim.fn.setfperm(TOKEN_FILE, "rw-------")
end

--- Decode JWT payload to get expiry (without verification)
---@param token string
---@return number|nil expiry_ts
local function jwt_expiry(token)
  local parts = vim.split(token, ".", { plain = true })
  if #parts < 2 then return nil end

  -- Base64url decode the payload
  local payload_b64 = parts[2]
  -- Add padding
  local pad = 4 - (#payload_b64 % 4)
  if pad < 4 then
    payload_b64 = payload_b64 .. string.rep("=", pad)
  end
  -- Convert base64url to base64
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

  -- If we have an explicit expiry, use it
  local exp = expiry_ts or jwt_expiry(token)
  if not exp then
    -- Can't determine expiry — assume valid but it might fail
    return true
  end

  -- Allow 60s buffer before expiry
  return exp > (os.time() + 60)
end

--- Get a valid CF Access token, refreshing if needed.
--- This is async — calls callback(token, err) when done.
---@param config table
---@param callback fun(token: string|nil, err: string|nil)
function M.get_token(config, callback)
  local cf = config.cloudflare or {}
  if not cf.enabled then
    callback(nil, nil) -- No auth needed
    return
  end

  -- Check cached token
  local token, expiry = read_cached_token()
  if token and is_token_valid(token, expiry) then
    callback(token, nil)
    return
  end

  -- Try to get a fresh token via cloudflared
  local url = get_access_url(config)
  M._fetch_token(url, function(new_token, err)
    if err then
      callback(nil, err)
      return
    end
    if new_token then
      local new_expiry = jwt_expiry(new_token)
      write_cached_token(new_token, new_expiry)
      callback(new_token, nil)
    else
      callback(nil, "No token returned")
    end
  end)
end

--- Fetch a token from cloudflared access
---@param url string
---@param callback fun(token: string|nil, err: string|nil)
function M._fetch_token(url, callback)
  -- Check if cloudflared is available
  if vim.fn.executable("cloudflared") ~= 1 then
    callback(nil, "cloudflared not found. Install it: brew install cloudflared")
    return
  end

  -- Try non-interactive token fetch first (works if already logged in)
  vim.system(
    { "cloudflared", "access", "token", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout and result.stdout:match("%S") then
          local token = result.stdout:gsub("%s+$", "")
          callback(token, nil)
        else
          -- Need interactive login — notify the user
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
  vim.notify(
    "Lobs: Opening browser for Cloudflare Access login...",
    vim.log.levels.INFO
  )

  vim.system(
    { "cloudflared", "access", "login", url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(nil, "Cloudflare Access login failed. Run manually: cloudflared access login " .. url)
          return
        end

        -- Now fetch the token (login should have cached creds)
        vim.system(
          { "cloudflared", "access", "token", url },
          { text = true },
          function(token_result)
            vim.schedule(function()
              if token_result.code == 0 and token_result.stdout and token_result.stdout:match("%S") then
                callback(token_result.stdout:gsub("%s+$", ""), nil)
              else
                callback(nil, "Failed to get token after login")
              end
            end)
          end
        )
      end)
    end
  )
end

--- Clear cached token (for manual re-auth)
function M.clear_cache()
  os.remove(TOKEN_FILE)
  vim.notify("Lobs: Cleared cached auth token", vim.log.levels.INFO)
end

return M
