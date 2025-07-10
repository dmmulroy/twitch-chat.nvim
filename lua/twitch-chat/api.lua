---@class TwitchChatAPI
---@field private _initialized boolean
---@field private _connections table<string, TwitchConnection>
---@field private _current_channel string?
---@field private _event_namespace table
local M = {}
local uv = vim.uv or vim.loop

local utils = require('twitch-chat.utils')
local config = require('twitch-chat.config')
local events = require('twitch-chat.events')
local irc = require('twitch-chat.modules.irc')
local auth = require('twitch-chat.modules.auth')
local buffer = require('twitch-chat.modules.buffer')

---@class TwitchConnection
---@field channel string Channel name
---@field status string Connection status ('connecting', 'connected', 'disconnected', 'error')
---@field websocket any WebSocket connection (deprecated)
---@field irc_conn any IRC connection handle
---@field chat_buffer any Chat buffer instance
---@field buffer_id number? Buffer ID for chat display
---@field window_id number? Window ID for chat display
---@field message_count number Total message count
---@field last_message_time number Timestamp of last message
---@field connected_at number? Timestamp when connection was established
---@field reconnect_attempts number Number of reconnection attempts
---@field rate_limiter table Rate limiter for sending messages

---@class TwitchMessage
---@field id string Unique message ID
---@field channel string Channel name
---@field username string Username of sender
---@field display_name string Display name of sender
---@field content string Message content
---@field timestamp number Message timestamp
---@field badges table<string, string> User badges
---@field emotes table[] Emote data
---@field color string? User color
---@field mod boolean Is user a moderator
---@field subscriber boolean Is user a subscriber
---@field turbo boolean Is user turbo
---@field user_type string User type

---@class TwitchChannelInfo
---@field name string Channel name
---@field display_name string Display name
---@field id string Channel ID
---@field status string Connection status
---@field message_count number Message count
---@field connected_at number Connection timestamp
---@field last_activity number Last activity timestamp

---@class TwitchStatus
---@field enabled boolean Plugin enabled
---@field authenticated boolean Authentication status
---@field debug boolean Debug mode
---@field channels TwitchChannelInfo[] Connected channels
---@field current_channel string? Current active channel
---@field uptime number Plugin uptime in seconds

-- Private state
M._initialized = false
M._connections = {}
M._current_channel = nil
M._event_namespace = events.create_namespace('api')

---Initialize the API
---@return nil
function M.init()
  if M._initialized then
    return
  end

  M._initialized = true
  M._connections = {}
  M._current_channel = nil

  -- Set up event listeners
  M._setup_event_listeners()

  -- Initialize rate limiters
  M._setup_rate_limiters()

  events.emit(events.CONNECTION_ESTABLISHED, { source = 'api' })
end

---Setup event listeners
---@return nil
function M._setup_event_listeners()
  -- Listen for configuration changes
  events.on(events.CONFIG_CHANGED, function(new_config)
    M._handle_config_change(new_config)
  end)

  -- Listen for authentication events
  events.on(events.AUTH_SUCCESS, function(auth_data)
    M._handle_auth_success(auth_data)
  end)

  events.on(events.AUTH_FAILED, function(error_data)
    M._handle_auth_failure(error_data)
  end)

  -- Listen for connection events
  events.on(events.CONNECTION_LOST, function(channel_data)
    M._handle_connection_lost(channel_data)
  end)
end

---Setup rate limiters for channels
---@return nil
function M._setup_rate_limiters()
  -- Implementation would set up rate limiting for message sending
end

---Connect to a Twitch channel
---@param channel string Channel name to connect to
---@return boolean success Whether connection was initiated successfully
function M.connect(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  -- Enhanced logging with correlation tracking
  local logger = require('twitch-chat.modules.logger')
  local correlation_id = logger.create_correlation_id('connect')
  logger.set_correlation_id(correlation_id)

  local timer_id = logger.start_timer('channel_connect', {
    channel = channel,
    correlation_id = correlation_id,
  })

  logger.info('Attempting to connect to channel', {
    channel = channel,
    correlation_id = correlation_id,
  }, { notify = false, category = 'background_operation' })

  -- Check if empty string
  if channel == '' then
    logger.error(
      'Empty channel name provided',
      { correlation_id = correlation_id },
      { notify = true, category = 'user_action' }
    )
    logger.end_timer(timer_id, { success = false, reason = 'empty_channel' })
    return false
  end

  if not M._initialized then
    logger.error(
      'Plugin not initialized',
      { correlation_id = correlation_id },
      { notify = true, category = 'system_status' }
    )
    events.emit(events.ERROR, {
      source = 'api',
      error = 'Plugin not initialized',
      correlation_id = correlation_id,
    })
    logger.end_timer(timer_id, { success = false, reason = 'not_initialized' })
    return false
  end

  -- Validate channel name
  if not utils.is_valid_channel(channel) then
    logger.error('Invalid channel name format', {
      channel = channel,
      correlation_id = correlation_id,
    })
    events.emit(events.ERROR, {
      source = 'api',
      error = 'Invalid channel name format',
      channel = channel,
      correlation_id = correlation_id,
    })
    logger.end_timer(timer_id, { success = false, reason = 'invalid_format' })
    return false
  end

  -- Check if already connected
  if M._connections[channel] then
    local conn = M._connections[channel]
    if conn.status == 'connected' or conn.status == 'connecting' then
      logger.warn('Already connected to channel', {
        channel = channel,
        status = conn.status,
        correlation_id = correlation_id,
      })
      logger.warn(
        'Already connected to channel',
        { channel = channel },
        { notify = true, category = 'user_action' }
      )
      logger.end_timer(timer_id, { success = true, reason = 'already_connected' })
      return true
    end
  end

  -- Create connection
  local connection = {
    channel = channel,
    status = 'connecting',
    websocket = nil,
    irc_conn = nil,
    chat_buffer = nil,
    buffer_id = nil,
    window_id = nil,
    message_count = 0,
    last_message_time = 0,
    connected_at = nil,
    reconnect_attempts = 0,
    rate_limiter = M._create_rate_limiter(),
  }

  M._connections[channel] = connection

  -- Set as current channel if none set
  if not M._current_channel then
    M._current_channel = channel
  end

  -- Start connection process
  M._start_connection(connection)

  return true
end

---Disconnect from a Twitch channel
---@param channel string Channel name to disconnect from
---@return boolean success Whether disconnection was successful
function M.disconnect(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  local connection = M._connections[channel]
  if not connection then
    vim.notify(string.format('Not connected to %s', channel), vim.log.levels.WARN)
    return false
  end

  -- Close websocket connection
  if connection.websocket then
    M._close_websocket(connection)
  end

  -- Close buffer and window
  if connection.buffer_id then
    M._close_buffer(connection)
  end

  -- Update connection status
  connection.status = 'disconnected'

  -- Remove from connections
  M._connections[channel] = nil

  -- Update current channel
  if M._current_channel == channel then
    M._current_channel = M._get_next_channel()
  end

  -- Emit event
  events.emit(events.CHANNEL_LEFT, {
    channel = channel,
    connection = connection,
  })

  logger.info(
    'Disconnected from channel',
    { channel = channel },
    { notify = true, category = 'user_action' }
  )

  return true
end

---Send a message to a channel
---@param channel string Channel name
---@param message string Message to send
---@return boolean success Whether message was sent successfully
function M.send_message(channel, message)
  vim.validate({
    channel = { channel, 'string' },
    message = { message, 'string' },
  })

  local connection = M._connections[channel]
  if not connection then
    vim.notify(string.format('Not connected to %s', channel), vim.log.levels.ERROR)
    return false
  end

  if connection.status ~= 'connected' then
    vim.notify(string.format('Not connected to %s', channel), vim.log.levels.ERROR)
    return false
  end

  -- Check rate limit
  if not M._check_rate_limit(connection) then
    vim.notify(
      'Rate limit exceeded. Please wait before sending another message.',
      vim.log.levels.WARN
    )
    return false
  end

  -- Send message via websocket
  local success = M._send_websocket_message(connection, message)

  if success then
    logger.info(
      'Message sent to channel',
      { channel = channel },
      { notify = true, category = 'user_action', priority = 'low' }
    )
  else
    logger.error(
      'Failed to send message to channel',
      { channel = channel },
      { notify = true, category = 'user_action' }
    )
  end

  return success
end

---Get list of connected channels
---@return TwitchChannelInfo[] channels List of connected channels
function M.get_channels()
  local channels = {}

  for channel_name, connection in pairs(M._connections) do
    table.insert(channels, {
      name = channel_name,
      display_name = channel_name, -- Would be populated from API
      id = channel_name, -- Would be populated from API
      status = connection.status,
      message_count = connection.message_count,
      connected_at = connection.connected_at or 0,
      last_activity = connection.last_message_time,
    })
  end

  return channels
end

---Get current active channel
---@return string? channel Current channel name or nil
function M.get_current_channel()
  return M._current_channel
end

---Set current active channel
---@param channel string Channel name to set as current
---@return boolean success Whether channel was set successfully
function M.set_current_channel(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  if not M._connections[channel] then
    vim.notify(string.format('Not connected to %s', channel), vim.log.levels.ERROR)
    return false
  end

  M._current_channel = channel

  -- Emit event
  events.emit(events.CHANNEL_JOINED, {
    channel = channel,
    previous_channel = M._current_channel,
  })

  return true
end

---Get plugin status
---@return TwitchStatus status Plugin status information
function M.get_status()
  local auth_module = require('twitch-chat.modules.auth')

  return {
    enabled = config.is_enabled(),
    authenticated = auth_module.is_authenticated(),
    debug = config.is_debug(),
    channels = M.get_channels(),
    current_channel = M._current_channel,
    uptime = M._get_uptime(),
  }
end

---Check if connected to a channel
---@param channel string Channel name
---@return boolean connected Whether connected to channel
function M.is_connected(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  -- Check if empty string
  if channel == '' then
    return false
  end

  -- Check if not initialized
  if not M._initialized or not M._connections then
    return false
  end

  local connection = M._connections[channel]
  return connection and connection.status == 'connected' or false
end

---Get connection info for a channel
---@param channel string Channel name
---@return TwitchConnection? connection Connection info or nil
function M.get_connection(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  -- Check if empty string
  if channel == '' then
    return nil
  end

  -- Check if not initialized
  if not M._initialized or not M._connections then
    return nil
  end

  return M._connections[channel]
end

---Reload the plugin
---@return nil
function M.reload()
  -- Disconnect all channels
  for channel in pairs(M._connections) do
    M.disconnect(channel)
  end

  -- Clear state
  M._initialized = false
  M._connections = {}
  M._current_channel = nil

  -- Reload modules
  package.loaded['twitch-chat.config'] = nil
  package.loaded['twitch-chat.events'] = nil
  package.loaded['twitch-chat.utils'] = nil
  package.loaded['twitch-chat.api'] = nil

  -- Reinitialize
  M.init()

  vim.notify('TwitchChat plugin reloaded', vim.log.levels.INFO)
end

---Insert emote at cursor
---@param emote_name string Emote name to insert
---@return boolean success Whether emote was inserted
function M.insert_emote(emote_name)
  vim.validate({
    emote_name = { emote_name, 'string' },
  })

  -- Insert emote at cursor position
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { emote_name })

  return true
end

---Get available emotes
---@return string[] emotes List of available emotes
function M.get_emotes()
  -- This would be populated from Twitch API
  return { 'Kappa', 'PogChamp', 'LUL', 'EZ', 'Jebaited', '4Head' }
end

---Register event listener
---@param event string Event name
---@param callback fun(data: any): nil Callback function
---@return nil
function M.on(event, callback)
  events.on(event, callback)
end

---Emit event
---@param event string Event name
---@param data any Event data
---@return nil
function M.emit(event, data)
  events.emit(event, data)
end

-- Private implementation functions

---Start connection process
---@param connection TwitchConnection Connection to start
---@return nil
function M._start_connection(connection)
  connection.status = 'connecting'

  -- Check authentication
  if not auth.is_authenticated() then
    connection.status = 'error'
    vim.notify('Authentication required. Please run :TwitchAuth login', vim.log.levels.ERROR)
    return
  end

  -- Get access token
  local access_token = auth.get_access_token()
  if not access_token then
    connection.status = 'error'
    vim.notify('Failed to get access token', vim.log.levels.ERROR)
    return
  end

  -- Configure IRC connection
  local irc_config = {
    server = 'irc-ws.chat.twitch.tv',
    port = 443,
    nick = connection.channel:sub(2), -- Remove # prefix for nick (will be overridden)
    pass = 'oauth:' .. access_token,
    reconnect_interval = config.get('connection.reconnect_interval') or 5000,
    max_reconnect_attempts = config.get('connection.max_reconnect_attempts') or 5,
    ping_timeout = config.get('connection.ping_timeout') or 15000,
    message_rate_limit = config.get('connection.message_rate_limit') or 20,
    join_rate_limit = config.get('connection.join_rate_limit') or 10,
  }

  -- Set up IRC callbacks
  local callbacks = {
    on_connect = function()
      connection.status = 'connected'
      connection.connected_at = os.time()

      -- Create chat buffer
      M._create_chat_buffer(connection)

      -- Emit connection event
      events.emit(events.CHANNEL_JOINED, {
        channel = connection.channel,
        connection = connection,
      })

      vim.notify(string.format('Connected to %s', connection.channel), vim.log.levels.INFO)
    end,

    on_disconnect = function(reason)
      connection.status = 'disconnected'
      vim.notify(
        string.format('Disconnected from %s: %s', connection.channel, reason or 'Unknown'),
        vim.log.levels.WARN
      )

      events.emit(events.CHANNEL_LEFT, {
        channel = connection.channel,
        connection = connection,
        reason = reason,
      })
    end,

    on_error = function(error_msg)
      connection.status = 'error'
      vim.notify(
        string.format('Error in %s: %s', connection.channel, error_msg),
        vim.log.levels.ERROR
      )

      events.emit(events.CONNECTION_ERROR, {
        channel = connection.channel,
        connection = connection,
        error = error_msg,
      })
    end,

    on_message = function(message)
      -- Handle incoming chat message
      M._handle_message(connection, message)
    end,

    on_join = function(user, channel)
      events.emit(events.USER_JOINED, {
        channel = channel,
        user = user,
        connection = connection,
      })
    end,

    on_part = function(user, channel, reason)
      events.emit(events.USER_LEFT, {
        channel = channel,
        user = user,
        reason = reason,
        connection = connection,
      })
    end,
  }

  -- Create IRC connection
  connection.irc_conn = irc.connect(irc_config, callbacks)

  -- Join the channel
  irc.join(connection.irc_conn, connection.channel)
end

---Create chat buffer for connection
---@param connection TwitchConnection Connection to create buffer for
---@return nil
function M._create_chat_buffer(connection)
  -- Use the buffer module to create a proper chat buffer
  local buffer_config = {
    channel = connection.channel,
    max_messages = config.get('buffer.max_messages') or 1000,
    auto_scroll = config.get('buffer.auto_scroll') or true,
    show_timestamps = config.get('buffer.show_timestamps') or true,
    show_emotes = config.get('emotes.enabled') or true,
  }

  local chat_buffer = buffer.create_buffer(buffer_config)
  connection.buffer_id = chat_buffer.bufnr
  connection.chat_buffer = chat_buffer

  -- Show welcome message
  buffer.add_system_message(chat_buffer, string.format('Connected to %s', connection.channel))
  buffer.add_system_message(chat_buffer, 'Chat messages will appear here')
end

---Handle incoming message from IRC
---@param connection TwitchConnection Connection that received the message
---@param message table IRC message data
---@return nil
function M._handle_message(connection, message)
  if not connection.chat_buffer then
    return
  end

  -- Update message count
  connection.message_count = connection.message_count + 1
  connection.last_message_time = os.time()

  -- Add message to buffer
  buffer.add_message(connection.chat_buffer, {
    username = message.username,
    content = message.content,
    timestamp = message.timestamp or os.time(),
    badges = message.badges or {},
    emotes = message.emotes or {},
    user_color = message.user_color,
    is_mod = message.is_mod or false,
    is_vip = message.is_vip or false,
    is_subscriber = message.is_subscriber or false,
  })

  -- Emit message event for other modules
  events.emit(events.MESSAGE_RECEIVED, {
    channel = connection.channel,
    message = message,
    connection = connection,
  })
end

---Close IRC connection
---@param connection TwitchConnection Connection to close
---@return nil
function M._close_websocket(connection)
  if connection.irc_conn then
    -- Leave the channel first
    irc.part(connection.irc_conn, connection.channel)

    -- Close the IRC connection
    irc.disconnect(connection.irc_conn)
    connection.irc_conn = nil
  end

  connection.status = 'disconnected'
end

---Close chat buffer
---@param connection TwitchConnection Connection to close buffer for
---@return nil
function M._close_buffer(connection)
  if connection.buffer_id then
    pcall(vim.api.nvim_buf_delete, connection.buffer_id, { force = true })
    connection.buffer_id = nil
  end

  if connection.window_id then
    pcall(vim.api.nvim_win_close, connection.window_id, true)
    connection.window_id = nil
  end
end

---Get next available channel
---@return string? channel Next channel name or nil
function M._get_next_channel()
  for channel_name, connection in pairs(M._connections) do
    if connection.status == 'connected' then
      return channel_name
    end
  end

  return nil
end

---Create rate limiter for connection
---@return table rate_limiter Rate limiter object
function M._create_rate_limiter()
  local rate_limit = config.get('chat.message_rate_limit') or 20

  return {
    messages = {},
    limit = rate_limit,
    window = 30000, -- 30 seconds
  }
end

---Check rate limit for connection
---@param connection TwitchConnection Connection to check
---@return boolean allowed Whether message is allowed
function M._check_rate_limit(connection)
  local now = uv.now()
  local rate_limiter = connection.rate_limiter

  -- Remove old messages from rate limiter
  for i = #rate_limiter.messages, 1, -1 do
    if now - rate_limiter.messages[i] > rate_limiter.window then
      table.remove(rate_limiter.messages, i)
    end
  end

  -- Check if we're under the limit
  if #rate_limiter.messages >= rate_limiter.limit then
    return false
  end

  -- Add current message to rate limiter
  table.insert(rate_limiter.messages, now)

  return true
end

---Send message via IRC connection
---@param connection TwitchConnection Connection to send through
---@param message string Message to send
---@return boolean success Whether message was sent
function M._send_websocket_message(connection, message)
  if not connection.irc_conn then
    vim.notify('No IRC connection available', vim.log.levels.ERROR)
    return false
  end

  if connection.status ~= 'connected' then
    vim.notify('Not connected to channel', vim.log.levels.ERROR)
    return false
  end

  -- Send message via IRC
  local success = irc.send_message(connection.irc_conn, connection.channel, message)

  if success then
    -- Add our own message to the buffer
    if connection.chat_buffer then
      -- Get our username from auth
      auth.get_user_info(function(valid, user_info)
        local username = (valid and user_info and user_info.login) or 'you'
        buffer.add_message(connection.chat_buffer, {
          username = username,
          content = message,
          timestamp = os.time(),
          badges = {},
          emotes = {},
          user_color = '#ffffff',
          is_mod = false,
          is_vip = false,
          is_subscriber = false,
          is_self = true, -- Mark as our own message
        })
      end)
    end

    -- Emit message sent event
    events.emit(events.MESSAGE_SENT, {
      channel = connection.channel,
      message = message,
      connection = connection,
    })
  else
    vim.notify('Failed to send message', vim.log.levels.ERROR)
  end

  return success
end

---Get plugin uptime
---@return number uptime Uptime in seconds
function M._get_uptime()
  -- Implementation would track actual uptime
  return 0
end

---Handle configuration change
---@param new_config table New configuration
---@return nil
function M._handle_config_change(new_config)
  -- Implementation would update connections based on new config
end

---Handle authentication success
---@param auth_data table Authentication data
---@return nil
function M._handle_auth_success(auth_data)
  -- Implementation would update authentication state
end

---Handle authentication failure
---@param error_data table Error data
---@return nil
function M._handle_auth_failure(error_data)
  -- Implementation would handle auth failure
end

---Handle connection lost
---@param channel_data table Channel data
---@return nil
function M._handle_connection_lost(channel_data)
  -- Implementation would handle reconnection
end

return M
