-- Connection Health Monitoring and Automatic Recovery
-- Monitors connection quality and triggers recovery mechanisms

local M = {}

---@class ConnectionMonitorConfig
---@field enabled boolean Enable health monitoring
---@field ping_interval number Ping interval in milliseconds
---@field ping_timeout number Ping timeout in milliseconds
---@field max_missed_pings number Max missed pings before considering unhealthy
---@field reconnect_interval number Base reconnect interval in milliseconds
---@field max_reconnect_attempts number Maximum reconnection attempts
---@field backoff_multiplier number Exponential backoff multiplier
---@field max_backoff_interval number Maximum backoff interval
---@field quality_window_size number Number of samples for quality metrics
---@field latency_threshold number High latency threshold in milliseconds

---@class ConnectionHealth
---@field is_healthy boolean Current health status
---@field consecutive_failures number Consecutive ping failures
---@field last_ping_time number Last ping timestamp
---@field last_pong_time number Last pong timestamp
---@field average_latency number Average ping latency
---@field latency_samples number[] Recent latency samples
---@field reconnect_attempts number Current reconnection attempts
---@field last_reconnect_time number Last reconnection attempt timestamp
---@field quality_score number Connection quality score (0-100)

local uv = vim.uv or vim.loop
local utils = require('twitch-chat.utils')
local events = require('twitch-chat.events')
local circuit_breaker = require('twitch-chat.modules.circuit_breaker')

-- Health monitoring state per connection
local connection_monitors = {}

-- Circuit breaker for reconnection operations
local reconnect_breaker = circuit_breaker.get_or_create('reconnection', {
  failure_threshold = 5,
  recovery_timeout = 300000, -- 5 minutes
  success_threshold = 2,
  timeout = 30000,
})

---@type ConnectionMonitorConfig
local default_config = {
  enabled = true,
  ping_interval = 30000, -- 30 seconds
  ping_timeout = 10000, -- 10 seconds
  max_missed_pings = 3, -- 3 missed pings = unhealthy
  reconnect_interval = 5000, -- 5 seconds base interval
  max_reconnect_attempts = 10, -- 10 attempts before giving up
  backoff_multiplier = 1.5, -- Exponential backoff
  max_backoff_interval = 300000, -- 5 minutes max
  quality_window_size = 10, -- Last 10 samples
  latency_threshold = 5000, -- 5 seconds high latency
}

---Initialize connection monitoring
---@param config ConnectionMonitorConfig? Configuration options
function M.setup(config)
  M.config = vim.tbl_deep_extend('force', default_config, config or {})

  if not M.config.enabled then
    utils.log(vim.log.levels.INFO, 'Connection monitoring disabled')
    return
  end

  utils.log(vim.log.levels.INFO, 'Connection monitoring initialized')
end

---Start monitoring a connection
---@param connection_id string Unique connection identifier
---@param connection_handle any Connection handle (WebSocket, IRC, etc.)
---@param callbacks table Callback functions for recovery actions
function M.start_monitoring(connection_id, connection_handle, callbacks)
  if not M.config.enabled then
    return
  end

  local monitor = {
    connection_id = connection_id,
    connection_handle = connection_handle,
    callbacks = callbacks or {},
    health = {
      is_healthy = true,
      consecutive_failures = 0,
      last_ping_time = 0,
      last_pong_time = 0,
      average_latency = 0,
      latency_samples = {},
      reconnect_attempts = 0,
      last_reconnect_time = 0,
      quality_score = 100,
    },
    ping_timer = nil,
    timeout_timer = nil,
  }

  connection_monitors[connection_id] = monitor

  -- Start ping timer
  M._start_ping_timer(monitor)

  utils.log(vim.log.levels.INFO, string.format('Started monitoring connection: %s', connection_id))
end

---Stop monitoring a connection
---@param connection_id string Connection identifier
function M.stop_monitoring(connection_id)
  local monitor = connection_monitors[connection_id]
  if not monitor then
    return
  end

  -- Clean up timers
  if monitor.ping_timer then
    monitor.ping_timer:stop()
    monitor.ping_timer:close()
  end

  if monitor.timeout_timer then
    monitor.timeout_timer:stop()
    monitor.timeout_timer:close()
  end

  connection_monitors[connection_id] = nil

  utils.log(vim.log.levels.INFO, string.format('Stopped monitoring connection: %s', connection_id))
end

---Record a successful pong response
---@param connection_id string Connection identifier
---@param latency number? Response latency in milliseconds
function M.record_pong(connection_id, latency)
  local monitor = connection_monitors[connection_id]
  if not monitor then
    return
  end

  local current_time = os.time() * 1000
  monitor.health.last_pong_time = current_time
  monitor.health.consecutive_failures = 0

  -- Calculate latency if not provided
  if not latency and monitor.health.last_ping_time > 0 then
    latency = current_time - monitor.health.last_ping_time
  end

  if latency then
    M._update_latency_metrics(monitor, latency)
  end

  M._update_health_status(monitor)

  -- Cancel timeout timer
  if monitor.timeout_timer then
    monitor.timeout_timer:stop()
    monitor.timeout_timer = nil
  end
end

---Record a missed pong (timeout)
---@param connection_id string Connection identifier
function M.record_timeout(connection_id)
  local monitor = connection_monitors[connection_id]
  if not monitor then
    return
  end

  monitor.health.consecutive_failures = monitor.health.consecutive_failures + 1
  M._update_health_status(monitor)

  utils.log(
    vim.log.levels.WARN,
    string.format(
      'Ping timeout for connection %s (failures: %d)',
      connection_id,
      monitor.health.consecutive_failures
    )
  )

  -- Trigger recovery if unhealthy
  if not monitor.health.is_healthy then
    M._trigger_recovery(monitor)
  end
end

---Get connection health information
---@param connection_id string Connection identifier
---@return ConnectionHealth? health
function M.get_health(connection_id)
  local monitor = connection_monitors[connection_id]
  return monitor and monitor.health or nil
end

---Get health status for all monitored connections
---@return table<string, ConnectionHealth>
function M.get_all_health()
  local health_status = {}
  for connection_id, monitor in pairs(connection_monitors) do
    health_status[connection_id] = monitor.health
  end
  return health_status
end

---Force reconnection for a connection
---@param connection_id string Connection identifier
function M.force_reconnect(connection_id)
  local monitor = connection_monitors[connection_id]
  if not monitor then
    utils.log(vim.log.levels.ERROR, 'Connection not found for reconnection: ' .. connection_id)
    return
  end

  M._trigger_recovery(monitor)
end

---Start ping timer for a monitor
---@param monitor table Monitor instance
function M._start_ping_timer(monitor)
  monitor.ping_timer = uv.new_timer()

  monitor.ping_timer:start(M.config.ping_interval, M.config.ping_interval, function()
    M._send_ping(monitor)
  end)
end

---Send ping and set up timeout
---@param monitor table Monitor instance
function M._send_ping(monitor)
  local current_time = os.time() * 1000
  monitor.health.last_ping_time = current_time

  -- Set up timeout timer
  monitor.timeout_timer = uv.new_timer()
  monitor.timeout_timer:start(M.config.ping_timeout, 0, function()
    M.record_timeout(monitor.connection_id)
    monitor.timeout_timer:close()
    monitor.timeout_timer = nil
  end)

  -- Send ping through callback
  if monitor.callbacks.send_ping then
    local success = pcall(monitor.callbacks.send_ping, monitor.connection_handle)
    if not success then
      utils.log(
        vim.log.levels.ERROR,
        string.format('Failed to send ping for connection: %s', monitor.connection_id)
      )
      M.record_timeout(monitor.connection_id)
    end
  else
    -- Default ping implementation for WebSocket-like connections
    if monitor.connection_handle and monitor.connection_handle.ping then
      local success = pcall(monitor.connection_handle.ping, monitor.connection_handle)
      if not success then
        M.record_timeout(monitor.connection_id)
      end
    end
  end
end

---Update latency metrics
---@param monitor table Monitor instance
---@param latency number Latency in milliseconds
function M._update_latency_metrics(monitor, latency)
  local samples = monitor.health.latency_samples

  -- Add new sample
  table.insert(samples, latency)

  -- Keep only recent samples
  if #samples > M.config.quality_window_size then
    table.remove(samples, 1)
  end

  -- Calculate average latency
  local total = 0
  for _, sample in ipairs(samples) do
    total = total + sample
  end
  monitor.health.average_latency = total / #samples
end

---Update overall health status and quality score
---@param monitor table Monitor instance
function M._update_health_status(monitor)
  local health = monitor.health

  -- Determine health status
  local was_healthy = health.is_healthy
  health.is_healthy = health.consecutive_failures < M.config.max_missed_pings

  -- Calculate quality score (0-100)
  local failure_penalty = (health.consecutive_failures / M.config.max_missed_pings) * 50
  local latency_penalty = 0

  if health.average_latency > 0 then
    latency_penalty = math.min((health.average_latency / M.config.latency_threshold) * 30, 30)
  end

  health.quality_score = math.max(0, 100 - failure_penalty - latency_penalty)

  -- Emit health change events
  if was_healthy and not health.is_healthy then
    events.emit(events.CONNECTION_UNHEALTHY, {
      connection_id = monitor.connection_id,
      health = health,
    })
  elseif not was_healthy and health.is_healthy then
    events.emit(events.CONNECTION_HEALTHY, {
      connection_id = monitor.connection_id,
      health = health,
    })
  end
end

---Trigger recovery mechanism
---@param monitor table Monitor instance
function M._trigger_recovery(monitor)
  local current_time = os.time() * 1000

  -- Check if we should attempt reconnection
  if monitor.health.reconnect_attempts >= M.config.max_reconnect_attempts then
    utils.log(
      vim.log.levels.ERROR,
      string.format('Max reconnection attempts reached for: %s', monitor.connection_id)
    )
    return
  end

  -- Calculate backoff delay
  local backoff_delay = math.min(
    M.config.reconnect_interval
      * math.pow(M.config.backoff_multiplier, monitor.health.reconnect_attempts),
    M.config.max_backoff_interval
  )

  -- Check if enough time has passed since last attempt
  if current_time - monitor.health.last_reconnect_time < backoff_delay then
    return
  end

  monitor.health.reconnect_attempts = monitor.health.reconnect_attempts + 1
  monitor.health.last_reconnect_time = current_time

  utils.log(
    vim.log.levels.INFO,
    string.format(
      'Attempting reconnection %d/%d for: %s',
      monitor.health.reconnect_attempts,
      M.config.max_reconnect_attempts,
      monitor.connection_id
    )
  )

  -- Use circuit breaker for reconnection
  local success, result = circuit_breaker.call(reconnect_breaker, function()
    if monitor.callbacks.reconnect then
      return monitor.callbacks.reconnect(monitor.connection_handle)
    end
    return false
  end)

  if success and result then
    -- Reset failure counters on successful reconnection
    monitor.health.consecutive_failures = 0
    monitor.health.reconnect_attempts = 0
    utils.log(
      vim.log.levels.INFO,
      string.format('Successfully reconnected: %s', monitor.connection_id)
    )
  else
    utils.log(
      vim.log.levels.ERROR,
      string.format(
        'Reconnection failed for: %s (%s)',
        monitor.connection_id,
        result or 'Unknown error'
      )
    )
  end
end

---Get monitoring statistics
---@return table stats
function M.get_stats()
  local stats = {
    total_connections = 0,
    healthy_connections = 0,
    unhealthy_connections = 0,
    average_quality = 0,
    total_reconnect_attempts = 0,
  }

  local total_quality = 0

  for _, monitor in pairs(connection_monitors) do
    stats.total_connections = stats.total_connections + 1
    total_quality = total_quality + monitor.health.quality_score
    stats.total_reconnect_attempts = stats.total_reconnect_attempts
      + monitor.health.reconnect_attempts

    if monitor.health.is_healthy then
      stats.healthy_connections = stats.healthy_connections + 1
    else
      stats.unhealthy_connections = stats.unhealthy_connections + 1
    end
  end

  if stats.total_connections > 0 then
    stats.average_quality = total_quality / stats.total_connections
  end

  return stats
end

---Cleanup all monitors
function M.cleanup()
  for connection_id, _ in pairs(connection_monitors) do
    M.stop_monitoring(connection_id)
  end
  connection_monitors = {}
end

return M
