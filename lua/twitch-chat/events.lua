---@class TwitchChatEvents
---Event system for inter-module communication
local M = {}
local utils = require('twitch-chat.utils')

---@type table<string, function[]>
local event_handlers = {}

-- Ensure event_handlers is always initialized
local function ensure_handlers()
  if not event_handlers then
    event_handlers = {}
  end
end

-- Event constants
M.MESSAGE_RECEIVED = 'message_received'
M.CHANNEL_JOINED = 'channel_joined'
M.CHANNEL_LEFT = 'channel_left'
M.CONNECTION_LOST = 'connection_lost'
M.CONNECTION_ESTABLISHED = 'connection_established'
M.SEND_MESSAGE = 'send_message'
M.USER_JOINED = 'user_joined'
M.USER_LEFT = 'user_left'
M.ERROR_OCCURRED = 'error_occurred'

-- Configuration events
M.CONFIG_CHANGED = 'config_changed'

-- Authentication events
M.AUTH_SUCCESS = 'auth_success'
M.AUTH_FAILED = 'auth_failed'

-- API events
M.ERROR = 'error'

-- Additional IRC and connection events
M.RAW_MESSAGE = 'raw_message'
M.CONNECTION_OPENED = 'connection_opened'
M.CONNECTION_ERROR = 'connection_error'
M.CONNECTION_CLOSED = 'connection_closed'
M.NOTICE_RECEIVED = 'notice_received'
M.USER_NOTICE_RECEIVED = 'user_notice_received'
M.ROOM_STATE_CHANGED = 'room_state_changed'
M.USER_STATE_CHANGED = 'user_state_changed'
M.CHAT_CLEARED = 'chat_cleared'
M.MESSAGE_DELETED = 'message_deleted'
M.AUTHENTICATED = 'authenticated'
M.NAMES_RECEIVED = 'names_received'

-- EVENTS namespace for backward compatibility
M.EVENTS = {
  MESSAGE_RECEIVED = M.MESSAGE_RECEIVED,
  CHANNEL_JOINED = M.CHANNEL_JOINED,
  CHANNEL_LEFT = M.CHANNEL_LEFT,
  CONNECTION_LOST = M.CONNECTION_LOST,
  CONNECTION_ESTABLISHED = M.CONNECTION_ESTABLISHED,
  SEND_MESSAGE = M.SEND_MESSAGE,
  USER_JOINED = M.USER_JOINED,
  USER_LEFT = M.USER_LEFT,
  ERROR_OCCURRED = M.ERROR_OCCURRED,
  CONFIG_CHANGED = M.CONFIG_CHANGED,
  AUTH_SUCCESS = M.AUTH_SUCCESS,
  AUTH_FAILED = M.AUTH_FAILED,
  ERROR = M.ERROR,
  RAW_MESSAGE = M.RAW_MESSAGE,
  CONNECTION_OPENED = M.CONNECTION_OPENED,
  CONNECTION_ERROR = M.CONNECTION_ERROR,
  CONNECTION_CLOSED = M.CONNECTION_CLOSED,
  NOTICE_RECEIVED = M.NOTICE_RECEIVED,
  USER_NOTICE_RECEIVED = M.USER_NOTICE_RECEIVED,
  ROOM_STATE_CHANGED = M.ROOM_STATE_CHANGED,
  USER_STATE_CHANGED = M.USER_STATE_CHANGED,
  CHAT_CLEARED = M.CHAT_CLEARED,
  MESSAGE_DELETED = M.MESSAGE_DELETED,
  AUTHENTICATED = M.AUTHENTICATED,
  NAMES_RECEIVED = M.NAMES_RECEIVED,
}

---Register an event handler
---@param event string
---@param handler function
function M.on(event, handler)
  -- Validate inputs
  if type(event) ~= 'string' or type(handler) ~= 'function' then
    return false
  end

  ensure_handlers()
  if not event_handlers[event] then
    event_handlers[event] = {}
  end
  table.insert(event_handlers[event], handler)
  return true
end

---Remove an event handler
---@param event string
---@param handler function
function M.off(event, handler)
  ensure_handlers()
  if not event_handlers[event] then
    return
  end

  for i, h in ipairs(event_handlers[event]) do
    if h == handler then
      table.remove(event_handlers[event], i)
      break
    end
  end
end

---Emit an event to all registered handlers
---@param event string
---@param data any
---@param callback function?
function M.emit(event, data, callback)
  -- Validate event name
  if type(event) ~= 'string' then
    if callback then
      callback()
    end
    return
  end

  ensure_handlers()
  if not event_handlers[event] then
    if callback then
      callback()
    end
    return
  end

  for _, handler in ipairs(event_handlers[event]) do
    local ok, result = pcall(handler, data)
    if not ok then
      utils.log(
        vim.log.levels.ERROR,
        'Error in event handler',
        { event = event, error = result, module = 'events' }
      )
    end
  end

  if callback then
    callback()
  end
end

---Remove all handlers for an event
---@param event string
function M.clear(event)
  event_handlers[event] = nil
end

---Remove all event handlers
function M.clear_all()
  event_handlers = {}
end

---Get all registered events
---@return string[]
function M.get_events()
  ensure_handlers()
  return vim.tbl_keys(event_handlers)
end

---Get handler count for an event
---@param event string
---@return number
function M.get_handler_count(event)
  ensure_handlers()
  return event_handlers[event] and #event_handlers[event] or 0
end

---Create a namespaced event emitter
---@param namespace string
---@return table
function M.create_namespace(namespace)
  local namespaced = {}

  function namespaced.on(event, handler)
    M.on(namespace .. ':' .. event, handler)
  end

  function namespaced.off(event, handler)
    M.off(namespace .. ':' .. event, handler)
  end

  function namespaced.emit(event, data, callback)
    M.emit(namespace .. ':' .. event, data, callback)
  end

  function namespaced.clear(event)
    M.clear(namespace .. ':' .. event)
  end

  return namespaced
end

---Setup the event system
function M.setup()
  -- Initialize event system
  ensure_handlers()
end

---Clear all handlers (for testing/reloading)
function M.reset()
  event_handlers = {}
  ensure_handlers()
end

return M
