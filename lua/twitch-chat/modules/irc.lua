-- lua/twitch-chat/modules/irc.lua
-- IRC protocol implementation for Twitch chat

local websocket = require('twitch-chat.modules.websocket')
local events = require('twitch-chat.events')
local connection_monitor = require('twitch-chat.modules.connection_monitor')
local uv = vim.uv or vim.loop

local M = {}

---@class Timer
---@field start fun(self: Timer, timeout: number, repeat_timeout: number, callback: function): boolean
---@field stop fun(self: Timer): boolean
---@field close fun(self: Timer): nil

---@class IRCConfig
---@field server string
---@field port number
---@field nick string
---@field pass string
---@field reconnect_interval number
---@field max_reconnect_attempts number
---@field ping_timeout number
---@field message_rate_limit number
---@field join_rate_limit number
---@field capabilities string[]

---@class IRCMessage
---@field raw string
---@field prefix string?
---@field command string
---@field params string[]
---@field tags table<string, string>?

---@class IRCChannel
---@field name string
---@field joined boolean
---@field users table<string, boolean>
---@field modes table<string, boolean>

---@class IRCConnection
---@field config IRCConfig
---@field websocket_conn any
---@field connected boolean
---@field authenticated boolean
---@field channels table<string, IRCChannel>
---@field nick string
---@field capabilities table<string, boolean>
---@field last_ping number
---@field last_pong number
---@field message_queue table[]
---@field join_queue table[]
---@field callbacks table<string, function>
---@field rate_limiters table<string, any>

-- Default configuration
local default_config = {
  server = 'wss://irc-ws.chat.twitch.tv:443',
  port = 443,
  nick = '',
  pass = '',
  reconnect_interval = 5000,
  max_reconnect_attempts = 5,
  ping_timeout = 60000,
  message_rate_limit = 20, -- messages per 30 seconds
  join_rate_limit = 50, -- joins per 15 seconds
  capabilities = {
    'twitch.tv/membership',
    'twitch.tv/tags',
    'twitch.tv/commands',
  },
}

-- IRC message parsing
local function parse_irc_message(line)
  local message = {
    raw = line,
    prefix = nil,
    command = '',
    params = {},
    tags = {},
  }

  local pos = 1

  -- Parse tags (if present)
  if line:sub(1, 1) == '@' then
    local tag_end = line:find(' ', pos)
    if tag_end then
      local tag_string = line:sub(2, tag_end - 1)
      for tag_pair in tag_string:gmatch('[^;]+') do
        local key, value = tag_pair:match('([^=]+)=?(.*)')
        if key then
          message.tags[key] = value ~= '' and value or true
        end
      end
      pos = tag_end + 1
    end
  end

  -- Parse prefix (if present)
  if line:sub(pos, pos) == ':' then
    local prefix_end = line:find(' ', pos)
    if prefix_end then
      message.prefix = line:sub(pos + 1, prefix_end - 1)
      pos = prefix_end + 1
    end
  end

  -- Parse command and parameters
  local remaining = line:sub(pos)
  local parts = vim.split(remaining, ' ', { plain = true })

  if #parts > 0 then
    message.command = parts[1]:upper()

    for i = 2, #parts do
      if parts[i]:sub(1, 1) == ':' then
        -- Trailing parameter (rest of the line)
        local trailing = table.concat(parts, ' ', i):sub(2)
        table.insert(message.params, trailing)
        break
      else
        table.insert(message.params, parts[i])
      end
    end
  end

  return message
end

-- IRC message formatting
local function format_irc_message(command, params)
  local message = command

  if params and #params > 0 then
    for i = 1, #params - 1 do
      message = message .. ' ' .. params[i]
    end

    -- Last parameter might need to be trailing
    local last_param = params[#params]
    if last_param:find(' ') or last_param:sub(1, 1) == ':' then
      message = message .. ' :' .. last_param
    else
      message = message .. ' ' .. last_param
    end
  end

  return message
end

-- Rate limiting helpers
local function create_rate_limiter(limit, window)
  return {
    limit = limit,
    window = window,
    timestamps = {},
  }
end

local function rate_limit_check(limiter)
  local now = uv.hrtime() / 1000000
  local cutoff = now - limiter.window

  -- Remove old timestamps
  local i = 1
  while i <= #limiter.timestamps and limiter.timestamps[i] < cutoff do
    i = i + 1
  end

  if i > 1 then
    for j = i, #limiter.timestamps do
      limiter.timestamps[j - i + 1] = limiter.timestamps[j]
    end
    for j = #limiter.timestamps - i + 2, #limiter.timestamps do
      limiter.timestamps[j] = nil
    end
  end

  return #limiter.timestamps < limiter.limit
end

local function rate_limit_add(limiter)
  local now = uv.hrtime() / 1000000
  table.insert(limiter.timestamps, now)
end

-- Event emission
local function emit_event(conn, event, data)
  events.emit(event, data)
end

-- Message queue processing
local function process_message_queue(conn)
  while #conn.message_queue > 0 and conn.connected do
    local message = table.remove(conn.message_queue, 1)
    if rate_limit_check(conn.rate_limiters.message) then
      rate_limit_add(conn.rate_limiters.message)
      websocket.send(conn.websocket_conn, message)
    else
      -- Put message back at the front of the queue
      table.insert(conn.message_queue, 1, message)
      break
    end
  end
end

local function process_join_queue(conn)
  while #conn.join_queue > 0 and conn.connected do
    local channel = table.remove(conn.join_queue, 1)
    if rate_limit_check(conn.rate_limiters.join) then
      rate_limit_add(conn.rate_limiters.join)
      local join_msg = format_irc_message('JOIN', { channel })
      websocket.send(conn.websocket_conn, join_msg)
    else
      -- Put channel back at the front of the queue
      table.insert(conn.join_queue, 1, channel)
      break
    end
  end
end

-- IRC command handlers
local function handle_ping(conn, message)
  local pong_msg = format_irc_message('PONG', message.params)
  websocket.send_raw(conn.websocket_conn, pong_msg)
  conn.last_pong = uv.hrtime() / 1000000

  -- Record pong for health monitoring
  if conn.monitor_id then
    connection_monitor.record_pong(conn.monitor_id)
  end
end

local function handle_pong(conn, message)
  conn.last_pong = uv.hrtime() / 1000000

  -- Record pong with latency calculation for health monitoring
  if conn.monitor_id and conn.last_ping > 0 then
    local latency = conn.last_pong - conn.last_ping
    connection_monitor.record_pong(conn.monitor_id, latency)
  end
end

-- Helper function to parse IRC message for privmsg
local function _parse_irc_message(message)
  local channel = message.params[1]
  local text = message.params[2]
  local nick = message.prefix and message.prefix:match('([^!]+)')

  return {
    channel = channel,
    text = text,
    nick = nick,
  }
end

-- Helper function to process message metadata
local function _process_message_metadata(message, nick)
  return {
    id = message.tags['id'],
    display_name = message.tags['display-name'] or nick,
    timestamp = os.time(),
    user_type = message.tags['user-type'],
    subscriber = message.tags['subscriber'] == '1',
    turbo = message.tags['turbo'] == '1',
    mod = message.tags['mod'] == '1',
    vip = message.tags['vip'] == '1',
    color = message.tags['color'],
    room_id = message.tags['room-id'],
    user_id = message.tags['user-id'],
    bits = message.tags['bits'],
  }
end

-- Helper function to process user badges
local function _process_user_badges(message)
  local badges = {}

  if message.tags['badges'] then
    for badge_pair in message.tags['badges']:gmatch('[^,]+') do
      local badge, version = badge_pair:match('([^/]+)/?(.*)')
      if badge then
        badges[badge] = version ~= '' and version or true
      end
    end
  end

  return badges
end

-- Helper function to process emotes
local function _process_emotes(message)
  local emotes = {}

  if message.tags['emotes'] then
    for emote_data in message.tags['emotes']:gmatch('[^/]+') do
      local emote_id, positions = emote_data:match('([^:]+):(.*)')
      if emote_id and positions then
        local emote = {
          id = emote_id,
          positions = {},
        }

        for pos_pair in positions:gmatch('[^,]+') do
          local start_pos, end_pos = pos_pair:match('(%d+)-(%d+)')
          if start_pos and end_pos then
            table.insert(emote.positions, {
              start = tonumber(start_pos),
              end_pos = tonumber(end_pos),
            })
          end
        end

        table.insert(emotes, emote)
      end
    end
  end

  return emotes
end

local function handle_privmsg(conn, message)
  if #message.params < 2 then
    return
  end

  local parsed_msg = _parse_irc_message(message)
  local metadata = _process_message_metadata(message, parsed_msg.nick)
  local badges = _process_user_badges(message)
  local emotes = _process_emotes(message)

  local chat_message = {
    id = metadata.id,
    channel = parsed_msg.channel,
    username = parsed_msg.nick,
    display_name = metadata.display_name,
    text = parsed_msg.text,
    timestamp = metadata.timestamp,
    user_type = metadata.user_type,
    subscriber = metadata.subscriber,
    turbo = metadata.turbo,
    mod = metadata.mod,
    vip = metadata.vip,
    badges = badges,
    emotes = emotes,
    color = metadata.color,
    room_id = metadata.room_id,
    user_id = metadata.user_id,
    bits = metadata.bits,
    raw_message = message,
  }

  emit_event(conn, events.EVENTS.MESSAGE_RECEIVED, chat_message)
end

local function handle_join(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]
  local nick = message.prefix and message.prefix:match('([^!]+)')

  if not conn.channels[channel] then
    conn.channels[channel] = {
      name = channel,
      joined = false,
      users = {},
      modes = {},
    }
  end

  if nick == conn.nick then
    conn.channels[channel].joined = true
    emit_event(conn, events.EVENTS.CHANNEL_JOINED, {
      channel = channel,
      nick = nick,
    })
  else
    conn.channels[channel].users[nick] = true
    emit_event(conn, events.EVENTS.USER_JOINED, {
      channel = channel,
      nick = nick,
    })
  end
end

local function handle_part(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]
  local nick = message.prefix and message.prefix:match('([^!]+)')
  local reason = message.params[2]

  if conn.channels[channel] then
    if nick == conn.nick then
      conn.channels[channel].joined = false
      emit_event(conn, events.EVENTS.CHANNEL_LEFT, {
        channel = channel,
        nick = nick,
        reason = reason,
      })
    else
      conn.channels[channel].users[nick] = nil
      emit_event(conn, events.EVENTS.USER_LEFT, {
        channel = channel,
        nick = nick,
        reason = reason,
      })
    end
  end
end

local function handle_notice(conn, message)
  if #message.params < 1 then
    return
  end

  local target = message.params[1]
  local text = message.params[2] or ''

  emit_event(conn, events.EVENTS.NOTICE_RECEIVED, {
    target = target,
    text = text,
    tags = message.tags,
  })
end

local function handle_usernotice(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]
  local text = message.params[2] or ''

  emit_event(conn, events.EVENTS.USER_NOTICE_RECEIVED, {
    channel = channel,
    text = text,
    msg_id = message.tags['msg-id'],
    system_msg = message.tags['system-msg'],
    tags = message.tags,
  })
end

local function handle_roomstate(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]

  if not conn.channels[channel] then
    conn.channels[channel] = {
      name = channel,
      joined = false,
      users = {},
      modes = {},
    }
  end

  -- Update channel modes based on tags
  if message.tags then
    for key, value in pairs(message.tags) do
      if key:match('^[a-z-]+$') then
        conn.channels[channel].modes[key] = value
      end
    end
  end

  emit_event(conn, events.EVENTS.ROOM_STATE_CHANGED, {
    channel = channel,
    modes = conn.channels[channel].modes,
  })
end

local function handle_userstate(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]

  emit_event(conn, events.EVENTS.USER_STATE_CHANGED, {
    channel = channel,
    tags = message.tags,
  })
end

local function handle_clearchat(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]
  local target_user = message.params[2]

  emit_event(conn, events.EVENTS.CHAT_CLEARED, {
    channel = channel,
    target_user = target_user,
    ban_duration = message.tags['ban-duration'],
    ban_reason = message.tags['ban-reason'],
  })
end

local function handle_clearmsg(conn, message)
  if #message.params < 1 then
    return
  end

  local channel = message.params[1]
  local deleted_message = message.params[2]

  emit_event(conn, events.EVENTS.MESSAGE_DELETED, {
    channel = channel,
    deleted_message = deleted_message,
    target_msg_id = message.tags['target-msg-id'],
  })
end

-- IRC command handlers map
local message_handlers = {
  ['PING'] = handle_ping,
  ['PONG'] = handle_pong,
  ['PRIVMSG'] = handle_privmsg,
  ['JOIN'] = handle_join,
  ['PART'] = handle_part,
  ['NOTICE'] = handle_notice,
  ['USERNOTICE'] = handle_usernotice,
  ['ROOMSTATE'] = handle_roomstate,
  ['USERSTATE'] = handle_userstate,
  ['CLEARCHAT'] = handle_clearchat,
  ['CLEARMSG'] = handle_clearmsg,
}

-- Process incoming IRC messages
local function process_irc_message(conn, line)
  local message = parse_irc_message(line)

  if message_handlers[message.command] then
    message_handlers[message.command](conn, message)
  else
    -- Handle numeric replies
    local numeric_code = tonumber(message.command)
    if numeric_code then
      if numeric_code == 1 then -- RPL_WELCOME
        conn.authenticated = true
        emit_event(conn, events.EVENTS.AUTHENTICATED, {
          nick = conn.nick,
          server = conn.config.server,
        })
      elseif numeric_code == 353 then -- RPL_NAMREPLY
        local channel = message.params[2]
        local names = message.params[3]

        if conn.channels[channel] then
          for name in names:gmatch('%S+') do
            -- Remove mode prefixes like @, +, etc.
            local clean_name = name:gsub('^[%@%+%%]', '')
            conn.channels[channel].users[clean_name] = true
          end
        end
      elseif numeric_code == 366 then -- RPL_ENDOFNAMES
        local channel = message.params[1]
        emit_event(conn, events.EVENTS.NAMES_RECEIVED, {
          channel = channel,
          users = conn.channels[channel] and conn.channels[channel].users or {},
        })
      end
    end
  end

  -- Always emit raw message for debugging/logging
  emit_event(conn, events.EVENTS.RAW_MESSAGE, {
    line = line,
    message = message,
  })
end

---Create a new IRC connection
---@param config IRCConfig
---@param callbacks table<string, function>
---@return IRCConnection
function M.connect(config, callbacks)
  config = vim.tbl_deep_extend('force', default_config, config or {})
  callbacks = callbacks or {}

  local conn = {
    config = config,
    websocket_conn = nil,
    connected = false,
    authenticated = false,
    channels = {},
    nick = config.nick,
    capabilities = {},
    last_ping = 0,
    last_pong = 0,
    message_queue = {},
    join_queue = {},
    callbacks = callbacks,
    rate_limiters = {
      message = create_rate_limiter(config.message_rate_limit, 30000),
      join = create_rate_limiter(config.join_rate_limit, 15000),
    },
  }

  -- WebSocket callbacks
  local ws_callbacks = {
    connect = function()
      conn.connected = true
      emit_event(conn, events.EVENTS.CONNECTION_OPENED, {})

      -- Send authentication
      if config.pass ~= '' then
        websocket.send_raw(conn.websocket_conn, 'PASS ' .. config.pass)
      end
      websocket.send_raw(conn.websocket_conn, 'NICK ' .. config.nick)

      -- Request capabilities
      if #config.capabilities > 0 then
        local cap_req = 'CAP REQ :' .. table.concat(config.capabilities, ' ')
        websocket.send_raw(conn.websocket_conn, cap_req)
      end
    end,

    message = function(data)
      -- Split multiple IRC messages (can be sent in one WebSocket frame)
      for line in data.data:gmatch('[^\r\n]+') do
        if line ~= '' then
          process_irc_message(conn, line)
        end
      end
    end,

    error = function(data)
      emit_event(conn, events.EVENTS.CONNECTION_ERROR, data)
    end,

    disconnect = function(data)
      conn.connected = false
      conn.authenticated = false
      emit_event(conn, events.EVENTS.CONNECTION_LOST, data)
    end,

    close = function(data)
      conn.connected = false
      conn.authenticated = false
      emit_event(conn, events.EVENTS.CONNECTION_CLOSED, data)
    end,
  }

  -- Create WebSocket connection
  conn.websocket_conn = websocket.connect(config.server, ws_callbacks)

  -- Start connection health monitoring
  local connection_id = string.format('irc_%s_%s', config.server, config.nick)
  local monitor_callbacks = {
    send_ping = function()
      return M.send_ping(conn)
    end,
    reconnect = function()
      return M.reconnect(conn)
    end,
  }

  connection_monitor.start_monitoring(connection_id, conn, monitor_callbacks)
  conn.monitor_id = connection_id

  -- Start processing queues
  ---@type Timer
  local queue_timer = uv.new_timer()
  queue_timer:start(1000, 1000, function()
    vim.schedule(function()
      if conn.connected then
        process_message_queue(conn)
        process_join_queue(conn)
      end
    end)
  end)

  return conn
end

---Send a message to a channel
---@param conn IRCConnection
---@param channel string
---@param message string
---@return boolean success
function M.send_message(conn, channel, message)
  if not conn.connected or not conn.authenticated then
    return false
  end

  local irc_msg = format_irc_message('PRIVMSG', { channel, message })

  if rate_limit_check(conn.rate_limiters.message) then
    rate_limit_add(conn.rate_limiters.message)
    return websocket.send(conn.websocket_conn, irc_msg)
  else
    table.insert(conn.message_queue, irc_msg)
    return true
  end
end

---Join a channel
---@param conn IRCConnection
---@param channel string
---@return boolean success
function M.join_channel(conn, channel)
  if not conn.connected or not conn.authenticated then
    return false
  end

  -- Ensure channel starts with #
  if not channel:match('^#') then
    channel = '#' .. channel
  end

  if rate_limit_check(conn.rate_limiters.join) then
    rate_limit_add(conn.rate_limiters.join)
    local join_msg = format_irc_message('JOIN', { channel })
    return websocket.send(conn.websocket_conn, join_msg)
  else
    table.insert(conn.join_queue, channel)
    return true
  end
end

---Leave a channel
---@param conn IRCConnection
---@param channel string
---@param reason string?
---@return boolean success
function M.part_channel(conn, channel, reason)
  if not conn.connected or not conn.authenticated then
    return false
  end

  local params = { channel }
  if reason then
    table.insert(params, reason)
  end

  local part_msg = format_irc_message('PART', params)
  return websocket.send(conn.websocket_conn, part_msg)
end

---Send a raw IRC command
---@param conn IRCConnection
---@param command string
---@param params string[]?
---@return boolean success
function M.send_raw(conn, command, params)
  if not conn.connected then
    return false
  end

  local irc_msg = format_irc_message(command, params)

  if rate_limit_check(conn.rate_limiters.message) then
    rate_limit_add(conn.rate_limiters.message)
    return websocket.send(conn.websocket_conn, irc_msg)
  else
    table.insert(conn.message_queue, irc_msg)
    return true
  end
end

---Disconnect from IRC
---@param conn IRCConnection
---@param reason string?
function M.disconnect(conn, reason)
  if conn.connected then
    local quit_msg = format_irc_message('QUIT', reason and { reason } or nil)
    websocket.send_raw(conn.websocket_conn, quit_msg)
  end

  if conn.websocket_conn then
    websocket.close(conn.websocket_conn)
  end

  -- Stop health monitoring
  if conn.monitor_id then
    connection_monitor.stop_monitoring(conn.monitor_id)
    conn.monitor_id = nil
  end

  conn.connected = false
  conn.authenticated = false
end

---Check if connected to IRC
---@param conn IRCConnection
---@return boolean
function M.is_connected(conn)
  return conn.connected and conn.authenticated
end

---Send a ping for health monitoring
---@param conn IRCConnection
---@return boolean success
function M.send_ping(conn)
  if not conn.connected then
    return false
  end

  conn.last_ping = uv.hrtime() / 1000000
  local ping_msg = format_irc_message('PING', { 'health_check' })
  return websocket.send_raw(conn.websocket_conn, ping_msg)
end

---Attempt to reconnect the IRC connection
---@param conn IRCConnection
---@return boolean success
function M.reconnect(conn)
  -- Disconnect first
  M.disconnect(conn, 'Reconnecting')

  -- Wait a moment before reconnecting
  vim.defer_fn(function()
    -- Recreate WebSocket connection
    local ws_callbacks = conn.websocket_conn and conn.websocket_conn.callbacks or {}
    conn.websocket_conn = websocket.connect(conn.config.server, ws_callbacks)
  end, 1000)

  return true
end

---Check if joined to a channel
---@param conn IRCConnection
---@param channel string
---@return boolean
function M.is_joined(conn, channel)
  return conn.channels[channel] and conn.channels[channel].joined
end

---Get list of joined channels
---@param conn IRCConnection
---@return string[]
function M.get_channels(conn)
  local channels = {}
  for channel, info in pairs(conn.channels) do
    if info.joined then
      table.insert(channels, channel)
    end
  end
  return channels
end

---Get channel information
---@param conn IRCConnection
---@param channel string
---@return IRCChannel?
function M.get_channel_info(conn, channel)
  return conn.channels[channel]
end

---Get connection status
---@param conn IRCConnection
---@return table
function M.get_status(conn)
  return {
    connected = conn.connected,
    authenticated = conn.authenticated,
    nick = conn.nick,
    channels = M.get_channels(conn),
    message_queue_size = #conn.message_queue,
    join_queue_size = #conn.join_queue,
    websocket_status = conn.websocket_conn and websocket.get_status(conn.websocket_conn) or nil,
  }
end

---Process queued messages and joins
---@param conn IRCConnection
function M.process_queues(conn)
  process_message_queue(conn)
  process_join_queue(conn)
end

---Parse IRC message string (for testing)
---@param raw_message string
---@return IRCMessage?
function M.parse_message(raw_message)
  if not raw_message or raw_message == '' then
    return nil
  end

  local message = {
    raw = raw_message,
    prefix = nil,
    command = '',
    params = {},
    tags = {},
  }

  local pos = 1

  -- Parse tags (IRCv3)
  if raw_message:sub(1, 1) == '@' then
    local tag_end = raw_message:find(' ', pos + 1)
    if tag_end then
      local tag_string = raw_message:sub(2, tag_end - 1)
      for tag in tag_string:gmatch('[^;]+') do
        local key, value = tag:match('([^=]+)=?(.*)')
        if key then
          message.tags[key] = value or ''
        end
      end
      pos = tag_end + 1
    end
  end

  -- Parse prefix
  if raw_message:sub(pos, pos) == ':' then
    local prefix_end = raw_message:find(' ', pos + 1)
    if prefix_end then
      message.prefix = raw_message:sub(pos + 1, prefix_end - 1)
      pos = prefix_end + 1
    end
  end

  -- Parse command and params
  local remaining = raw_message:sub(pos)
  local parts = {}
  for part in remaining:gmatch('%S+') do
    table.insert(parts, part)
  end

  if #parts > 0 then
    message.command = parts[1]
    for i = 2, #parts do
      table.insert(message.params, parts[i])
    end
  end

  return message
end

return M
