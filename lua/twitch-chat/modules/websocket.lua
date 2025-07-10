-- lua/twitch-chat/modules/websocket.lua
-- WebSocket client implementation using vim.uv

local uv = vim.uv or vim.loop
local M = {}
local logger = require('twitch-chat.modules.logger')

---@class Timer : userdata
---@field start fun(self: Timer, timeout: number, repeat_timeout: number, callback: function): boolean
---@field stop fun(self: Timer): boolean
---@field close fun(self: Timer): nil

-- Simple bit operations for Lua 5.1 compatibility
local bit = {}
function bit.band(a, b)
  local result = 0
  local bit_value = 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      result = result + bit_value
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_value = bit_value * 2
  end
  return result
end

function bit.bxor(a, b)
  local result = 0
  local bit_value = 1
  while a > 0 or b > 0 do
    if (a % 2) ~= (b % 2) then
      result = result + bit_value
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_value = bit_value * 2
  end
  return result
end

-- Optional: if you want to use the global event system
-- local events = require('twitch-chat.events')

---@class WebSocketConfig
---@field url string
---@field timeout number
---@field reconnect_interval number
---@field max_reconnect_attempts number
---@field ping_interval number
---@field rate_limit_messages number
---@field rate_limit_window number

---@class WebSocketConnection
---@field url string
---@field connected boolean
---@field connecting boolean
---@field tcp_handle userdata?
---@field callbacks table<string, function>
---@field config WebSocketConfig
---@field reconnect_attempts number
---@field reconnect_timer userdata?
---@field ping_timer userdata?
---@field message_queue table[]
---@field rate_limiter table
---@field last_ping number
---@field last_pong number
---@field close_code number?
---@field close_reason string?

-- Default configuration
local default_config = {
  url = 'wss://irc-ws.chat.twitch.tv:443',
  timeout = 10000,
  reconnect_interval = 5000,
  max_reconnect_attempts = 5,
  ping_interval = 30000,
  rate_limit_messages = 20,
  rate_limit_window = 30000,
}

-- Rate limiter implementation
local function create_rate_limiter(limit, window)
  return {
    limit = limit,
    window = window,
    timestamps = {},
  }
end

local function rate_limit_check(limiter)
  local now = uv.hrtime() / 1000000 -- Convert to milliseconds
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

-- WebSocket frame parsing helpers
local function parse_websocket_frame(data)
  if #data < 2 then
    return nil, 'Frame too short'
  end

  local byte1 = string.byte(data, 1)
  local byte2 = string.byte(data, 2)

  local fin = bit.band(byte1, 0x80) ~= 0
  local opcode = bit.band(byte1, 0x0F)
  local masked = bit.band(byte2, 0x80) ~= 0
  local payload_len = bit.band(byte2, 0x7F)

  local offset = 2

  -- Extended payload length
  if payload_len == 126 then
    if #data < offset + 2 then
      return nil, 'Frame too short for extended length'
    end
    payload_len = string.byte(data, offset + 1) * 256 + string.byte(data, offset + 2)
    offset = offset + 2
  elseif payload_len == 127 then
    if #data < offset + 8 then
      return nil, 'Frame too short for extended length'
    end
    -- For simplicity, we'll assume payload length fits in 32 bits
    payload_len = 0
    for i = 4, 7 do
      payload_len = payload_len * 256 + string.byte(data, offset + i + 1)
    end
    offset = offset + 8
  end

  -- Masking key
  local mask = nil
  if masked then
    if #data < offset + 4 then
      return nil, 'Frame too short for mask'
    end
    mask = string.sub(data, offset + 1, offset + 4)
    offset = offset + 4
  end

  -- Payload
  if #data < offset + payload_len then
    return nil, 'Frame too short for payload'
  end

  local payload = string.sub(data, offset + 1, offset + payload_len)

  -- Unmask payload if needed
  if masked and mask then
    local unmasked = {}
    for i = 1, #payload do
      local mask_byte = string.byte(mask, ((i - 1) % 4) + 1)
      local payload_byte = string.byte(payload, i)
      unmasked[i] = string.char(bit.bxor(payload_byte, mask_byte))
    end
    payload = table.concat(unmasked)
  end

  return {
    fin = fin,
    opcode = opcode,
    payload = payload,
    frame_len = offset + payload_len,
  }
end

local function create_websocket_frame(opcode, payload)
  local frame = {}

  -- First byte: FIN (1) + RSV (000) + OPCODE (4 bits)
  table.insert(frame, string.char(0x80 + opcode))

  -- Second byte: MASK (1) + PAYLOAD_LEN (7 bits)
  local payload_len = #payload
  local mask =
    string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))

  if payload_len < 126 then
    table.insert(frame, string.char(0x80 + payload_len))
  elseif payload_len < 65536 then
    table.insert(frame, string.char(0x80 + 126))
    table.insert(frame, string.char(math.floor(payload_len / 256)))
    table.insert(frame, string.char(payload_len % 256))
  else
    table.insert(frame, string.char(0x80 + 127))
    -- For simplicity, we'll use 32-bit length
    table.insert(frame, string.char(0, 0, 0, 0))
    table.insert(
      frame,
      string.char(
        math.floor(payload_len / 16777216),
        math.floor((payload_len % 16777216) / 65536),
        math.floor((payload_len % 65536) / 256),
        payload_len % 256
      )
    )
  end

  -- Add mask
  table.insert(frame, mask)

  -- Mask and add payload
  local masked_payload = {}
  for i = 1, #payload do
    local mask_byte = string.byte(mask, ((i - 1) % 4) + 1)
    local payload_byte = string.byte(payload, i)
    masked_payload[i] = string.char(bit.bxor(payload_byte, mask_byte))
  end
  table.insert(frame, table.concat(masked_payload))

  return table.concat(frame)
end

-- HTTP upgrade request for WebSocket
local function create_websocket_handshake(url, headers)
  local parsed_url = vim.split(url, '/', { plain = true })
  local host = parsed_url[3] or 'irc-ws.chat.twitch.tv:443'
  local path = '/' .. table.concat(parsed_url, '/', 4)

  local key = vim.fn.system('openssl rand -base64 16'):gsub('\n', '')

  local request = {
    'GET ' .. path .. ' HTTP/1.1',
    'Host: ' .. host,
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Key: ' .. key,
    'Sec-WebSocket-Version: 13',
  }

  if headers then
    for k, v in pairs(headers) do
      table.insert(request, k .. ': ' .. v)
    end
  end

  table.insert(request, '')
  table.insert(request, '')

  return table.concat(request, '\r\n')
end

-- Connection management
local function cleanup_connection(conn)
  -- Cleanup TCP handle
  if conn.tcp_handle then
    if not conn.tcp_handle:is_closing() then
      conn.tcp_handle:read_stop()
      conn.tcp_handle:close()
    end
    conn.tcp_handle = nil
  end

  -- Cleanup reconnect timer
  if conn.reconnect_timer then
    if not conn.reconnect_timer:is_closing() then
      conn.reconnect_timer:stop()
      conn.reconnect_timer:close()
    end
    conn.reconnect_timer = nil
  end

  -- Cleanup ping timer
  if conn.ping_timer then
    if not conn.ping_timer:is_closing() then
      conn.ping_timer:stop()
      conn.ping_timer:close()
    end
    conn.ping_timer = nil
  end

  -- Clear message queue to prevent memory leaks
  conn.message_queue = {}

  -- Reset rate limiter
  if conn.rate_limiter then
    conn.rate_limiter.timestamps = {}
  end

  -- Clear callbacks to prevent reference cycles
  conn.callbacks = {}

  conn.connected = false
  conn.connecting = false
end

local function emit_event(conn, event, data)
  if conn.callbacks and conn.callbacks[event] then
    local success, err = pcall(conn.callbacks[event], data)
    if not success then
      logger.error(
        'WebSocket event callback error',
        { error = tostring(err), module = 'websocket' }
      )
    end
  end
end

local function schedule_reconnect(conn)
  if conn.reconnect_attempts >= conn.config.max_reconnect_attempts then
    emit_event(conn, 'max_reconnect_attempts', {
      attempts = conn.reconnect_attempts,
      max_attempts = conn.config.max_reconnect_attempts,
    })
    return
  end

  conn.reconnect_attempts = conn.reconnect_attempts + 1
  ---@type Timer
  conn.reconnect_timer = uv.new_timer()

  conn.reconnect_timer:start(conn.config.reconnect_interval, 0, function()
    vim.schedule(function()
      M.connect(conn.config.url, conn.callbacks, conn.config)
    end)
  end)
end

local function start_ping_timer(conn)
  if conn.ping_timer then
    conn.ping_timer:stop()
    conn.ping_timer:close()
  end

  ---@type Timer
  conn.ping_timer = uv.new_timer()
  conn.ping_timer:start(conn.config.ping_interval, conn.config.ping_interval, function()
    vim.schedule(function()
      if conn.connected then
        conn.last_ping = uv.hrtime() / 1000000
        M.ping(conn)
      end
    end)
  end)
end

local function process_message_queue(conn)
  while #conn.message_queue > 0 and conn.connected do
    local message = table.remove(conn.message_queue, 1)
    if rate_limit_check(conn.rate_limiter) then
      rate_limit_add(conn.rate_limiter)
      M.send_raw(conn, message)
    else
      -- Put message back at the front of the queue
      table.insert(conn.message_queue, 1, message)
      break
    end
  end
end

-- Helper function to handle read errors
local function handle_read_error(conn, read_err)
  cleanup_connection(conn)
  emit_event(conn, 'error', { message = 'Read error: ' .. read_err })
  schedule_reconnect(conn)
end

-- Helper function to handle connection closure
local function handle_connection_close(conn)
  cleanup_connection(conn)
  emit_event(conn, 'disconnect', {
    code = conn.close_code,
    reason = conn.close_reason,
  })
  schedule_reconnect(conn)
end

-- Helper function to process WebSocket handshake
local function process_handshake(conn, buffer)
  local headers_end = buffer:find('\r\n\r\n')
  if not headers_end then
    return buffer, false
  end

  local headers = buffer:sub(1, headers_end - 1)
  local remaining_buffer = buffer:sub(headers_end + 4)

  -- Validate handshake response
  if headers:find('HTTP/1.1 101') and headers:find('Upgrade: websocket') then
    conn.connected = true
    conn.connecting = false
    conn.reconnect_attempts = 0

    emit_event(conn, 'connect', {})
    start_ping_timer(conn)

    -- Process any queued messages
    process_message_queue(conn)

    return remaining_buffer, true
  else
    cleanup_connection(conn)
    emit_event(conn, 'error', { message = 'Invalid handshake response' })
    schedule_reconnect(conn)
    return remaining_buffer, false
  end
end

-- Helper function to handle WebSocket close frame
local function handle_close_frame(conn, frame)
  local close_code = 1000
  local close_reason = ''

  if #frame.payload >= 2 then
    close_code = string.byte(frame.payload, 1) * 256 + string.byte(frame.payload, 2)
    close_reason = frame.payload:sub(3)
  end

  conn.close_code = close_code
  conn.close_reason = close_reason

  -- Send close frame back
  local close_frame = create_websocket_frame(0x8, frame.payload)
  conn.tcp_handle:write(close_frame)

  cleanup_connection(conn)
  emit_event(conn, 'close', {
    code = close_code,
    reason = close_reason,
  })

  if close_code ~= 1000 then
    schedule_reconnect(conn)
  end

  return true -- Indicates connection should be closed
end

-- Helper function to process WebSocket frames
local function process_websocket_frames(conn, buffer)
  while #buffer >= 2 do
    local frame, frame_err = parse_websocket_frame(buffer)
    if not frame then
      if frame_err == 'Frame too short' or (frame_err and frame_err:find('too short')) then
        break -- Wait for more data
      else
        cleanup_connection(conn)
        emit_event(
          conn,
          'error',
          { message = 'Frame parse error: ' .. (frame_err or 'unknown error') }
        )
        schedule_reconnect(conn)
        return buffer, true -- Error occurred
      end
    else
      -- frame is guaranteed to be non-nil here
      buffer = buffer:sub(frame.frame_len + 1)

      -- Handle frame based on opcode
      if frame.opcode == 0x1 then -- Text frame
        emit_event(conn, 'message', { data = frame.payload })
      elseif frame.opcode == 0x2 then -- Binary frame
        emit_event(conn, 'message', { data = frame.payload, binary = true })
      elseif frame.opcode == 0x8 then -- Close frame
        local should_close = handle_close_frame(conn, frame)
        if should_close then
          return buffer, true
        end
      elseif frame.opcode == 0x9 then -- Ping frame
        -- Send pong frame
        local pong_frame = create_websocket_frame(0xA, frame.payload)
        conn.tcp_handle:write(pong_frame)
      elseif frame.opcode == 0xA then -- Pong frame
        conn.last_pong = uv.hrtime() / 1000000
        emit_event(conn, 'pong', { data = frame.payload })
      end
    end
  end

  return buffer, false -- No error
end

---Create a new WebSocket connection
---@param url string
---@param callbacks table<string, function>
---@param config WebSocketConfig?
---@return WebSocketConnection
function M.connect(url, callbacks, config)
  config = vim.tbl_deep_extend('force', default_config, config or {})

  local conn = {
    url = url,
    connected = false,
    connecting = false,
    tcp_handle = nil,
    callbacks = callbacks or {},
    config = config,
    reconnect_attempts = 0,
    reconnect_timer = nil,
    ping_timer = nil,
    message_queue = {},
    rate_limiter = create_rate_limiter(config.rate_limit_messages, config.rate_limit_window),
    last_ping = 0,
    last_pong = 0,
    close_code = nil,
    close_reason = nil,
  }

  -- Parse URL
  local parsed_url = vim.split(url, '/', { plain = true })
  local protocol = parsed_url[1]:gsub(':', '')
  local host_port = parsed_url[3] or 'irc-ws.chat.twitch.tv:443'
  local host, port = host_port:match('([^:]+):?(%d*)')
  port = tonumber(port) or (protocol == 'wss' and 443 or 80)

  conn.connecting = true
  conn.tcp_handle = uv.new_tcp()

  -- Connect to server
  conn.tcp_handle:connect(host, port, function(err)
    if err then
      cleanup_connection(conn)
      emit_event(conn, 'error', { message = 'Connection failed: ' .. err })
      schedule_reconnect(conn)
      return
    end

    -- Send WebSocket handshake
    local handshake = create_websocket_handshake(url)
    local write_req = conn.tcp_handle:write(handshake)
    if not write_req then
      cleanup_connection(conn)
      emit_event(conn, 'error', { message = 'Handshake write failed' })
      schedule_reconnect(conn)
      return
    end

    -- Handle incoming data
    local buffer = ''
    local handshake_complete = false

    ---@diagnostic disable-next-line: redundant-parameter
    conn.tcp_handle:read_start(function(read_err, data)
      if read_err then
        handle_read_error(conn, read_err)
        return
      end

      if not data then
        handle_connection_close(conn)
        return
      end

      buffer = buffer .. data

      if not handshake_complete then
        local remaining_buffer, handshake_success = process_handshake(conn, buffer)
        buffer = remaining_buffer
        if handshake_success then
          handshake_complete = true
        elseif handshake_success == false then
          -- Handshake failed, connection will be cleaned up
          return
        end
      end

      if handshake_complete then
        local remaining_buffer, error_occurred = process_websocket_frames(conn, buffer)
        buffer = remaining_buffer
        if error_occurred then
          return
        end
      end
    end)
  end)

  -- Set connection timeout
  local timeout_timer = uv.new_timer()
  if timeout_timer then
    ---@cast timeout_timer Timer
    timeout_timer:start(config.timeout, 0, function()
      if conn.connecting then
        cleanup_connection(conn)
        emit_event(conn, 'error', { message = 'Connection timeout' })
        schedule_reconnect(conn)
      end
      timeout_timer:close()
    end)
  end

  return conn
end

---Send a text message through the WebSocket connection
---@param conn WebSocketConnection
---@param message string
---@return boolean success
function M.send(conn, message)
  if not conn.connected then
    table.insert(conn.message_queue, message)
    return false
  end

  if not rate_limit_check(conn.rate_limiter) then
    table.insert(conn.message_queue, message)
    return false
  end

  rate_limit_add(conn.rate_limiter)
  return M.send_raw(conn, message)
end

---Send a raw message without rate limiting
---@param conn WebSocketConnection
---@param message string
---@return boolean success
function M.send_raw(conn, message)
  if not conn.connected or not conn.tcp_handle then
    return false
  end

  local frame = create_websocket_frame(0x1, message)
  local success = conn.tcp_handle:write(frame)

  if not success then
    emit_event(conn, 'error', { message = 'Failed to send message' })
    return false
  end

  return true
end

---Send a ping frame
---@param conn WebSocketConnection
function M.ping(conn)
  if not conn.connected or not conn.tcp_handle then
    return false
  end

  local frame = create_websocket_frame(0x9, '')
  return conn.tcp_handle:write(frame)
end

---Close the WebSocket connection
---@param conn WebSocketConnection
---@param code number?
---@param reason string?
function M.close(conn, code, reason)
  if not conn.connected or not conn.tcp_handle then
    return
  end

  code = code or 1000
  reason = reason or ''

  local close_payload = string.char(math.floor(code / 256), code % 256) .. reason
  local close_frame = create_websocket_frame(0x8, close_payload)

  conn.tcp_handle:write(close_frame)

  -- Set close code and reason on connection
  conn.close_code = code
  conn.close_reason = reason

  cleanup_connection(conn)

  emit_event(conn, 'close', {
    code = code,
    reason = reason,
  })
end

---Check if the connection is active
---@param conn WebSocketConnection
---@return boolean
function M.is_connected(conn)
  return not not (conn.connected and conn.tcp_handle and not conn.tcp_handle:is_closing())
end

---Get connection status
---@param conn WebSocketConnection
---@return table
function M.get_status(conn)
  return {
    connected = conn.connected,
    connecting = conn.connecting,
    reconnect_attempts = conn.reconnect_attempts,
    max_reconnect_attempts = conn.config.max_reconnect_attempts,
    message_queue_size = #conn.message_queue,
    rate_limiter_count = #conn.rate_limiter.timestamps,
    last_ping = conn.last_ping,
    last_pong = conn.last_pong,
    close_code = conn.close_code,
    close_reason = conn.close_reason,
  }
end

---Process queued messages (useful for manual rate limiting)
---@param conn WebSocketConnection
function M.process_queue(conn)
  process_message_queue(conn)
end

---Manually trigger reconnection
---@param conn WebSocketConnection
---@param delay number? Delay in milliseconds before reconnection
---@return boolean success
function M.reconnect(conn, delay)
  vim.validate({
    conn = { conn, 'table' },
    delay = { delay, 'number', true },
  })

  if conn.connected then
    return true -- Already connected
  end

  if conn.reconnect_attempts >= conn.config.max_reconnect_attempts then
    return false -- Max attempts exceeded
  end

  delay = delay or calculate_reconnect_delay(conn.reconnect_attempts)

  -- Schedule reconnection
  if delay > 0 then
    vim.defer_fn(function()
      if not conn.connected then
        schedule_reconnect(conn)
      end
    end, delay)
  else
    schedule_reconnect(conn)
  end

  return true
end

---Gracefully shutdown connection with proper cleanup
---@param conn WebSocketConnection
---@param timeout number? Timeout in milliseconds for graceful shutdown
function M.shutdown(conn, timeout)
  timeout = timeout or 5000

  if not conn or not conn.tcp_handle then
    return
  end

  logger.debug('Starting graceful WebSocket shutdown', { module = 'websocket' })

  -- Send close frame first
  if conn.connected then
    M.close(conn, 1000, 'Shutting down')
  end

  -- Set timeout for forced cleanup
  local shutdown_timer = uv.new_timer()
  if shutdown_timer then
    shutdown_timer:start(timeout, 0, function()
      logger.warn('WebSocket shutdown timeout, forcing cleanup', { module = 'websocket' })
      cleanup_connection(conn)
      shutdown_timer:close()
    end)
  end
end

---Get resource usage statistics for monitoring
---@param conn WebSocketConnection
---@return table stats
function M.get_resource_stats(conn)
  if not conn then
    return {
      tcp_handle_active = false,
      timers_active = 0,
      message_queue_size = 0,
      rate_limiter_entries = 0,
      callbacks_registered = 0,
      memory_estimate_bytes = 0,
    }
  end

  local timers_active = 0
  if conn.reconnect_timer and not conn.reconnect_timer:is_closing() then
    timers_active = timers_active + 1
  end
  if conn.ping_timer and not conn.ping_timer:is_closing() then
    timers_active = timers_active + 1
  end

  local callback_count = 0
  for _, _ in pairs(conn.callbacks or {}) do
    callback_count = callback_count + 1
  end

  -- Rough memory estimate
  local memory_estimate = 0
  memory_estimate = memory_estimate + (#conn.message_queue * 100) -- ~100 bytes per queued message
  memory_estimate = memory_estimate + (#(conn.rate_limiter.timestamps or {}) * 8) -- 8 bytes per timestamp
  memory_estimate = memory_estimate + (callback_count * 50) -- ~50 bytes per callback

  return {
    tcp_handle_active = conn.tcp_handle and not conn.tcp_handle:is_closing(),
    timers_active = timers_active,
    message_queue_size = #conn.message_queue,
    rate_limiter_entries = #(conn.rate_limiter.timestamps or {}),
    callbacks_registered = callback_count,
    memory_estimate_bytes = memory_estimate,
  }
end

return M
