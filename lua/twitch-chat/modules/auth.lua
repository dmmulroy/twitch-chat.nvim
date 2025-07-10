---@class TwitchAuth
---@field config TwitchAuthConfig
---@field current_token TwitchToken?
---@field token_file string
---@field http_server any
---@field current_oauth_state string?
---@field oauth_state_expires number?
local M = {}

---@class TwitchToken
---@field access_token string
---@field refresh_token string?
---@field token_type string
---@field expires_in number
---@field scope string[]
---@field expires_at number
---@field last_rotation number? Timestamp of last rotation
---@field rotation_interval number? Auto-rotation interval in seconds

---@class OAuthResponse
---@field access_token string
---@field refresh_token string?
---@field token_type string
---@field expires_in number
---@field scope string

local circuit_breaker = require('twitch-chat.modules.circuit_breaker')
local logger = require('twitch-chat.modules.logger')

local DEFAULT_CONFIG = {
  client_id = '',
  client_secret = '',
  redirect_uri = 'http://localhost:3000/callback',
  scopes = { 'chat:read', 'chat:edit' },
  token_file = vim.fn.stdpath('cache') .. '/twitch-chat-token.json',
}

-- Circuit breakers for different operations
local twitch_api_breaker = circuit_breaker.get_or_create('twitch_api', {
  failure_threshold = 3,
  recovery_timeout = 30000, -- 30 seconds
  success_threshold = 2,
  timeout = 10000, -- 10 seconds
})

local TWITCH_AUTH_URL = 'https://id.twitch.tv/oauth2/authorize'
local TWITCH_TOKEN_URL = 'https://id.twitch.tv/oauth2/token'
local TWITCH_VALIDATE_URL = 'https://id.twitch.tv/oauth2/validate'

-- Token rotation settings
local TOKEN_ROTATION_THRESHOLD = 3600 -- 1 hour before expiry
local AUTO_ROTATION_INTERVAL = 86400 -- 24 hours
local rotation_timer

---Initialize the auth module
---@param config TwitchAuthConfig
function M.setup(config)
  M.config = vim.tbl_deep_extend('force', DEFAULT_CONFIG, config or {})
  M.token_file = M.config.token_file

  -- Validate required config
  if not M.config.client_id or M.config.client_id == '' then
    error('Twitch client_id is required for authentication')
  end

  -- Try to load existing token
  M.current_token = M.load_token()

  -- Setup token rotation if auto_refresh is enabled
  if M.config.auto_refresh and M.current_token then
    M.setup_token_rotation()
  end
end

---Generate OAuth authorization URL
---@return string
function M.generate_auth_url()
  -- Generate and store state for validation
  local state = M.generate_state()
  M.current_oauth_state = state
  M.oauth_state_expires = os.time() + 300 -- 5 minutes

  local params = {
    client_id = M.config.client_id,
    redirect_uri = M.config.redirect_uri,
    response_type = 'code',
    scope = table.concat(M.config.scopes, ' '),
    state = state,
  }

  local query_string = M.build_query_string(params)
  return TWITCH_AUTH_URL .. '?' .. query_string
end

---Generate a cryptographically secure random state parameter for OAuth security
---@return string
function M.generate_state()
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local state = ''

  -- Use multiple random sources for better entropy
  math.randomseed(os.time() + vim.fn.rand() + vim.loop.hrtime())

  for i = 1, 32 do
    -- Additional randomness mixing
    local rand_val = (vim.fn.rand() + math.random(1, #chars) + os.clock() * 1000000) % #chars + 1
    state = state .. chars:sub(rand_val, rand_val)
  end
  return state
end

---Build query string from parameters
---@param params table<string, string>
---@return string
function M.build_query_string(params)
  local parts = {}
  for key, value in pairs(params) do
    table.insert(parts, key .. '=' .. vim.uri_encode(value))
  end
  return table.concat(parts, '&')
end

---Start OAuth flow
---@param callback? fun(success: boolean, error?: string): nil
function M.start_oauth_flow(callback)
  callback = callback or function() end

  -- Generate auth URL
  local auth_url = M.generate_auth_url()

  -- Start local server to handle callback
  M.start_callback_server(function(success, token_or_error)
    if success then
      -- Type assertion: in success case, token_or_error is TwitchToken
      ---@cast token_or_error TwitchToken
      M.current_token = token_or_error
      M.save_token(M.current_token)
      callback(true)
    else
      -- Type assertion: in error case, token_or_error is string
      ---@cast token_or_error string
      callback(false, token_or_error)
    end
  end)

  -- Open browser
  M.open_browser(auth_url)
end

---Start local HTTP server for OAuth callback
---@param callback fun(success: boolean, token_or_error: TwitchToken|string): nil
function M.start_callback_server(callback)
  local uv = vim.uv or vim.loop
  local server = uv.new_tcp()

  if not server then
    callback(false, 'Failed to create TCP server')
    return
  end

  server:bind('127.0.0.1', 3000)

  server:listen(128, function(err)
    if err then
      callback(false, 'Failed to start callback server: ' .. err)
      return
    end

    server:accept(function(client_err, client)
      if client_err then
        callback(false, 'Failed to accept client: ' .. client_err)
        return
      end

      client:read_start(function(read_err, chunk)
        if read_err then
          callback(false, 'Failed to read request: ' .. read_err)
          client:close()
          return
        end

        if chunk then
          -- Parse HTTP request
          local request = chunk:match('GET ([^%s]+)')
          if request then
            local code = request:match('code=([^&]+)')
            local state = request:match('state=([^&]+)')

            -- Validate state parameter for CSRF protection
            if not M.validate_oauth_state(state) then
              local response =
                'HTTP/1.1 400 Bad Request\r\n\r\n<html><body><h1>Authentication failed!</h1><p>Error: Invalid state parameter (possible CSRF attack)</p></body></html>'
              client:write(response)
              client:close()
              callback(false, 'OAuth state validation failed')
              return
            end

            if code then
              -- Clear state after successful validation
              M.clear_oauth_state()

              -- Send response to browser
              local response =
                'HTTP/1.1 200 OK\r\n\r\n<html><body><h1>Authentication successful!</h1><p>You can close this window.</p></body></html>'
              client:write(response)
              client:close()

              -- Exchange code for token
              M.exchange_code_for_token(code, callback)
            else
              local error_msg = request:match('error=([^&]+)') or 'Unknown error'
              local response = 'HTTP/1.1 400 Bad Request\r\n\r\n<html><body><h1>Authentication failed!</h1><p>Error: '
                .. error_msg
                .. '</p></body></html>'
              client:write(response)
              client:close()
              callback(false, 'OAuth error: ' .. error_msg)
            end
          end
        else
          client:close()
        end
      end)
    end)
  end)

  -- Store server reference for cleanup
  M.http_server = server

  -- Auto-cleanup after 5 minutes
  vim.defer_fn(function()
    if M.http_server then
      M.http_server:close()
      M.http_server = nil
    end
    -- Also clear OAuth state on timeout
    M.clear_oauth_state()
  end, 300000)
end

---Validate OAuth state parameter
---@param received_state string?
---@return boolean
function M.validate_oauth_state(received_state)
  -- Check if we have a stored state
  if not M.current_oauth_state then
    return false
  end

  -- Check if state has expired
  if not M.oauth_state_expires or os.time() > M.oauth_state_expires then
    M.clear_oauth_state()
    return false
  end

  -- Check if received state matches stored state
  if not received_state or received_state ~= M.current_oauth_state then
    return false
  end

  return true
end

---Clear stored OAuth state
function M.clear_oauth_state()
  M.current_oauth_state = nil
  M.oauth_state_expires = nil
end

---Exchange authorization code for access token
---@param code string
---@param callback fun(success: boolean, token_or_error: TwitchToken|string): nil
function M.exchange_code_for_token(code, callback)
  local curl = require('plenary.curl')

  local data = {
    client_id = M.config.client_id,
    client_secret = M.config.client_secret,
    code = code,
    grant_type = 'authorization_code',
    redirect_uri = M.config.redirect_uri,
  }

  -- Use circuit breaker for token exchange
  local success, result = circuit_breaker.call(twitch_api_breaker, function()
    curl.post(TWITCH_TOKEN_URL, {
      body = M.build_query_string(data),
      headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
      },
      callback = function(response)
        if response.status == 200 then
          local parse_success, token_data = pcall(vim.json.decode, response.body)
          if parse_success and token_data.access_token then
            local token = M.create_token_from_response(token_data)
            callback(true, token)
          else
            callback(false, 'Failed to parse token response')
          end
        else
          callback(false, 'Token request failed: ' .. response.status)
          error('HTTP ' .. response.status) -- Trigger circuit breaker
        end
      end,
    })
    return true
  end)

  if not success then
    callback(false, 'Token exchange failed: ' .. (result or 'Circuit breaker open'))
  end
end

---Create token object from OAuth response
---@param response OAuthResponse
---@return TwitchToken
function M.create_token_from_response(response)
  return {
    access_token = response.access_token,
    refresh_token = response.refresh_token,
    token_type = response.token_type or 'Bearer',
    expires_in = response.expires_in,
    scope = vim.split(response.scope or '', ' '),
    expires_at = os.time() + (response.expires_in or 3600),
    last_rotation = os.time(),
    rotation_interval = AUTO_ROTATION_INTERVAL,
  }
end

---Open browser to given URL
---@param url string
function M.open_browser(url)
  local uv = vim.uv or vim.loop
  local system = uv.os_uname().sysname
  local cmd

  if system == 'Darwin' then
    cmd = { 'open', url }
  elseif system == 'Linux' then
    cmd = { 'xdg-open', url }
  elseif system == 'Windows_NT' then
    cmd = { 'start', url }
  else
    logger.info(
      'Please open this URL in your browser',
      { url = url, module = 'auth' },
      { notify = true, category = 'user_action', priority = 'high' }
    )
    return
  end

  vim.fn.jobstart(cmd, { detach = true })
end

---Validate current token
---@param callback? fun(valid: boolean, user_info?: table): nil
function M.validate_token(callback)
  if not M.current_token then
    if callback then
      callback(false)
    end
    return false
  end

  -- Check expiration
  if os.time() >= M.current_token.expires_at then
    if callback then
      callback(false)
    end
    return false
  end

  -- Validate with Twitch API using circuit breaker
  local curl = require('plenary.curl')

  local cb_success, cb_result = circuit_breaker.call(twitch_api_breaker, function()
    curl.get(TWITCH_VALIDATE_URL, {
      headers = {
        ['Authorization'] = 'Bearer ' .. M.current_token.access_token,
      },
      callback = function(response)
        if response.status == 200 then
          local success, user_info = pcall(vim.json.decode, response.body)
          if success then
            if callback then
              callback(true, user_info)
            end
          else
            if callback then
              callback(false)
            end
          end
        else
          if callback then
            callback(false)
          end
          if response.status >= 500 then
            error('HTTP ' .. response.status) -- Trigger circuit breaker for server errors
          end
        end
      end,
    })
    return true
  end)

  if not cb_success then
    if callback then
      callback(false)
    end
  end

  return true
end

---Refresh access token using refresh token
---@param callback? fun(success: boolean, error?: string): nil
function M.refresh_token(callback)
  if not M.current_token or not M.current_token.refresh_token then
    if callback then
      callback(false, 'No refresh token available')
    end
    return
  end

  local curl = require('plenary.curl')

  local data = {
    client_id = M.config.client_id,
    client_secret = M.config.client_secret,
    refresh_token = M.current_token.refresh_token,
    grant_type = 'refresh_token',
  }

  curl.post(TWITCH_TOKEN_URL, {
    body = M.build_query_string(data),
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
    callback = function(response)
      if response.status == 200 then
        local success, token_data = pcall(vim.json.decode, response.body)
        if success and token_data.access_token then
          local new_token = M.create_token_from_response(token_data)
          -- Keep refresh token if not provided
          if not new_token.refresh_token then
            new_token.refresh_token = M.current_token.refresh_token
          end

          M.current_token = new_token
          M.save_token(M.current_token)

          if callback then
            callback(true)
          end
        else
          if callback then
            callback(false, 'Failed to parse refresh response')
          end
        end
      else
        if callback then
          callback(false, 'Token refresh failed: ' .. response.status)
        end
      end
    end,
  })
end

---Get current access token
---@return string?
function M.get_access_token()
  if not M.current_token then
    return nil
  end

  -- Check if token is expired
  if os.time() >= M.current_token.expires_at then
    return nil
  end

  return M.current_token.access_token
end

---Check if user is authenticated
---@return boolean
function M.is_authenticated()
  return M.current_token ~= nil and os.time() < M.current_token.expires_at
end

---Save token using secure storage (OS keyring preferred, encrypted file fallback)
---@param token TwitchToken
function M.save_token(token)
  local token_json = vim.json.encode(token)

  -- Try OS keyring first
  if M.save_to_keyring(token_json) then
    -- Remove file-based token if keyring save succeeded
    if vim.fn.filereadable(M.token_file) == 1 then
      vim.fn.delete(M.token_file)
    end
    return
  end

  -- Fall back to encrypted file storage
  local encrypted_token = M.encrypt_token(token_json)
  if encrypted_token then
    M.save_to_file(encrypted_token, true)
    logger.warn(
      'Token stored using file encryption (OS keyring not available)',
      { module = 'auth' }
    )
    return
  end

  -- Last resort: plain file with warning
  M.save_to_file(token_json, false)
  logger.warn(
    'Token stored in plain text file - consider setting up OS keyring for better security',
    { module = 'auth' },
    { notify = true, category = 'system_status', priority = 'low' }
  )
end

---Attempt to save token to OS keyring
---@param token_json string
---@return boolean success
function M.save_to_keyring(token_json)
  local uv = vim.uv or vim.loop
  local system = uv.os_uname().sysname
  local cmd

  if system == 'Darwin' then
    -- macOS Keychain
    cmd = {
      'security',
      'add-generic-password',
      '-a',
      'twitch-chat-nvim',
      '-s',
      'twitch-oauth-token',
      '-w',
      token_json,
      '-U', -- Update if exists
    }
  elseif system == 'Linux' then
    -- Try secret-tool (GNOME Keyring / KDE Wallet)
    if vim.fn.executable('secret-tool') == 1 then
      -- secret-tool reads password from stdin
      local handle = io.popen(
        'secret-tool store --label="Twitch Chat Neovim OAuth Token" application twitch-chat-nvim type oauth-token',
        'w'
      )
      if handle then
        handle:write(token_json)
        handle:close()
        return true
      end
      return false
    else
      return false
    end
  elseif system == 'Windows_NT' then
    -- Windows Credential Manager via cmdkey
    cmd = {
      'cmdkey',
      '/generic:twitch-chat-nvim',
      '/user:oauth-token',
      '/pass:' .. token_json,
    }
  else
    return false
  end

  local result = vim.fn.system(cmd)
  return vim.v.shell_error == 0
end

---Encrypt token for file storage
---@param token_json string
---@return string? encrypted_data
function M.encrypt_token(token_json)
  -- Simple XOR encryption with system-derived key
  -- Note: This is basic encryption, not cryptographically strong
  local key = M.derive_encryption_key()
  if not key then
    return nil
  end

  local encrypted = {}
  for i = 1, #token_json do
    local char_code = string.byte(token_json, i)
    local key_char = string.byte(key, ((i - 1) % #key) + 1)
    encrypted[i] = string.char(char_code ~ key_char)
  end

  return table.concat(encrypted)
end

---Derive encryption key from system properties
---@return string? key
function M.derive_encryption_key()
  local uv = vim.uv or vim.loop
  local system_info = uv.os_uname()

  -- Create key from system properties (not secure, but better than plaintext)
  local key_source = system_info.sysname .. system_info.nodename .. system_info.version

  -- Simple hash function
  local hash = 0
  for i = 1, #key_source do
    hash = (hash * 31 + string.byte(key_source, i)) % 256
  end

  -- Generate 32-character key
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local key = ''
  for i = 1, 32 do
    hash = (hash * 31 + i) % #chars + 1
    key = key .. chars:sub(hash, hash)
  end

  return key
end

---Save token to file (with or without encryption)
---@param data string
---@param is_encrypted boolean
function M.save_to_file(data, is_encrypted)
  local token_dir = vim.fn.fnamemodify(M.token_file, ':h')

  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(token_dir) == 0 then
    vim.fn.mkdir(token_dir, 'p')
  end

  -- Add encryption marker if encrypted
  local file_data = data
  if is_encrypted then
    file_data = '###ENCRYPTED###\n' .. data
  end

  -- Write token to file
  local file = io.open(M.token_file, 'w')
  if file then
    file:write(file_data)
    file:close()

    -- Set restrictive permissions (only owner can read/write)
    vim.fn.system('chmod 600 ' .. vim.fn.shellescape(M.token_file))
  else
    error('Failed to save token to file: ' .. M.token_file)
  end
end

---Load token from secure storage (keyring or file)
---@return TwitchToken?
function M.load_token()
  -- Try to load from OS keyring first
  local keyring_token = M.load_from_keyring()
  if keyring_token then
    return keyring_token
  end

  -- Fall back to file storage
  return M.load_from_file()
end

---Load token from OS keyring
---@return TwitchToken?
function M.load_from_keyring()
  local uv = vim.uv or vim.loop
  local system = uv.os_uname().sysname
  local cmd

  if system == 'Darwin' then
    -- macOS Keychain
    cmd = {
      'security',
      'find-generic-password',
      '-a',
      'twitch-chat-nvim',
      '-s',
      'twitch-oauth-token',
      '-w', -- Print password only
    }
  elseif system == 'Linux' then
    -- Try secret-tool (GNOME Keyring / KDE Wallet)
    if vim.fn.executable('secret-tool') == 1 then
      cmd = {
        'secret-tool',
        'lookup',
        'application',
        'twitch-chat-nvim',
        'type',
        'oauth-token',
      }
    else
      return nil
    end
  elseif system == 'Windows_NT' then
    -- Windows Credential Manager (would need PowerShell for retrieval)
    return nil -- Skip keyring on Windows for now due to complexity
  else
    return nil
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  -- Remove trailing newline
  result = result:gsub('\n$', '')

  local success, token = pcall(vim.json.decode, result)
  if not success or not token.access_token then
    return nil
  end

  return token
end

---Load token from file storage (with decryption support)
---@return TwitchToken?
function M.load_from_file()
  if vim.fn.filereadable(M.token_file) == 0 then
    return nil
  end

  local file = io.open(M.token_file, 'r')
  if not file then
    return nil
  end

  local content = file:read('*a')
  file:close()

  -- Check if content is encrypted
  local token_json = content
  if content:match('^###ENCRYPTED###\n') then
    local encrypted_data = content:gsub('^###ENCRYPTED###\n', '')
    token_json = M.decrypt_token(encrypted_data)
    if not token_json then
      logger.error('Failed to decrypt stored token', { module = 'auth' })
      return nil
    end
  end

  local success, token = pcall(vim.json.decode, token_json)
  if not success or not token.access_token then
    return nil
  end

  return token
end

---Decrypt token from file storage
---@param encrypted_data string
---@return string? decrypted_json
function M.decrypt_token(encrypted_data)
  local key = M.derive_encryption_key()
  if not key then
    return nil
  end

  local decrypted = {}
  for i = 1, #encrypted_data do
    local char_code = string.byte(encrypted_data, i)
    local key_char = string.byte(key, ((i - 1) % #key) + 1)
    decrypted[i] = string.char(char_code ~ key_char)
  end

  return table.concat(decrypted)
end

---Clear stored authentication
function M.clear_auth()
  M.current_token = nil

  -- Clear from keyring
  M.clear_from_keyring()

  -- Clear from file
  if vim.fn.filereadable(M.token_file) == 1 then
    vim.fn.delete(M.token_file)
  end
end

---Clear token from OS keyring
function M.clear_from_keyring()
  local uv = vim.uv or vim.loop
  local system = uv.os_uname().sysname
  local cmd

  if system == 'Darwin' then
    -- macOS Keychain
    cmd = {
      'security',
      'delete-generic-password',
      '-a',
      'twitch-chat-nvim',
      '-s',
      'twitch-oauth-token',
    }
  elseif system == 'Linux' then
    -- Try secret-tool (GNOME Keyring / KDE Wallet)
    if vim.fn.executable('secret-tool') == 1 then
      cmd = {
        'secret-tool',
        'clear',
        'application',
        'twitch-chat-nvim',
        'type',
        'oauth-token',
      }
    else
      return
    end
  elseif system == 'Windows_NT' then
    -- Windows Credential Manager
    cmd = {
      'cmdkey',
      '/delete:twitch-chat-nvim',
    }
  else
    return
  end

  vim.fn.system(cmd)
  -- Don't check error code as item might not exist
end

---Client credentials flow (for app-only authentication)
---@param callback fun(success: boolean, error?: string): nil
function M.client_credentials_flow(callback)
  if not M.config.client_secret then
    callback(false, 'Client secret required for client credentials flow')
    return
  end

  local curl = require('plenary.curl')

  local data = {
    client_id = M.config.client_id,
    client_secret = M.config.client_secret,
    grant_type = 'client_credentials',
  }

  curl.post(TWITCH_TOKEN_URL, {
    body = M.build_query_string(data),
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
    callback = function(response)
      if response.status == 200 then
        local success, token_data = pcall(vim.json.decode, response.body)
        if success and token_data.access_token then
          local token = M.create_token_from_response(token_data)
          M.current_token = token
          M.save_token(M.current_token)
          callback(true)
        else
          callback(false, 'Failed to parse client credentials response')
        end
      else
        callback(false, 'Client credentials request failed: ' .. response.status)
      end
    end,
  })
end

---Check if token has required scopes
---@param required_scopes string[]
---@return boolean
function M.has_scopes(required_scopes)
  if not M.current_token or not M.current_token.scope then
    return false
  end

  for _, required_scope in ipairs(required_scopes) do
    local has_scope = false
    for _, token_scope in ipairs(M.current_token.scope) do
      if token_scope == required_scope then
        has_scope = true
        break
      end
    end
    if not has_scope then
      return false
    end
  end

  return true
end

---Get user info from token validation
---@param callback fun(success: boolean, user_info?: table): nil
function M.get_user_info(callback)
  M.validate_token(function(valid, user_info)
    callback(valid, user_info)
  end)
end

---Revoke current token
---@param callback? fun(success: boolean): nil
function M.revoke_token(callback)
  if not M.current_token then
    if callback then
      callback(false)
    end
    return
  end

  local curl = require('plenary.curl')

  curl.post('https://id.twitch.tv/oauth2/revoke', {
    body = M.build_query_string({
      client_id = M.config.client_id,
      token = M.current_token.access_token,
    }),
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
    callback = function(response)
      M.clear_auth()
      if callback then
        callback(response.status == 200)
      end
    end,
  })
end

---Setup automatic token rotation
function M.setup_token_rotation()
  if not M.current_token or not M.current_token.refresh_token then
    return
  end

  -- Clear existing rotation timer
  M.stop_token_rotation()

  -- Calculate next rotation time
  local next_rotation = M.calculate_next_rotation_time()

  if next_rotation > 0 then
    rotation_timer = vim.defer_fn(function()
      M.rotate_token_if_needed()
    end, next_rotation * 1000) -- Convert to milliseconds

    logger.debug('Token rotation scheduled', {
      next_rotation_in_seconds = next_rotation,
      module = 'auth',
    })
  end
end

---Stop automatic token rotation
function M.stop_token_rotation()
  if rotation_timer then
    vim.fn.timer_stop(rotation_timer)
    rotation_timer = nil
  end
end

---Calculate next rotation time based on token expiry and rotation interval
---@return number seconds_until_rotation
function M.calculate_next_rotation_time()
  if not M.current_token then
    return 0
  end

  local now = os.time()
  local expires_at = M.current_token.expires_at
  local last_rotation = M.current_token.last_rotation or now
  local rotation_interval = M.current_token.rotation_interval or AUTO_ROTATION_INTERVAL

  -- Time until token expires (with threshold buffer)
  local time_until_expiry = expires_at - now - TOKEN_ROTATION_THRESHOLD

  -- Time until next scheduled rotation
  local time_until_next_rotation = last_rotation + rotation_interval - now

  -- Return the earlier of the two times, but ensure it's at least 60 seconds
  local next_rotation = math.max(60, math.min(time_until_expiry, time_until_next_rotation))

  return math.max(0, next_rotation)
end

---Check if token needs rotation and perform it
---@param force? boolean Force rotation even if not needed
---@param callback? fun(success: boolean, error?: string): nil
function M.rotate_token_if_needed(force, callback)
  callback = callback or function() end

  if not M.current_token or not M.current_token.refresh_token then
    callback(false, 'No refresh token available')
    return
  end

  local now = os.time()
  local should_rotate = force or M.should_rotate_token()

  if not should_rotate then
    -- Schedule next rotation check
    M.setup_token_rotation()
    callback(true)
    return
  end

  logger.info('Rotating token', {
    expires_at = M.current_token.expires_at,
    current_time = now,
    module = 'auth',
  })

  M.refresh_token(function(success, error)
    if success then
      logger.info('Token rotation successful', { module = 'auth' })

      -- Setup next rotation
      M.setup_token_rotation()

      -- Emit token rotation event
      local events = require('twitch-chat.events')
      events.emit('token_rotated', {
        timestamp = now,
        new_expires_at = M.current_token.expires_at,
      })

      callback(true)
    else
      logger.error('Token rotation failed', {
        error = error,
        module = 'auth',
      })

      -- Retry rotation with exponential backoff
      local retry_delay = math.min(300, 60 * (M.current_token.rotation_failures or 0) + 60)
      vim.defer_fn(function()
        M.rotate_token_if_needed(true, callback)
      end, retry_delay * 1000)

      -- Track rotation failures
      M.current_token.rotation_failures = (M.current_token.rotation_failures or 0) + 1

      callback(false, error)
    end
  end)
end

---Check if token should be rotated
---@return boolean
function M.should_rotate_token()
  if not M.current_token then
    return false
  end

  local now = os.time()
  local expires_at = M.current_token.expires_at
  local last_rotation = M.current_token.last_rotation or now
  local rotation_interval = M.current_token.rotation_interval or AUTO_ROTATION_INTERVAL

  -- Rotate if token expires soon
  if expires_at - now <= TOKEN_ROTATION_THRESHOLD then
    return true
  end

  -- Rotate if enough time has passed since last rotation
  if now - last_rotation >= rotation_interval then
    return true
  end

  return false
end

---Get token rotation status
---@return table
function M.get_rotation_status()
  if not M.current_token then
    return {
      has_token = false,
      can_rotate = false,
    }
  end

  local now = os.time()
  return {
    has_token = true,
    can_rotate = not not M.current_token.refresh_token,
    expires_at = M.current_token.expires_at,
    expires_in = M.current_token.expires_at - now,
    last_rotation = M.current_token.last_rotation,
    should_rotate = M.should_rotate_token(),
    next_rotation_in = M.calculate_next_rotation_time(),
    rotation_failures = M.current_token.rotation_failures or 0,
  }
end

---Cleanup resources
function M.cleanup()
  -- Stop token rotation
  M.stop_token_rotation()

  if M.http_server then
    M.http_server:close()
    M.http_server = nil
  end
  M.clear_oauth_state()
end

return M
