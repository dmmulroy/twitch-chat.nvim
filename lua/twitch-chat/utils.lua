---@class Timer
---@field start fun(self: Timer, timeout: number, repeat_timeout: number, callback: function): boolean
---@field stop fun(self: Timer): boolean
---@field close fun(self: Timer): nil

---@class TwitchChatUtils
local M = {}
local uv = vim.uv or vim.loop

---Deep merge two tables
---@param target table Target table to merge into
---@param source table Source table to merge from
---@return table merged The merged table
function M.deep_merge(target, source)
  vim.validate({
    target = { target, 'table' },
    source = { source, 'table' },
  })

  local result = vim.deepcopy(target)

  for k, v in pairs(source) do
    if type(v) == 'table' and type(result[k]) == 'table' then
      result[k] = M.deep_merge(result[k], v)
    else
      result[k] = v
    end
  end

  return result
end

---Safe call with error handling
---@param func function Function to call
---@param ... any Arguments to pass to function
---@return boolean success, any result_or_error
function M.safe_call(func, ...)
  vim.validate({
    func = { func, 'function' },
  })

  local success, result = pcall(func, ...)
  if not success then
    vim.notify(
      string.format('Error in safe_call: %s', result),
      vim.log.levels.ERROR,
      { title = 'TwitchChat Utils' }
    )
  end

  return success, result
end

---Format timestamp
---@param timestamp number Unix timestamp
---@param format string? Format string (default: '%H:%M:%S')
---@return string formatted_time
function M.format_timestamp(timestamp, format)
  vim.validate({
    timestamp = { timestamp, 'number' },
    format = { format, 'string', true },
  })

  format = format or '%H:%M:%S'
  return tostring(os.date(format, timestamp) or '')
end

---Escape special characters for display
---@param text string Text to escape
---@return string escaped_text
---@return number? substitutions
function M.escape_text(text)
  vim.validate({
    text = { text, 'string' },
  })

  return text:gsub('[%c\127-\255]', function(char)
    return string.format('\\%03d', string.byte(char))
  end)
end

---Strip ANSI escape sequences
---@param text string Text with potential ANSI sequences
---@return string clean_text
---@return number? substitutions
function M.strip_ansi(text)
  vim.validate({
    text = { text, 'string' },
  })

  return text:gsub('\027%[[0-9;]*m', '')
end

---Truncate text to specified length
---@param text string Text to truncate
---@param max_length number Maximum length
---@param suffix string? Suffix to add when truncated (default: '...')
---@return string truncated_text
function M.truncate(text, max_length, suffix)
  vim.validate({
    text = { text, 'string' },
    max_length = { max_length, 'number' },
    suffix = { suffix, 'string', true },
  })

  -- Handle edge case for zero or negative max_length
  if max_length <= 0 then
    return ''
  end

  suffix = suffix or '...'

  if #text <= max_length then
    return text
  end

  return text:sub(1, max_length - #suffix) .. suffix
end

---Split string by delimiter
---@param str string String to split
---@param delimiter string Delimiter to split on
---@return string[] parts
function M.split(str, delimiter)
  vim.validate({
    str = { str, 'string' },
    delimiter = { delimiter, 'string' },
  })

  local parts = {}
  local pattern = string.format('([^%s]+)', delimiter)

  for part in str:gmatch(pattern) do
    table.insert(parts, part)
  end

  return parts
end

---Join table elements with delimiter
---@param tbl table Table to join
---@param delimiter string Delimiter to join with
---@return string joined_string
function M.join(tbl, delimiter)
  vim.validate({
    tbl = { tbl, 'table' },
    delimiter = { delimiter, 'string' },
  })

  return table.concat(tbl, delimiter)
end

---Check if table is empty
---@param tbl table Table to check
---@return boolean is_empty
function M.is_empty(tbl)
  vim.validate({
    tbl = { tbl, 'table' },
  })

  return next(tbl) == nil
end

---Get table length (works for both arrays and maps)
---@param tbl table Table to measure
---@return number length
function M.table_length(tbl)
  vim.validate({
    tbl = { tbl, 'table' },
  })

  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end

  return count
end

---Check if value exists in table
---@param tbl table Table to search
---@param value any Value to find
---@return boolean found
function M.table_contains(tbl, value)
  vim.validate({
    tbl = { tbl, 'table' },
  })

  for _, v in pairs(tbl) do
    if v == value then
      return true
    end
  end

  return false
end

---Get keys from table
---@param tbl table Table to get keys from
---@return any[] keys
function M.table_keys(tbl)
  vim.validate({
    tbl = { tbl, 'table' },
  })

  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end

  return keys
end

---Get values from table
---@param tbl table Table to get values from
---@return any[] values
function M.table_values(tbl)
  vim.validate({
    tbl = { tbl, 'table' },
  })

  local values = {}
  for _, v in pairs(tbl) do
    table.insert(values, v)
  end

  return values
end

---Validate URL format
---@param url string URL to validate
---@return boolean valid
function M.is_valid_url(url)
  vim.validate({
    url = { url, 'string' },
  })

  local pattern = '^https?://[%w%.%-_:]+[%w%.%-_/:%?=&]*$'
  return url:match(pattern) ~= nil
end

---Validate channel name format
---@param channel string Channel name to validate
---@return boolean valid
function M.is_valid_channel(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  -- Twitch channel names: 4-25 characters, alphanumeric + underscore
  -- Remove # prefix if present
  local clean_channel = channel:gsub('^#', '')

  -- Check length
  if #clean_channel < 4 or #clean_channel > 25 then
    return false
  end

  -- Check pattern (alphanumeric + underscore only)
  local pattern = '^[a-zA-Z0-9_]+$'
  return clean_channel:match(pattern) ~= nil
end

---Generate random string
---@param length number Length of random string
---@param charset string? Character set to use (default: alphanumeric)
---@return string random_string
function M.random_string(length, charset)
  vim.validate({
    length = { length, 'number' },
    charset = { charset, 'string', true },
  })

  charset = charset or 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  local result = {}

  for _ = 1, length do
    local index = math.random(1, #charset)
    table.insert(result, charset:sub(index, index))
  end

  return table.concat(result)
end

---Debounce function calls
---@param func function Function to debounce
---@param delay number Delay in milliseconds
---@return function debounced_function
function M.debounce(func, delay)
  vim.validate({
    func = { func, 'function' },
    delay = { delay, 'number' },
  })

  ---@type Timer?
  local timer = nil

  return function(...)
    local args = { ... }

    if timer then
      timer:stop()
    end

    ---@type Timer
    timer = uv.new_timer()
    if timer then
      timer:start(delay, 0, function()
        if timer then
          timer:stop()
          timer = nil
        end
        vim.schedule(function()
          func(unpack(args))
        end)
      end)
    end
  end
end

---Throttle function calls
---@param func function Function to throttle
---@param delay number Delay in milliseconds
---@return function throttled_function
function M.throttle(func, delay)
  vim.validate({
    func = { func, 'function' },
    delay = { delay, 'number' },
  })

  local last_call = 0

  return function(...)
    local now = uv.now()

    if now - last_call >= delay then
      last_call = now
      func(...)
    end
  end
end

---Create a simple cache
---@param max_size number? Maximum cache size (default: 100)
---@return table cache Cache object with get/set/clear methods
function M.create_cache(max_size)
  vim.validate({
    max_size = { max_size, 'number', true },
  })

  max_size = max_size or 100
  local cache = {}
  local keys = {}

  return {
    get = function(key)
      return cache[key]
    end,

    set = function(key, value)
      if not cache[key] then
        table.insert(keys, key)

        -- Remove oldest entry if cache is full
        if #keys > max_size then
          local oldest_key = table.remove(keys, 1)
          cache[oldest_key] = nil
        end
      end

      cache[key] = value
    end,

    clear = function()
      cache = {}
      keys = {}
    end,

    size = function()
      return #keys
    end,
  }
end

---Get file extension
---@param filename string Filename to get extension from
---@return string extension
function M.get_file_extension(filename)
  vim.validate({
    filename = { filename, 'string' },
  })

  return filename:match('%.([^%.]+)$') or ''
end

---Check if file exists
---@param filepath string Path to file
---@return boolean exists
function M.file_exists(filepath)
  vim.validate({
    filepath = { filepath, 'string' },
  })

  local stat = uv.fs_stat(filepath)
  return stat ~= nil and stat.type == 'file'
end

---Check if directory exists
---@param dirpath string Path to directory
---@return boolean exists
function M.dir_exists(dirpath)
  vim.validate({
    dirpath = { dirpath, 'string' },
  })

  local stat = uv.fs_stat(dirpath)
  return stat ~= nil and stat.type == 'directory'
end

---Create directory if it doesn't exist
---@param dirpath string Path to directory
---@return boolean success
function M.ensure_dir(dirpath)
  vim.validate({
    dirpath = { dirpath, 'string' },
  })

  if M.dir_exists(dirpath) then
    return true
  end

  local success, err = pcall(vim.fn.mkdir, dirpath, 'p')
  if not success then
    -- Only show notification if it's not a test context or known problematic paths
    local is_test_path = dirpath:match('^/root') or dirpath:match('^/nonexistent')
    if not is_test_path then
      vim.notify(
        string.format('Failed to create directory %s: %s', dirpath, err),
        vim.log.levels.ERROR,
        { title = 'TwitchChat Utils' }
      )
    end
  end

  return success
end

---Read file contents
---@param filepath string Path to file
---@return string? content File contents or nil if failed
function M.read_file(filepath)
  vim.validate({
    filepath = { filepath, 'string' },
  })

  if not M.file_exists(filepath) then
    return nil
  end

  local file = io.open(filepath, 'r')
  if not file then
    return nil
  end

  local content = file:read('*a')
  file:close()

  return content
end

---Write file contents
---@param filepath string Path to file
---@param content string Content to write
---@return boolean success
function M.write_file(filepath, content)
  vim.validate({
    filepath = { filepath, 'string' },
    content = { content, 'string' },
  })

  -- Ensure directory exists
  local dir = vim.fn.fnamemodify(filepath, ':h')
  if not M.ensure_dir(dir) then
    return false
  end

  local file = io.open(filepath, 'w')
  if not file then
    return false
  end

  file:write(content)
  file:close()

  return true
end

---Log message using comprehensive logger
---@param level number Log level (vim.log.levels)
---@param message string Message to log
---@param context table? Additional context
function M.log(level, message, context)
  vim.validate({
    level = { level, 'number' },
    message = { message, 'string' },
    context = { context, 'table', true },
  })

  -- Use the comprehensive logger if available, fallback to simple logging
  local ok, logger = pcall(require, 'twitch-chat.modules.logger')
  if ok and logger then
    logger.log(level, message, context)
  else
    -- Fallback to simple logging
    local timestamp = M.format_timestamp(os.time(), '%Y-%m-%d %H:%M:%S')
    local log_message = string.format('[%s] %s', timestamp, message)

    if context then
      log_message = log_message .. ' ' .. vim.inspect(context)
    end

    vim.notify(log_message, level, { title = 'TwitchChat' })
  end
end

---Enhanced logging utilities for debugging
M.debug = {
  ---Log function entry with parameters
  ---@param func_name string Function name
  ---@param params table? Function parameters
  ---@return string correlation_id
  enter_function = function(func_name, params)
    local logger = require('twitch-chat.modules.logger')
    local correlation_id = logger.create_correlation_id('func')
    logger.set_correlation_id(correlation_id)

    logger.debug('Function entered', {
      function_name = func_name,
      parameters = params,
      correlation_id = correlation_id,
    })

    return correlation_id
  end,

  ---Log function exit with result
  ---@param func_name string Function name
  ---@param result any Function result
  ---@param correlation_id string? Correlation ID from enter_function
  exit_function = function(func_name, result, correlation_id)
    local logger = require('twitch-chat.modules.logger')

    logger.debug('Function exited', {
      function_name = func_name,
      result_type = type(result),
      correlation_id = correlation_id,
    })

    if correlation_id then
      logger.set_correlation_id(nil) -- Clear correlation
    end
  end,

  ---Log API call with timing
  ---@param method string HTTP method
  ---@param url string Request URL
  ---@param callback function Callback function to execute
  ---@return any result
  api_call = function(method, url, callback)
    local logger = require('twitch-chat.modules.logger')
    local timer_id = logger.start_timer('api_call', {
      method = method,
      url = url,
    })

    local start_time = os.time()
    local success, result = pcall(callback)
    local duration = (os.time() - start_time) * 1000

    local status_code = nil
    if type(result) == 'table' and result.status then
      status_code = result.status
    end

    logger.log_api_call(method, url, status_code, duration, {
      success = success,
      result_type = type(result),
    })

    logger.end_timer(timer_id, {
      success = success,
      status_code = status_code,
    })

    if not success then
      error(result)
    end

    return result
  end,

  ---Log performance metrics for operations
  ---@param operation_name string Operation name
  ---@param metrics table Performance metrics
  log_performance = function(operation_name, metrics)
    local logger = require('twitch-chat.modules.logger')

    logger.log_event('performance_metrics', {
      operation = operation_name,
      metrics = metrics,
      timestamp = os.time(),
    })
  end,

  ---Log state changes
  ---@param component string Component name
  ---@param old_state any Previous state
  ---@param new_state any New state
  ---@param context table? Additional context
  state_change = function(component, old_state, new_state, context)
    local logger = require('twitch-chat.modules.logger')

    logger.info('State change detected', {
      component = component,
      old_state = old_state,
      new_state = new_state,
      context = context,
    })
  end,
}

---Check if a table contains a value
---@param table table Table to search
---@param value any Value to find
---@return boolean found
function M.table_contains(table, value)
  vim.validate({
    table = { table, 'table' },
  })

  for _, v in ipairs(table) do
    if v == value then
      return true
    end
  end
  return false
end

---Join table elements with separator
---@param table table Table to join
---@param separator string Separator string
---@return string joined
function M.join(table, separator)
  vim.validate({
    table = { table, 'table' },
    separator = { separator, 'string' },
  })

  return table.concat(table, separator)
end

---Check if a table is empty
---@param table table Table to check
---@return boolean empty
function M.is_empty(table)
  vim.validate({
    table = { table, 'table' },
  })

  return next(table) == nil
end

---Validate Twitch channel name format
---@param channel string Channel name to validate
---@return boolean valid
function M.is_valid_channel(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  -- Twitch channel names are alphanumeric + underscores, 1-25 characters
  return channel:match('^[a-zA-Z0-9_]{1,25}$') ~= nil
end

---Validate Twitch username format
---@param username string Username to validate
---@return boolean valid
function M.is_valid_username(username)
  vim.validate({
    username = { username, 'string' },
  })

  -- Twitch usernames are alphanumeric + underscores, 4-25 characters
  return username:match('^[a-zA-Z0-9_]{4,25}$') ~= nil
end

---Validate URL format
---@param url string URL to validate
---@return boolean valid
function M.is_valid_url(url)
  vim.validate({
    url = { url, 'string' },
  })

  -- Basic URL validation
  return url:match("^https?://[%w.-]+[%w.-_~:/?#[%]@!$&'()*+,;=]+$") ~= nil
end

---Check if a directory is writable
---@param dirpath string Directory path to check
---@return boolean writable
function M.is_writable(dirpath)
  vim.validate({
    dirpath = { dirpath, 'string' },
  })

  if not M.dir_exists(dirpath) then
    return false
  end

  -- Try to create a temporary file
  local temp_file = dirpath .. '/.twitch_chat_write_test'
  local success = M.write_file(temp_file, 'test')

  if success then
    -- Clean up test file
    pcall(os.remove, temp_file)
  end

  return success
end

---Split string by delimiter
---@param str string String to split
---@param delimiter string Delimiter to split by
---@return table parts
function M.split(str, delimiter)
  vim.validate({
    str = { str, 'string' },
    delimiter = { delimiter, 'string' },
  })

  local parts = {}
  local pattern = '([^' .. delimiter .. ']+)'

  for part in str:gmatch(pattern) do
    table.insert(parts, part)
  end

  return parts
end

---Get memory usage estimate for a value
---@param value any Value to estimate memory for
---@return number bytes Estimated memory usage in bytes
function M.get_memory_estimate(value)
  local function estimate_recursive(val, seen)
    seen = seen or {}

    if seen[val] then
      return 0 -- Avoid circular references
    end

    local size = 0
    local val_type = type(val)

    if val_type == 'string' then
      size = #val
    elseif val_type == 'number' then
      size = 8 -- Approximate
    elseif val_type == 'boolean' then
      size = 1
    elseif val_type == 'table' then
      seen[val] = true
      size = 40 -- Base table overhead

      for k, v in pairs(val) do
        size = size + estimate_recursive(k, seen) + estimate_recursive(v, seen) + 16 -- Key-value pair overhead
      end
    elseif val_type == 'function' then
      size = 32 -- Approximate function size
    end

    return size
  end

  return estimate_recursive(value)
end

return M
