---@class TwitchChatLogger
---Comprehensive logging framework for debugging and monitoring
local M = {}

---@class NotificationConfig
---@field enabled boolean Global notification enable/disable
---@field levels table<string, boolean> Which levels trigger notifications
---@field categories table<string, boolean> Context-based notification rules
---@field rate_limit table Rate limiting configuration
---@field fallback_to_console boolean Fallback to console when notifications disabled

---@class RateLimitConfig
---@field enabled boolean Enable rate limiting for notifications
---@field max_per_second number Maximum notifications per second
---@field burst_allowance number Burst allowance for rapid notifications
---@field window_size number Time window for rate limiting (milliseconds)

---@class LoggerConfig
---@field enabled boolean Enable logging system
---@field level string|number Minimum log level ('DEBUG', 'INFO', 'WARN', 'ERROR' or vim.log.levels)
---@field file_logging boolean Enable file logging
---@field console_logging boolean Enable console/notify logging
---@field file_path string? Path to log file
---@field max_file_size number Maximum log file size in bytes
---@field max_files number Maximum number of rotated log files
---@field buffer_size number Number of log entries to buffer before flush
---@field auto_flush_interval number Auto-flush interval in milliseconds
---@field structured_logging boolean Enable structured logging with JSON
---@field performance_logging boolean Enable performance timing logs
---@field context_capture boolean Capture call stack context
---@field module_filters table<string, boolean> Per-module logging filters
---@field notify NotificationConfig Notification configuration

---@class LogEntry
---@field timestamp number Unix timestamp
---@field level string Log level name
---@field level_num number Log level number
---@field message string Log message
---@field module string? Source module name
---@field function_name string? Source function name
---@field line_number number? Source line number
---@field context table? Additional context data
---@field performance_data table? Performance timing data
---@field correlation_id string? Request/operation correlation ID
---@field session_id string Session identifier

---@class PerformanceTimer
---@field name string Timer name
---@field start_time number Start time in nanoseconds
---@field end_time number? End time in nanoseconds
---@field duration number? Duration in milliseconds
---@field metadata table? Additional timer metadata

local uv = vim.uv or vim.loop
local utils = require('twitch-chat.utils')

-- Log levels
local LOG_LEVELS = {
  DEBUG = vim.log.levels.DEBUG,
  INFO = vim.log.levels.INFO,
  WARN = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

local LEVEL_NAMES = {
  [vim.log.levels.DEBUG] = 'DEBUG',
  [vim.log.levels.INFO] = 'INFO',
  [vim.log.levels.WARN] = 'WARN',
  [vim.log.levels.ERROR] = 'ERROR',
}

---@type LoggerConfig
local default_config = {
  enabled = true,
  level = vim.log.levels.INFO,
  file_logging = true,
  console_logging = true,
  file_path = vim.fn.stdpath('cache') .. '/twitch-chat/debug.log',
  max_file_size = 10 * 1024 * 1024, -- 10MB
  max_files = 5,
  buffer_size = 100,
  auto_flush_interval = 5000, -- 5 seconds
  structured_logging = true,
  performance_logging = true,
  context_capture = true,
  module_filters = {},
  notify = {
    enabled = true,
    levels = {
      DEBUG = false,
      INFO = false, -- Only show INFO for user-facing actions
      WARN = true, -- Show important warnings
      ERROR = true, -- Always show errors
    },
    categories = {
      user_action = true, -- User-initiated commands/actions
      system_status = true, -- Connection, auth, plugin status
      background_operation = false, -- Internal operations, API calls
      debug_info = false, -- Debug/development info
      performance = false, -- Performance metrics
    },
    rate_limit = {
      enabled = true,
      max_per_second = 3, -- Prevent notification spam
      burst_allowance = 5, -- Allow short bursts
      window_size = 1000, -- 1 second window
    },
    fallback_to_console = false, -- Don't spam console when notifications disabled
  },
}

-- Internal state
local log_buffer = {}
local flush_timer = nil
local session_id = nil
local active_timers = {}
local correlation_counter = 0

-- Notification rate limiting state
local notification_timestamps = {}
local last_notification_cleanup = 0

---Initialize the logger
---@param config LoggerConfig? Logger configuration
---@return boolean success
function M.setup(config)
  if config then
    default_config = utils.deep_merge(default_config, config)
  end

  -- Generate session ID
  session_id = M._generate_session_id()

  -- Ensure log directory exists
  if default_config.file_logging then
    M._ensure_log_directory()
  end

  -- Start auto-flush timer
  if default_config.auto_flush_interval > 0 then
    M._start_flush_timer()
  end

  -- Setup error handling
  M._setup_error_handling()

  -- Log initialization
  M.info('Logger initialized', {
    session_id = session_id,
    config = {
      level = LEVEL_NAMES[default_config.level] or default_config.level,
      file_logging = default_config.file_logging,
      file_path = default_config.file_path,
    },
  })

  return true
end

---Log a message with specified level
---@param level number|string Log level
---@param message string Log message
---@param context table? Additional context
---@param opts table? Logging options { notify = boolean, category = string, priority = string, correlation_id = string, performance_data = table }
function M.log(level, message, context, opts)
  if not default_config.enabled then
    return
  end

  -- Normalize level
  local level_num = type(level) == 'string' and LOG_LEVELS[level:upper()] or level
  if not level_num or level_num < default_config.level then
    return
  end

  opts = opts or {}

  -- Capture call context
  local call_info = {}
  if default_config.context_capture then
    call_info = M._capture_call_context()
  end

  -- Create log entry
  local entry = {
    timestamp = os.time(),
    level = LEVEL_NAMES[level_num] or 'UNKNOWN',
    level_num = level_num,
    message = message,
    module = call_info.module or opts.module,
    function_name = call_info.function_name,
    line_number = call_info.line_number,
    context = context,
    correlation_id = opts.correlation_id or M._get_current_correlation_id(),
    session_id = session_id,
  }

  -- Add performance data if available
  if opts.performance_data then
    entry.performance_data = opts.performance_data
  end

  -- Check module filters
  if entry.module and default_config.module_filters[entry.module] == false then
    return
  end

  -- Add to buffer
  table.insert(log_buffer, entry)

  -- Notification handling
  if default_config.console_logging then
    local should_notify = M._should_notify(entry, opts)
    if should_notify then
      M._send_notification(entry, opts)
    elseif default_config.notify.fallback_to_console then
      M._console_log(entry)
    end
  end

  -- Flush if buffer is full
  if #log_buffer >= default_config.buffer_size then
    M.flush()
  end
end

---Log debug message
---@param message string Log message
---@param context table? Additional context
---@param opts table? Logging options
function M.debug(message, context, opts)
  M.log(vim.log.levels.DEBUG, message, context, opts)
end

---Log info message
---@param message string Log message
---@param context table? Additional context
---@param opts table? Logging options
function M.info(message, context, opts)
  M.log(vim.log.levels.INFO, message, context, opts)
end

---Log warning message
---@param message string Log message
---@param context table? Additional context
---@param opts table? Logging options
function M.warn(message, context, opts)
  M.log(vim.log.levels.WARN, message, context, opts)
end

---Log error message
---@param message string Log message
---@param context table? Additional context
---@param opts table? Logging options
function M.error(message, context, opts)
  M.log(vim.log.levels.ERROR, message, context, opts)
end

---Start a performance timer
---@param name string Timer name
---@param metadata table? Additional timer metadata
---@return string timer_id
function M.start_timer(name, metadata)
  if not default_config.performance_logging then
    return ''
  end

  local timer_id = string.format('%s_%d_%d', name, os.time(), math.random(1000, 9999))

  active_timers[timer_id] = {
    name = name,
    start_time = uv.hrtime(),
    metadata = metadata or {},
  }

  M.debug('Timer started', {
    timer_id = timer_id,
    name = name,
    metadata = metadata,
  })

  return timer_id
end

---End a performance timer
---@param timer_id string Timer ID returned by start_timer
---@param additional_context table? Additional context for the timing log
---@return number? duration Duration in milliseconds
function M.end_timer(timer_id, additional_context)
  if not default_config.performance_logging or not timer_id then
    return nil
  end

  local timer = active_timers[timer_id]
  if not timer then
    M.warn('Timer not found', { timer_id = timer_id })
    return nil
  end

  local end_time = uv.hrtime()
  local duration = (end_time - timer.start_time) / 1000000 -- Convert to milliseconds

  timer.end_time = end_time
  timer.duration = duration

  -- Log performance data
  local perf_context = utils.deep_merge(timer.metadata, additional_context or {})
  perf_context.duration_ms = duration
  perf_context.timer_name = timer.name

  M.debug('Timer completed', perf_context, {
    performance_data = {
      timer_id = timer_id,
      name = timer.name,
      duration_ms = duration,
      start_time = timer.start_time,
      end_time = end_time,
    },
  })

  -- Clean up
  active_timers[timer_id] = nil

  return duration
end

---Time a function execution
---@param name string Timer name
---@param func function Function to time
---@param ... any Function arguments
---@return any ... Function return values
function M.time_function(name, func, ...)
  local timer_id = M.start_timer(name)
  local results = { pcall(func, ...) }
  local success = table.remove(results, 1)

  local duration = M.end_timer(timer_id, {
    success = success,
    error_message = not success and results[1] or nil,
  })

  if not success then
    M.error('Timed function failed', {
      function_name = name,
      duration_ms = duration,
      error = results[1],
    })
    error(results[1])
  end

  return unpack(results)
end

---Create a correlation ID for request/operation tracking
---@param prefix string? Optional prefix for the correlation ID
---@return string correlation_id
function M.create_correlation_id(prefix)
  correlation_counter = correlation_counter + 1
  local timestamp = os.time()
  local id = string.format('%s_%d_%d', prefix or 'op', timestamp, correlation_counter)
  return id
end

---Set current correlation ID for subsequent logs
---@param correlation_id string? Correlation ID (nil to clear)
function M.set_correlation_id(correlation_id)
  vim.g.twitch_chat_correlation_id = correlation_id
end

---Get current correlation ID
---@return string? correlation_id
function M._get_current_correlation_id()
  return vim.g.twitch_chat_correlation_id
end

---Log structured data for debugging
---@param event_name string Event name
---@param data table Event data
---@param level number? Log level (default: INFO)
function M.log_event(event_name, data, level)
  level = level or vim.log.levels.INFO

  M.log(level, string.format('Event: %s', event_name), {
    event_name = event_name,
    event_data = data,
    event_timestamp = os.time(),
  })
end

---Log API call information
---@param method string HTTP method
---@param url string Request URL
---@param status_code number? Response status code
---@param duration number? Request duration in milliseconds
---@param context table? Additional context
function M.log_api_call(method, url, status_code, duration, context)
  local message = string.format('%s %s', method, url)
  if status_code then
    message = message .. string.format(' -> %d', status_code)
  end

  local log_context = {
    api_method = method,
    api_url = url,
    status_code = status_code,
    duration_ms = duration,
  }

  if context then
    log_context = utils.deep_merge(log_context, context)
  end

  local log_level = vim.log.levels.INFO
  if status_code and status_code >= 400 then
    log_level = vim.log.levels.ERROR
  elseif status_code and status_code >= 300 then
    log_level = vim.log.levels.WARN
  end

  M.log(log_level, message, log_context)
end

---Flush log buffer to file
function M.flush()
  if not default_config.file_logging or #log_buffer == 0 then
    return
  end

  local log_file = default_config.file_path
  if not log_file then
    return
  end

  -- Check for log rotation
  M._rotate_logs_if_needed()

  -- Prepare log entries
  local entries = {}
  for _, entry in ipairs(log_buffer) do
    if default_config.structured_logging then
      table.insert(entries, vim.json.encode(entry))
    else
      table.insert(entries, M._format_plain_log(entry))
    end
  end

  -- Write to file
  local success = pcall(function()
    local file = io.open(log_file, 'a')
    if file then
      for _, line in ipairs(entries) do
        file:write(line .. '\n')
      end
      file:close()
    end
  end)

  if not success then
    vim.notify('Failed to write to log file: ' .. log_file, vim.log.levels.ERROR)
  end

  -- Clear buffer
  log_buffer = {}
end

---Set log level
---@param level string|number New log level
function M.set_level(level)
  local level_num = type(level) == 'string' and LOG_LEVELS[level:upper()] or level
  if level_num then
    default_config.level = level_num
    M.info('Log level changed', { new_level = LEVEL_NAMES[level_num] })
  end
end

---Enable/disable module logging
---@param module_name string Module name
---@param enabled boolean Enable/disable logging for this module
function M.set_module_filter(module_name, enabled)
  default_config.module_filters[module_name] = enabled
  M.info('Module filter updated', {
    module = module_name,
    enabled = enabled,
  })
end

---Configure notification settings
---@param config table Notification configuration
function M.configure_notifications(config)
  if config.enabled ~= nil then
    default_config.notify.enabled = config.enabled
  end

  if config.levels then
    default_config.notify.levels =
      vim.tbl_extend('force', default_config.notify.levels, config.levels)
  end

  if config.categories then
    default_config.notify.categories =
      vim.tbl_extend('force', default_config.notify.categories, config.categories)
  end

  if config.rate_limit then
    default_config.notify.rate_limit =
      vim.tbl_extend('force', default_config.notify.rate_limit, config.rate_limit)
  end

  M.info('Notification configuration updated', {
    enabled = default_config.notify.enabled,
    rate_limit_enabled = default_config.notify.rate_limit.enabled,
  })
end

---Get current notification configuration
---@return table config
function M.get_notification_config()
  return vim.deepcopy(default_config.notify)
end

---Get logger statistics
---@return table stats
function M.get_stats()
  return {
    session_id = session_id,
    buffer_size = #log_buffer,
    active_timers = vim.tbl_count(active_timers),
    config = {
      level = LEVEL_NAMES[default_config.level],
      file_logging = default_config.file_logging,
      file_path = default_config.file_path,
    },
    correlation_counter = correlation_counter,
  }
end

---Cleanup logger resources
function M.cleanup()
  -- Flush remaining logs
  M.flush()

  -- Stop flush timer
  if flush_timer then
    flush_timer:stop()
    flush_timer:close()
    flush_timer = nil
  end

  -- Clear active timers
  active_timers = {}

  M.info('Logger cleanup completed')
end

-- Internal Functions

---Generate unique session ID
---@return string session_id
function M._generate_session_id()
  local timestamp = os.time()
  local random = math.random(10000, 99999)
  return string.format('session_%d_%d', timestamp, random)
end

---Ensure log directory exists
function M._ensure_log_directory()
  local log_dir = vim.fn.fnamemodify(default_config.file_path, ':h')
  if vim.fn.isdirectory(log_dir) == 0 then
    vim.fn.mkdir(log_dir, 'p')
  end
end

---Start auto-flush timer
function M._start_flush_timer()
  flush_timer = uv.new_timer()

  if flush_timer ~= nil then
    flush_timer:start(
      default_config.auto_flush_interval,
      default_config.auto_flush_interval,
      function()
        vim.schedule(function()
          M.flush()
        end)
      end
    )
  end
end

---Capture call context information
---@return table call_info
function M._capture_call_context()
  local info = debug.getinfo(4, 'Sl')
  if not info then
    return {}
  end

  local source = info.source or ''
  local module_name = source:match('lua/twitch%-chat/(.-)%.lua$')
  if module_name then
    module_name = module_name:gsub('/', '.')
  end

  return {
    module = module_name,
    function_name = info.name,
    line_number = info.currentline,
    source = source,
  }
end

---Console logging
---@param entry LogEntry Log entry
function M._console_log(entry)
  local formatted_message = string.format('[%s] %s', entry.level, entry.message)

  if entry.context then
    formatted_message = formatted_message
      .. ' '
      .. vim.inspect(entry.context, { indent = '', depth = 2 })
  end

  vim.notify(formatted_message, entry.level_num, {
    title = 'TwitchChat',
    timeout = entry.level_num >= vim.log.levels.WARN and 5000 or 3000,
  })
end

---Format plain text log entry
---@param entry LogEntry Log entry
---@return string formatted_log
function M._format_plain_log(entry)
  local timestamp = os.date('%Y-%m-%d %H:%M:%S', entry.timestamp)
  local parts = {
    timestamp,
    string.format('[%s]', entry.level),
  }

  if entry.module then
    table.insert(parts, string.format('[%s]', entry.module))
  end

  if entry.correlation_id then
    table.insert(parts, string.format('[%s]', entry.correlation_id))
  end

  table.insert(parts, entry.message)

  local formatted = table.concat(parts, ' ')

  if entry.context then
    formatted = formatted .. ' | ' .. vim.inspect(entry.context, { indent = '', depth = 1 })
  end

  return formatted
end

---Rotate logs if needed
function M._rotate_logs_if_needed()
  local log_file = default_config.file_path
  if not log_file or vim.fn.filereadable(log_file) == 0 then
    return
  end

  local file_size = vim.fn.getfsize(log_file)
  if file_size < default_config.max_file_size then
    return
  end

  -- Rotate existing files
  for i = default_config.max_files - 1, 1, -1 do
    local old_file = log_file .. '.' .. i
    local new_file = log_file .. '.' .. (i + 1)

    if vim.fn.filereadable(old_file) == 1 then
      os.rename(old_file, new_file)
    end
  end

  -- Move current log to .1
  os.rename(log_file, log_file .. '.1')
end

-- Notification Functions

---Check if a log entry should trigger a notification
---@param entry LogEntry Log entry
---@param opts table? Logging options
---@return boolean should_notify
function M._should_notify(entry, opts)
  opts = opts or {}

  -- Check if notifications are globally enabled
  if not default_config.notify.enabled then
    return false
  end

  -- Check explicit notify option
  if opts.notify ~= nil then
    return opts.notify
  end

  -- Check level-based rules
  local level_name = entry.level
  if default_config.notify.levels[level_name] ~= nil then
    if not default_config.notify.levels[level_name] then
      return false
    end
  end

  -- Check category-based rules
  local category = opts.category
  if category and default_config.notify.categories[category] ~= nil then
    if not default_config.notify.categories[category] then
      return false
    end
  end

  -- Check rate limiting
  if default_config.notify.rate_limit.enabled then
    return M._check_rate_limit()
  end

  return true
end

---Check notification rate limiting
---@return boolean allowed
function M._check_rate_limit()
  local now = uv.hrtime() / 1000000 -- Convert to milliseconds
  local window_size = default_config.notify.rate_limit.window_size
  local max_per_second = default_config.notify.rate_limit.max_per_second
  local burst_allowance = default_config.notify.rate_limit.burst_allowance

  -- Clean up old timestamps periodically
  if now - last_notification_cleanup > window_size then
    M._cleanup_notification_timestamps(now, window_size)
    last_notification_cleanup = now
  end

  -- Count recent notifications
  local recent_count = 0
  local cutoff_time = now - window_size

  for _, timestamp in ipairs(notification_timestamps) do
    if timestamp >= cutoff_time then
      recent_count = recent_count + 1
    end
  end

  -- Check against limits
  local per_second_limit = max_per_second * (window_size / 1000)
  if recent_count < per_second_limit or recent_count < burst_allowance then
    table.insert(notification_timestamps, now)
    return true
  end

  return false
end

---Clean up old notification timestamps
---@param now number Current time in milliseconds
---@param window_size number Window size in milliseconds
function M._cleanup_notification_timestamps(now, window_size)
  local cutoff_time = now - window_size
  local new_timestamps = {}

  for _, timestamp in ipairs(notification_timestamps) do
    if timestamp >= cutoff_time then
      table.insert(new_timestamps, timestamp)
    end
  end

  notification_timestamps = new_timestamps
end

---Send a notification
---@param entry LogEntry Log entry
---@param opts table? Logging options
function M._send_notification(entry, opts)
  opts = opts or {}

  -- Format notification message
  local message = entry.message
  if entry.context and opts.include_context ~= false then
    -- For notifications, keep context brief
    local context_summary = M._summarize_context(entry.context)
    if context_summary then
      message = message .. ' (' .. context_summary .. ')'
    end
  end

  -- Determine notification options
  local notify_opts = {
    title = 'TwitchChat',
    timeout = M._get_notification_timeout(entry.level_num, opts.priority),
  }

  -- Add any custom notification options
  if opts.notify_opts then
    notify_opts = vim.tbl_extend('force', notify_opts, opts.notify_opts)
  end

  -- Send the notification
  vim.notify(message, entry.level_num, notify_opts)
end

---Summarize context for notifications
---@param context table? Context data
---@return string? summary
function M._summarize_context(context)
  if not context or type(context) ~= 'table' then
    return nil
  end

  -- Extract key fields for brief summary
  local parts = {}

  if context.channel then
    table.insert(parts, 'channel: ' .. context.channel)
  end

  if context.module then
    table.insert(parts, 'module: ' .. context.module)
  end

  if context.error and type(context.error) == 'string' then
    -- Truncate long error messages
    local error_msg = context.error
    if #error_msg > 50 then
      error_msg = string.sub(error_msg, 1, 50) .. '...'
    end
    table.insert(parts, 'error: ' .. error_msg)
  end

  if #parts == 0 then
    return nil
  end

  return table.concat(parts, ', ')
end

---Get notification timeout based on level and priority
---@param level_num number Log level number
---@param priority string? Priority hint
---@return number timeout
function M._get_notification_timeout(level_num, priority)
  if priority == 'high' then
    return 8000
  elseif priority == 'low' then
    return 2000
  end

  -- Default timeouts based on level
  if level_num >= vim.log.levels.ERROR then
    return 6000
  elseif level_num >= vim.log.levels.WARN then
    return 4000
  else
    return 3000
  end
end

---Setup error handling
function M._setup_error_handling()
  -- Capture Lua errors

  vim.api.nvim_create_autocmd('User', {
    pattern = 'TwitchChatError',
    callback = function(args)
      if args.data then
        M.error('Plugin error captured', {
          error_message = args.data.message,
          error_source = args.data.source,
          stack_trace = args.data.traceback,
        })
      end
    end,
  })
end

return M
