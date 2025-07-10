-- Circuit Breaker Pattern Implementation for Network Operations
-- Prevents cascading failures by temporarily disabling failing services

local M = {}

---@class CircuitBreakerConfig
---@field failure_threshold number Maximum failures before opening circuit
---@field recovery_timeout number Time before attempting recovery (ms)
---@field success_threshold number Successes needed to close circuit
---@field timeout number Operation timeout (ms)

---@class CircuitBreaker
---@field state string Current state: 'CLOSED', 'OPEN', 'HALF_OPEN'
---@field failure_count number Current failure count
---@field success_count number Current success count in HALF_OPEN state
---@field last_failure_time number Timestamp of last failure
---@field config CircuitBreakerConfig Configuration
---@field name string Circuit breaker name for logging

-- Circuit breaker states
local STATES = {
  CLOSED = 'CLOSED', -- Normal operation
  OPEN = 'OPEN', -- Failing, rejecting calls
  HALF_OPEN = 'HALF_OPEN', -- Testing if service recovered
}

local utils = require('twitch-chat.utils')

---Create a new circuit breaker
---@param name string Circuit breaker name
---@param config CircuitBreakerConfig? Configuration options
---@return CircuitBreaker
function M.new(name, config)
  config = config or {}

  local default_config = {
    failure_threshold = 5, -- Open after 5 failures
    recovery_timeout = 60000, -- Wait 60s before trying again
    success_threshold = 3, -- Need 3 successes to close
    timeout = 10000, -- 10s operation timeout
  }

  return {
    name = name,
    state = STATES.CLOSED,
    failure_count = 0,
    success_count = 0,
    last_failure_time = 0,
    config = vim.tbl_deep_extend('force', default_config, config),
  }
end

---Execute a function with circuit breaker protection
---@param circuit CircuitBreaker Circuit breaker instance
---@param fn function Function to execute
---@param ... any Arguments to pass to function
---@return boolean success, any result_or_error
function M.call(circuit, fn, ...)
  -- Check if circuit should transition states
  M._update_state(circuit)

  -- If circuit is open, reject the call
  if circuit.state == STATES.OPEN then
    local time_since_failure = os.time() * 1000 - circuit.last_failure_time
    if time_since_failure < circuit.config.recovery_timeout then
      utils.log(
        vim.log.levels.DEBUG,
        string.format('Circuit breaker [%s] is OPEN, rejecting call', circuit.name)
      )
      return false, 'Circuit breaker is OPEN'
    else
      -- Transition to half-open to test recovery
      circuit.state = STATES.HALF_OPEN
      circuit.success_count = 0
      utils.log(
        vim.log.levels.INFO,
        string.format('Circuit breaker [%s] transitioning to HALF_OPEN', circuit.name)
      )
    end
  end

  -- Execute the function with timeout
  local success, result = M._execute_with_timeout(circuit, fn, ...)

  -- Update circuit state based on result
  if success then
    M._record_success(circuit)
  else
    M._record_failure(circuit)
  end

  return success, result
end

---Execute function with timeout protection
---@param circuit CircuitBreaker Circuit breaker instance
---@param fn function Function to execute
---@param ... any Function arguments
---@return boolean success, any result_or_error
function M._execute_with_timeout(circuit, fn, ...)
  local logger = require('twitch-chat.modules.logger')
  local timer_id = logger.start_timer('circuit_breaker_operation', {
    circuit_name = circuit.name,
    circuit_state = circuit.state,
  })

  local start_time = vim.loop.hrtime()
  local timeout_ns = circuit.config.timeout * 1000000

  local success, result = pcall(fn, ...)

  local execution_time = vim.loop.hrtime() - start_time
  local execution_time_ms = execution_time / 1000000

  if execution_time > timeout_ns then
    logger.warn('Circuit breaker operation timeout', {
      circuit_name = circuit.name,
      timeout_ms = circuit.config.timeout,
      actual_duration_ms = execution_time_ms,
    })
    logger.end_timer(timer_id, {
      success = false,
      reason = 'timeout',
      duration_ms = execution_time_ms,
    })
    return false, 'Operation timeout'
  end

  logger.debug('Circuit breaker operation completed', {
    circuit_name = circuit.name,
    success = success,
    duration_ms = execution_time_ms,
  })

  logger.end_timer(timer_id, {
    success = success,
    duration_ms = execution_time_ms,
  })

  return success, result
end

---Record a successful operation
---@param circuit CircuitBreaker Circuit breaker instance
function M._record_success(circuit)
  circuit.failure_count = 0

  if circuit.state == STATES.HALF_OPEN then
    circuit.success_count = circuit.success_count + 1

    if circuit.success_count >= circuit.config.success_threshold then
      circuit.state = STATES.CLOSED
      circuit.success_count = 0
      utils.log(
        vim.log.levels.INFO,
        string.format(
          'Circuit breaker [%s] CLOSED after %d successes',
          circuit.name,
          circuit.config.success_threshold
        )
      )
    end
  end
end

---Record a failed operation
---@param circuit CircuitBreaker Circuit breaker instance
function M._record_failure(circuit)
  circuit.failure_count = circuit.failure_count + 1
  circuit.last_failure_time = os.time() * 1000

  if
    circuit.state == STATES.CLOSED
    and circuit.failure_count >= circuit.config.failure_threshold
  then
    circuit.state = STATES.OPEN
    utils.log(
      vim.log.levels.WARN,
      string.format(
        'Circuit breaker [%s] OPENED after %d failures',
        circuit.name,
        circuit.failure_count
      )
    )
  elseif circuit.state == STATES.HALF_OPEN then
    -- Any failure in half-open state reopens the circuit
    circuit.state = STATES.OPEN
    circuit.success_count = 0
    utils.log(
      vim.log.levels.WARN,
      string.format('Circuit breaker [%s] REOPENED after failure in HALF_OPEN state', circuit.name)
    )
  end
end

---Update circuit state based on time and conditions
---@param circuit CircuitBreaker Circuit breaker instance
function M._update_state(circuit)
  if circuit.state == STATES.OPEN then
    local time_since_failure = os.time() * 1000 - circuit.last_failure_time
    if time_since_failure >= circuit.config.recovery_timeout then
      circuit.state = STATES.HALF_OPEN
      circuit.success_count = 0
      utils.log(
        vim.log.levels.INFO,
        string.format(
          'Circuit breaker [%s] transitioning to HALF_OPEN for recovery test',
          circuit.name
        )
      )
    end
  end
end

---Get circuit breaker statistics
---@param circuit CircuitBreaker Circuit breaker instance
---@return table stats
function M.get_stats(circuit)
  return {
    name = circuit.name,
    state = circuit.state,
    failure_count = circuit.failure_count,
    success_count = circuit.success_count,
    last_failure_time = circuit.last_failure_time,
    config = circuit.config,
  }
end

---Reset circuit breaker to initial state
---@param circuit CircuitBreaker Circuit breaker instance
function M.reset(circuit)
  circuit.state = STATES.CLOSED
  circuit.failure_count = 0
  circuit.success_count = 0
  circuit.last_failure_time = 0

  utils.log(vim.log.levels.INFO, string.format('Circuit breaker [%s] manually reset', circuit.name))
end

---Check if circuit breaker is healthy
---@param circuit CircuitBreaker Circuit breaker instance
---@return boolean is_healthy
function M.is_healthy(circuit)
  return circuit.state == STATES.CLOSED or circuit.state == STATES.HALF_OPEN
end

-- Circuit breaker registry for managing multiple breakers
local circuit_registry = {}

---Get or create a named circuit breaker
---@param name string Circuit breaker name
---@param config CircuitBreakerConfig? Configuration
---@return CircuitBreaker
function M.get_or_create(name, config)
  if not circuit_registry[name] then
    circuit_registry[name] = M.new(name, config)
  end
  return circuit_registry[name]
end

---Get all registered circuit breakers
---@return table<string, CircuitBreaker>
function M.get_all()
  return circuit_registry
end

---Get statistics for all circuit breakers
---@return table<string, table>
function M.get_all_stats()
  local stats = {}
  for name, circuit in pairs(circuit_registry) do
    stats[name] = M.get_stats(circuit)
  end
  return stats
end

---Reset all circuit breakers
function M.reset_all()
  for name, circuit in pairs(circuit_registry) do
    M.reset(circuit)
  end
end

return M
