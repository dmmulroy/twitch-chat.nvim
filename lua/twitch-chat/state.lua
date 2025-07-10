---@class TwitchChatState
local M = {}
local utils = require('twitch-chat.utils')

-- Central state storage
local state = {
  authenticated = false,
  access_token = nil,
  channels = {},
  channel_messages = {},
  channel_emotes = {},
  channel_info = {},
  channel_settings = {},
  connected = false,
  active_channel = nil,
  cache = {},
  event_handlers = {},
}

---Reset all state to initial values
---@return nil
function M.reset()
  state = {
    authenticated = false,
    access_token = nil,
    channels = {},
    channel_messages = {},
    channel_emotes = {},
    channel_info = {},
    channel_settings = {},
    connected = false,
    active_channel = nil,
    cache = {},
    event_handlers = {},
  }
end

-- Authentication methods
---@param authenticated boolean
function M.set_authenticated(authenticated)
  state.authenticated = authenticated
end

---@return boolean
function M.is_authenticated()
  return state.authenticated
end

---@param token string?
function M.set_access_token(token)
  state.access_token = token
end

---@return string?
function M.get_access_token()
  return state.access_token
end

-- Connection methods
---@param connected boolean
function M.set_connected(connected)
  state.connected = connected
end

---@return boolean
function M.is_connected()
  return state.connected
end

-- Channel methods
---@param channel string
function M.add_channel(channel)
  if not vim.tbl_contains(state.channels, channel) then
    table.insert(state.channels, channel)
  end
  if not state.channel_messages[channel] then
    state.channel_messages[channel] = {}
  end
  if not state.channel_emotes[channel] then
    state.channel_emotes[channel] = {}
  end
  if not state.channel_settings[channel] then
    state.channel_settings[channel] = {}
  end
end

---@return string[]
function M.get_channels()
  return vim.deepcopy(state.channels)
end

---@param channel string
function M.set_active_channel(channel)
  state.active_channel = channel
end

---@return string?
function M.get_active_channel()
  return state.active_channel
end

-- Message methods
---@param channel string
---@param message table
function M.add_message(channel, message)
  if not state.channel_messages[channel] then
    state.channel_messages[channel] = {}
  end
  table.insert(state.channel_messages[channel], message)
end

---@param channel string
---@return table[]
function M.get_channel_messages(channel)
  return vim.deepcopy(state.channel_messages[channel] or {})
end

-- Emote methods
---@param channel string
---@param emotes table[]
function M.set_channel_emotes(channel, emotes)
  state.channel_emotes[channel] = emotes
end

---@param channel string
---@return table[]
function M.get_channel_emotes(channel)
  return vim.deepcopy(state.channel_emotes[channel] or {})
end

-- Channel info methods
---@param channel string
---@param info table
function M.set_channel_info(channel, info)
  state.channel_info[channel] = info
end

---@param channel string
---@return table?
function M.get_channel_info(channel)
  return vim.deepcopy(state.channel_info[channel])
end

-- Channel settings methods
---@param channel string
---@param settings table
function M.set_channel_settings(channel, settings)
  state.channel_settings[channel] = settings
end

---@param channel string
---@return table
function M.get_channel_settings(channel)
  return vim.deepcopy(state.channel_settings[channel] or {})
end

-- Cache methods
---@param key string
---@param value any
---@param ttl number? Time to live in seconds
function M.cache_set(key, value, ttl)
  local expiry = ttl and (os.time() + ttl) or nil
  state.cache[key] = {
    value = value,
    expiry = expiry,
  }
end

---@param key string
---@return any?
function M.cache_get(key)
  local cached = state.cache[key]
  if not cached then
    return nil
  end

  if cached.expiry and os.time() > cached.expiry then
    state.cache[key] = nil
    return nil
  end

  return cached.value
end

---Clear all cache entries
function M.cache_clear()
  state.cache = {}
end

-- Event system methods
---@param event string
---@param handler function
function M.on(event, handler)
  if not state.event_handlers[event] then
    state.event_handlers[event] = {}
  end
  table.insert(state.event_handlers[event], handler)
end

---@param event string
---@param data any?
function M.emit(event, data)
  local handlers = state.event_handlers[event]
  if handlers then
    for _, handler in ipairs(handlers) do
      local success, err = pcall(handler, data)
      if not success then
        utils.log(vim.log.levels.ERROR, 'Event handler error', { error = err, module = 'state' })
      end
    end
  end
end

---Get debug information about current state
---@return table
function M.get_debug_info()
  return {
    authenticated = state.authenticated,
    connected = state.connected,
    active_channel = state.active_channel,
    channel_count = #state.channels,
    total_messages = vim.tbl_count(state.channel_messages),
    cache_size = vim.tbl_count(state.cache),
    event_types = vim.tbl_keys(state.event_handlers),
  }
end

return M
