---@class TwitchChatFilter
---Message filtering with regex support for Twitch chat
local M = {}
local uv = vim.uv or vim.loop

---@class FilterConfig
---@field enabled boolean
---@field default_mode string -- 'allow', 'block'
---@field rules FilterRulesConfig
---@field performance FilterPerformanceConfig
---@field logging FilterLoggingConfig
---@field persistence FilterPersistenceConfig

---@class FilterRulesConfig
---@field patterns FilterPatternConfig
---@field users FilterUserConfig
---@field content FilterContentConfig
---@field commands FilterCommandConfig
---@field timeouts FilterTimeoutConfig

---@class FilterPatternConfig
---@field enabled boolean
---@field case_sensitive boolean
---@field whole_word boolean
---@field max_patterns number
---@field block_patterns string[]
---@field allow_patterns string[]

---@class FilterUserConfig
---@field enabled boolean
---@field case_sensitive boolean
---@field max_users number
---@field block_users string[]
---@field allow_users string[]
---@field moderator_bypass boolean
---@field vip_bypass boolean
---@field subscriber_bypass boolean

---@class FilterContentConfig
---@field enabled boolean
---@field filter_links boolean
---@field filter_caps boolean
---@field filter_spam boolean
---@field filter_emote_spam boolean
---@field caps_threshold number
---@field spam_threshold number
---@field emote_spam_threshold number

---@class FilterCommandConfig
---@field enabled boolean
---@field filter_bot_commands boolean
---@field filter_user_commands boolean
---@field allowed_commands string[]
---@field blocked_commands string[]

---@class FilterTimeoutConfig
---@field enabled boolean
---@field timeout_duration number -- seconds
---@field max_violations number
---@field reset_interval number -- seconds

---@class FilterPerformanceConfig
---@field cache_compiled_patterns boolean
---@field max_cache_size number
---@field batch_processing boolean
---@field max_batch_size number

---@class FilterLoggingConfig
---@field enabled boolean
---@field log_blocked boolean
---@field log_allowed boolean
---@field log_file string?
---@field max_log_size number

---@class FilterPersistenceConfig
---@field enabled boolean
---@field save_rules boolean
---@field save_stats boolean
---@field rules_file string?
---@field stats_file string?

---@class FilterRule
---@field id string
---@field name string
---@field type string -- 'pattern', 'user', 'content', 'command'
---@field action string -- 'block', 'allow'
---@field pattern string?
---@field user string?
---@field enabled boolean
---@field priority number
---@field created_at number
---@field last_used number
---@field use_count number

---@class FilterMatch
---@field rule_id string
---@field rule_name string
---@field action string
---@field match_text string
---@field match_start number?
---@field match_end number?

---@class FilterResult
---@field allowed boolean
---@field matches FilterMatch[]
---@field reason string?
---@field processing_time number?

---@class FilterStats
---@field total_messages number
---@field blocked_messages number
---@field allowed_messages number
---@field rules_triggered table<string, number>
---@field user_violations table<string, number>
---@field pattern_matches table<string, number>

local utils = require('twitch-chat.utils')
local events = require('twitch-chat.events')

-- Regex sandboxing configuration
local REGEX_TIMEOUT_MS = 100 -- Maximum regex execution time
local PATTERN_COMPLEXITY_LIMIT = 50 -- Maximum pattern complexity score
local MAX_PATTERN_LENGTH = 1000 -- Maximum pattern length

---@type FilterConfig
local default_config = {
  enabled = true,
  default_mode = 'allow', -- 'allow', 'block'
  rules = {
    patterns = {
      enabled = true,
      case_sensitive = false,
      whole_word = false,
      max_patterns = 100,
      block_patterns = {},
      allow_patterns = {},
    },
    users = {
      enabled = true,
      case_sensitive = false,
      max_users = 500,
      block_users = {},
      allow_users = {},
      moderator_bypass = true,
      vip_bypass = true,
      subscriber_bypass = false,
    },
    content = {
      enabled = true,
      filter_links = false,
      filter_caps = false,
      filter_spam = false,
      filter_emote_spam = false,
      caps_threshold = 0.7, -- 70% caps
      spam_threshold = 5, -- repeat message count
      emote_spam_threshold = 10, -- max emotes per message
    },
    commands = {
      enabled = true,
      filter_bot_commands = false,
      filter_user_commands = false,
      allowed_commands = {},
      blocked_commands = {},
    },
    timeouts = {
      enabled = false,
      timeout_duration = 300, -- 5 minutes
      max_violations = 3,
      reset_interval = 3600, -- 1 hour
    },
  },
  performance = {
    cache_compiled_patterns = true,
    max_cache_size = 1000,
    batch_processing = true,
    max_batch_size = 100,
  },
  logging = {
    enabled = false,
    log_blocked = true,
    log_allowed = false,
    log_file = vim.fn.stdpath('cache') .. '/twitch-chat/filter.log',
    max_log_size = 1048576, -- 1MB
  },
  persistence = {
    enabled = true,
    save_rules = true,
    save_stats = true,
    rules_file = vim.fn.stdpath('cache') .. '/twitch-chat/filter_rules.json',
    stats_file = vim.fn.stdpath('cache') .. '/twitch-chat/filter_stats.json',
  },
}

-- Filter state
local filter_state = {
  rules = {},
  compiled_patterns = {},
  stats = {
    total_messages = 0,
    blocked_messages = 0,
    allowed_messages = 0,
    rules_triggered = {},
    user_violations = {},
    pattern_matches = {},
  },
  user_timeouts = {},
  recent_messages = {},
  -- Performance optimization caches
  rule_cache = {
    by_type = {
      pattern = {},
      user = {},
      content = {},
      command = {},
    },
    by_priority = {},
    sorted_rules = {},
    last_updated = 0,
  },
  performance_metrics = {
    filter_times = {},
    rule_hit_counts = {},
    cache_hits = 0,
    cache_misses = 0,
  },
}

-- Store event handler reference for cleanup
local message_received_handler = nil

-- Counter for generating unique IDs when utils.random_string returns same value
local rule_id_counter = 0

-- Performance cache
local pattern_cache = utils.create_cache(1000)
local user_cache = utils.create_cache(500)

---Initialize the filter module
---@param user_config table?
---@return boolean success
function M.setup(user_config)
  if user_config then
    default_config = utils.deep_merge(default_config, user_config)
  end

  -- Check if filtering is enabled
  if not default_config.enabled then
    return false
  end

  -- Initialize state
  M._init_state()

  -- Load persistent data
  M._load_persistent_data()

  -- Setup event listeners (after everything else is ready)
  M._setup_event_listeners()

  return true
end

---Check if filtering is enabled
---@return boolean enabled
function M.is_enabled()
  return default_config.enabled
end

---Filter a message
---@param message table Message data
---@return FilterResult
function M.filter_message(message)
  vim.validate({
    message = { message, 'table' },
  })

  -- Validate required message fields
  if not message.content or type(message.content) ~= 'string' then
    return { allowed = true, matches = {}, reason = 'Invalid message: missing content' }
  end

  if not message.username or type(message.username) ~= 'string' then
    return { allowed = true, matches = {}, reason = 'Invalid message: missing username' }
  end

  if not default_config.enabled then
    return { allowed = true, matches = {} }
  end

  local start_time = uv.hrtime()
  local result = {
    allowed = default_config.default_mode == 'allow',
    matches = {},
    reason = nil,
    processing_time = nil,
  }

  -- Update stats
  filter_state.stats.total_messages = filter_state.stats.total_messages + 1

  -- Check user timeouts
  if M._is_user_timed_out(message.username) then
    result.allowed = false
    result.reason = 'User is timed out'
    M._record_blocked_message(message, result)
    return result
  end

  -- Process filter rules in priority order
  local rules = M._get_sorted_rules()

  for _, rule in ipairs(rules) do
    if rule.enabled then
      local match = M._check_rule(message, rule)
      if match then
        table.insert(result.matches, match)

        -- Update rule stats
        M._update_rule_stats(rule.id)

        -- Apply rule action
        if rule.action == 'block' then
          result.allowed = false
          result.reason = 'Blocked by rule: ' .. rule.name
          break
        elseif rule.action == 'allow' then
          result.allowed = true
          result.reason = 'Allowed by rule: ' .. rule.name
          break
        end
      end
    end
  end

  -- Check content filtering
  if result.allowed and default_config.rules and default_config.rules.content then
    local content_result = M._check_content_filters(message)
    if content_result and not content_result.allowed then
      result.allowed = false
      result.reason = content_result.reason
      table.insert(result.matches, content_result)
    end
  end

  -- Check command filtering
  if result.allowed and default_config.rules and default_config.rules.commands then
    local command_result = M._check_command_filters(message)
    if command_result and not command_result.allowed then
      result.allowed = false
      result.reason = command_result.reason
      table.insert(result.matches, command_result)
    end
  end

  -- Record result
  if result.allowed then
    M._record_allowed_message(message, result)
  else
    M._record_blocked_message(message, result)

    -- Check for timeout
    if
      default_config.rules
      and default_config.rules.timeouts
      and default_config.rules.timeouts.enabled
    then
      M._check_user_timeout(message.username)
    end
  end

  -- Calculate processing time
  local end_time = uv.hrtime()
  result.processing_time = (end_time - start_time) / 1000000 -- Convert to milliseconds

  -- Track performance metrics
  table.insert(filter_state.performance_metrics.filter_times, result.processing_time)

  -- Keep only recent filter times (last 100 measurements)
  if #filter_state.performance_metrics.filter_times > 100 then
    table.remove(filter_state.performance_metrics.filter_times, 1)
  end

  return result
end

---Add a filter rule
---@param rule_data table Rule data
---@return string rule_id
function M.add_rule(rule_data)
  vim.validate({
    rule_data = { rule_data, 'table' },
  })

  -- Generate unique ID, handle test case where random_string might return same value
  local rule_id = rule_data.id
  if not rule_id then
    rule_id = utils.random_string(16)
    -- If this ID already exists (can happen in tests), append counter
    if filter_state.rules[rule_id] then
      rule_id_counter = rule_id_counter + 1
      rule_id = rule_id .. '_' .. tostring(rule_id_counter)
    end
  end

  local rule = {
    id = rule_id,
    name = rule_data.name or 'Unnamed Rule',
    type = rule_data.type or 'pattern',
    action = rule_data.action or 'block',
    pattern = rule_data.pattern,
    user = rule_data.user,
    enabled = rule_data.enabled ~= false,
    priority = rule_data.priority or 0,
    created_at = os.time(),
    last_used = 0,
    use_count = 0,
  }

  -- Validate rule
  local valid, error_msg = M._validate_rule(rule)
  if not valid then
    error('Invalid rule: ' .. error_msg)
  end

  -- Add to rules
  filter_state.rules[rule.id] = rule

  -- Compile pattern if needed
  if rule.type == 'pattern' and rule.pattern then
    M._compile_pattern(rule.id, rule.pattern)
  end

  -- Invalidate rule cache
  M._invalidate_rule_cache()

  -- Save rules
  if default_config.persistence.enabled and default_config.persistence.save_rules then
    M._save_rules()
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_rule_added', { rule = rule })

  return rule.id
end

---Remove a filter rule
---@param rule_id string Rule ID
---@return boolean success
function M.remove_rule(rule_id)
  vim.validate({
    rule_id = { rule_id, 'string' },
  })

  if not filter_state.rules[rule_id] then
    return false
  end

  -- Remove rule
  local rule = filter_state.rules[rule_id]
  filter_state.rules[rule_id] = nil

  -- Remove compiled pattern
  if filter_state.compiled_patterns[rule_id] then
    filter_state.compiled_patterns[rule_id] = nil
  end

  -- Invalidate rule cache
  M._invalidate_rule_cache()

  -- Save rules and return persistence result
  if default_config.persistence.enabled and default_config.persistence.save_rules then
    local save_result = M._save_rules()
    -- Emit event
    require('twitch-chat.events').emit('filter_rule_removed', { rule = rule })
    return save_result
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_rule_removed', { rule = rule })
  return true
end

---Update a filter rule
---@param rule_id string Rule ID
---@param updates table Updates to apply
---@return boolean success
function M.update_rule(rule_id, updates)
  vim.validate({
    rule_id = { rule_id, 'string' },
    updates = { updates, 'table' },
  })

  local rule = filter_state.rules[rule_id]
  if not rule then
    return false
  end

  -- Apply updates
  for key, value in pairs(updates) do
    if key ~= 'id' and key ~= 'created_at' then
      rule[key] = value
    end
  end

  -- Validate updated rule
  local valid, error_msg = M._validate_rule(rule)
  if not valid then
    error('Invalid rule update: ' .. error_msg)
  end

  -- Recompile pattern if needed
  if rule.type == 'pattern' and rule.pattern then
    M._compile_pattern(rule.id, rule.pattern)
  end

  -- Invalidate rule cache
  M._invalidate_rule_cache()

  -- Save rules
  if default_config.persistence.save_rules then
    M._save_rules()
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_rule_updated', { rule = rule })

  return true
end

---Get all filter rules
---@return table<string, FilterRule>
function M.get_rules()
  return vim.deepcopy(filter_state.rules)
end

---Get a specific filter rule
---@param rule_id string Rule ID
---@return FilterRule?
function M.get_rule(rule_id)
  vim.validate({
    rule_id = { rule_id, 'string' },
  })

  return filter_state.rules[rule_id] and vim.deepcopy(filter_state.rules[rule_id]) or nil
end

---Enable/disable a filter rule
---@param rule_id string Rule ID
---@param enabled boolean Whether to enable the rule
---@return boolean success
function M.toggle_rule(rule_id, enabled)
  vim.validate({
    rule_id = { rule_id, 'string' },
    enabled = { enabled, 'boolean' },
  })

  local rule = filter_state.rules[rule_id]
  if not rule then
    return false
  end

  rule.enabled = enabled

  -- Save rules
  if default_config.persistence.save_rules then
    M._save_rules()
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_rule_toggled', { rule = rule, enabled = enabled })

  return true
end

---Clear all filter rules
---@return nil
function M.clear_rules()
  filter_state.rules = {}
  filter_state.compiled_patterns = {}

  -- Save rules
  if default_config.persistence.save_rules then
    M._save_rules()
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_rules_cleared', {})
end

---Add user to block list
---@param username string Username to block
---@return boolean success
function M.block_user(username)
  vim.validate({
    username = { username, 'string' },
  })

  local rule_id = M.add_rule({
    name = 'Block user: ' .. username,
    type = 'user',
    action = 'block',
    user = username,
    priority = 100,
  })

  return rule_id ~= nil
end

---Add user to allow list
---@param username string Username to allow
---@return boolean success
function M.allow_user(username)
  vim.validate({
    username = { username, 'string' },
  })

  local rule_id = M.add_rule({
    name = 'Allow user: ' .. username,
    type = 'user',
    action = 'allow',
    user = username,
    priority = 200,
  })

  return rule_id ~= nil
end

---Add pattern to block list
---@param pattern string Pattern to block
---@param name string? Rule name
---@return boolean success
function M.block_pattern(pattern, name)
  vim.validate({
    pattern = { pattern, 'string' },
    name = { name, 'string', true },
  })

  local rule_id = M.add_rule({
    name = name or ('Block pattern: ' .. pattern),
    type = 'pattern',
    action = 'block',
    pattern = pattern,
    priority = 50,
  })

  return rule_id ~= nil
end

---Add pattern to allow list
---@param pattern string Pattern to allow
---@param name string? Rule name
---@return boolean success
function M.allow_pattern(pattern, name)
  vim.validate({
    pattern = { pattern, 'string' },
    name = { name, 'string', true },
  })

  local rule_id = M.add_rule({
    name = name or ('Allow pattern: ' .. pattern),
    type = 'pattern',
    action = 'allow',
    pattern = pattern,
    priority = 150,
  })

  return rule_id ~= nil
end

---Timeout a user
---@param username string Username to timeout
---@param duration number? Timeout duration in seconds
---@return boolean success
function M.timeout_user(username, duration)
  vim.validate({
    username = { username, 'string' },
    duration = { duration, 'number', true },
  })

  duration = duration or default_config.rules.timeouts.timeout_duration

  filter_state.user_timeouts[username] = {
    expires = os.time() + duration,
    violations = 0,
  }

  -- Emit event
  require('twitch-chat.events').emit('user_timed_out', { username = username, duration = duration })

  return true
end

---Remove timeout from user
---@param username string Username to remove timeout from
---@return boolean success
function M.untimeout_user(username)
  vim.validate({
    username = { username, 'string' },
  })

  if filter_state.user_timeouts[username] then
    filter_state.user_timeouts[username] = nil

    -- Emit event
    require('twitch-chat.events').emit('user_timeout_removed', { username = username })

    return true
  end

  return false
end

---Get filter statistics
---@return FilterStats
function M.get_stats()
  return vim.deepcopy(filter_state.stats)
end

---Reset filter statistics
---@return boolean success
function M.reset_stats()
  filter_state.stats = {
    total_messages = 0,
    blocked_messages = 0,
    allowed_messages = 0,
    rules_triggered = {},
    user_violations = {},
    pattern_matches = {},
  }

  -- Save stats and return persistence result
  if default_config.persistence.enabled and default_config.persistence.save_stats then
    local save_result = M._save_stats()
    -- Emit event
    require('twitch-chat.events').emit('filter_stats_reset', {})
    return save_result
  end

  -- Emit event
  require('twitch-chat.events').emit('filter_stats_reset', {})
  return true
end

---Setup event listeners
---@return nil
function M._setup_event_listeners()
  -- Create handler function
  message_received_handler = function(data)
    if data.username and data.content and data.channel then
      local message = {
        username = data.username,
        content = data.content,
        channel = data.channel,
        timestamp = data.timestamp or os.time(),
        badges = data.badges or {},
        emotes = data.emotes or {},
      }

      local result = M.filter_message(message)

      -- Emit filter result event
      local events_module = require('twitch-chat.events')
      events_module.emit('message_filtered', {
        message = message,
        result = result,
      })

      -- Block message if needed
      if not result.allowed then
        events_module.emit('message_blocked', {
          message = message,
          result = result,
        })
      end
    end
  end

  -- Filter messages as they are received
  local events_module = require('twitch-chat.events')
  events_module.on(events_module.MESSAGE_RECEIVED, message_received_handler)
end

---Initialize filter state
---@return nil
function M._init_state()
  filter_state = {
    rules = {},
    compiled_patterns = {},
    stats = {
      total_messages = 0,
      blocked_messages = 0,
      allowed_messages = 0,
      rules_triggered = {},
      user_violations = {},
      pattern_matches = {},
    },
    user_timeouts = {},
    recent_messages = {},
  }
end

---Load persistent data
---@return nil
function M._load_persistent_data()
  if default_config.persistence.enabled then
    if default_config.persistence.save_rules then
      M._load_rules()
    end

    if default_config.persistence.save_stats then
      M._load_stats()
    end
  end
end

---Get sorted rules by priority with caching
---@return FilterRule[]
function M._get_sorted_rules()
  -- Check if cache is valid
  if M._is_rule_cache_valid() then
    filter_state.performance_metrics.cache_hits = filter_state.performance_metrics.cache_hits + 1
    return filter_state.rule_cache.sorted_rules
  end

  filter_state.performance_metrics.cache_misses = filter_state.performance_metrics.cache_misses + 1

  -- Rebuild cache
  M._rebuild_rule_cache()

  return filter_state.rule_cache.sorted_rules
end

---Check if a rule matches a message
---@param message table Message data
---@param rule FilterRule Filter rule
---@return FilterMatch?
function M._check_rule(message, rule)
  if rule.type == 'pattern' and rule.pattern then
    return M._check_pattern_rule(message, rule)
  elseif rule.type == 'user' and rule.user then
    return M._check_user_rule(message, rule)
  elseif rule.type == 'content' then
    return M._check_content_rule(message, rule)
  elseif rule.type == 'command' then
    return M._check_command_rule(message, rule)
  end

  return nil
end

---Check pattern rule with safe regex execution
---@param message table Message data
---@param rule FilterRule Filter rule
---@return FilterMatch?
function M._check_pattern_rule(message, rule)
  local pattern = filter_state.compiled_patterns[rule.id]
  if not pattern then
    pattern = M._compile_pattern(rule.id, rule.pattern)
  end

  if not pattern then
    return nil
  end

  local content = message.content
  if not default_config.rules.patterns.case_sensitive then
    content = content:lower()
  end

  -- Safe pattern matching with timeout
  local match_start, match_end = M._safe_pattern_match(content, pattern)
  if match_start then
    return {
      rule_id = rule.id,
      rule_name = rule.name,
      action = rule.action,
      match_text = content:sub(match_start, match_end),
      match_start = match_start,
      match_end = match_end,
    }
  end

  return nil
end

---Safely execute pattern matching with timeout protection
---@param text string Text to search in
---@param pattern string Pattern to match
---@return number? match_start, number? match_end
function M._safe_pattern_match(text, pattern)
  local start_time = vim.loop.hrtime()
  local timeout_ns = REGEX_TIMEOUT_MS * 1000000 -- Convert to nanoseconds

  local success, match_start, match_end = pcall(function()
    local exec_start = vim.loop.hrtime()
    local s, e = text:find(pattern)
    local exec_time = vim.loop.hrtime() - exec_start

    if exec_time > timeout_ns then
      error('Pattern matching timeout')
    end

    return s, e
  end)

  local total_time = vim.loop.hrtime() - start_time
  if total_time > timeout_ns then
    utils.log(
      vim.log.levels.WARN,
      'Pattern matching took too long: ' .. (total_time / 1000000) .. 'ms'
    )
    return nil, nil
  end

  if success then
    return match_start, match_end
  else
    utils.log(vim.log.levels.ERROR, 'Pattern matching failed: ' .. (match_start or 'unknown error'))
    return nil, nil
  end
end

---Check user rule
---@param message table Message data
---@param rule FilterRule Filter rule
---@return FilterMatch?
function M._check_user_rule(message, rule)
  local username = message.username
  local rule_user = rule.user

  if not default_config.rules.users.case_sensitive then
    username = username:lower()
    if rule_user then
      rule_user = rule_user:lower()
    end
  end

  if username == rule_user then
    -- Check for bypass conditions
    if rule.action == 'block' then
      if default_config.rules.users.moderator_bypass and M._is_moderator(message) then
        return nil
      end

      if default_config.rules.users.vip_bypass and M._is_vip(message) then
        return nil
      end

      if default_config.rules.users.subscriber_bypass and M._is_subscriber(message) then
        return nil
      end
    end

    return {
      rule_id = rule.id,
      rule_name = rule.name,
      action = rule.action,
      match_text = message.username,
    }
  end

  return nil
end

---Check content rule
---@param message table Message data
---@param rule FilterRule Filter rule
---@return FilterMatch?
function M._check_content_rule(message, rule)
  local content = message.content

  -- Check for links
  if default_config.rules.content.filter_links then
    if content:match('https?://[%w%.%-_]+') then
      return {
        rule_id = rule.id,
        rule_name = rule.name,
        action = 'block',
        match_text = 'Contains link',
      }
    end
  end

  -- Check for excessive caps
  if default_config.rules.content.filter_caps then
    local caps_count = 0
    local total_chars = 0

    for char in content:gmatch('%a') do
      total_chars = total_chars + 1
      if char:match('%u') then
        caps_count = caps_count + 1
      end
    end

    if
      total_chars > 0 and caps_count / total_chars > default_config.rules.content.caps_threshold
    then
      return {
        rule_id = rule.id,
        rule_name = rule.name,
        action = 'block',
        match_text = 'Excessive caps',
      }
    end
  end

  -- Check for emote spam
  if default_config.rules.content.filter_emote_spam then
    local emote_count = message.emotes and #message.emotes or 0
    if emote_count > default_config.rules.content.emote_spam_threshold then
      return {
        rule_id = rule.id,
        rule_name = rule.name,
        action = 'block',
        match_text = 'Emote spam',
      }
    end
  end

  return nil
end

---Check command rule
---@param message table Message data
---@param rule FilterRule Filter rule
---@return FilterMatch?
function M._check_command_rule(message, rule)
  local content = message.content

  -- Check if message is a command
  if not content:match('^[!/]') then
    return nil
  end

  local command = content:match('^[!/](%w+)')
  if not command then
    return nil
  end

  -- Check blocked commands
  if utils.table_contains(default_config.rules.commands.blocked_commands, command) then
    return {
      rule_id = rule.id,
      rule_name = rule.name,
      action = 'block',
      match_text = 'Blocked command: ' .. command,
    }
  end

  -- Check allowed commands
  if #default_config.rules.commands.allowed_commands > 0 then
    if not utils.table_contains(default_config.rules.commands.allowed_commands, command) then
      return {
        rule_id = rule.id,
        rule_name = rule.name,
        action = 'block',
        match_text = 'Command not allowed: ' .. command,
      }
    end
  end

  return nil
end

---Compile regex pattern with security sandboxing
---@param rule_id string Rule ID
---@param pattern string Pattern to compile
---@return string? compiled_pattern
function M._compile_pattern(rule_id, pattern)
  -- Check cache first
  local cached = pattern_cache:get(pattern)
  if cached then
    filter_state.compiled_patterns[rule_id] = cached
    return cached
  end

  -- Validate pattern security before compilation
  local is_safe, reason = M._validate_pattern_security(pattern)
  if not is_safe then
    utils.log(
      vim.log.levels.ERROR,
      'Pattern rejected for security: ' .. pattern .. ' (' .. reason .. ')'
    )
    return nil
  end

  -- Compile pattern with timeout protection
  local success, compiled = M._safe_pattern_compile(pattern)

  if success and compiled then
    filter_state.compiled_patterns[rule_id] = compiled
    pattern_cache:set(pattern, compiled)
    return compiled
  else
    utils.log(vim.log.levels.ERROR, 'Failed to compile pattern: ' .. pattern)
    return nil
  end
end

---Validate pattern security to prevent ReDoS attacks
---@param pattern string Pattern to validate
---@return boolean is_safe, string reason
function M._validate_pattern_security(pattern)
  -- Check pattern length
  if #pattern > MAX_PATTERN_LENGTH then
    return false, 'Pattern too long'
  end

  -- Calculate complexity score
  local complexity = M._calculate_pattern_complexity(pattern)
  if complexity > PATTERN_COMPLEXITY_LIMIT then
    return false, 'Pattern too complex (score: ' .. complexity .. ')'
  end

  -- Check for dangerous constructs
  local dangerous_patterns = {
    '%(.*%+.*%)*', -- Nested quantifiers like (a+)*
    '%(.*%*.*%)*', -- Nested quantifiers like (a*)*
    '%(%?.*%|.*%)*', -- Complex alternation groups
    '%.%*%.%*', -- Multiple .* patterns
    '%.%+%.%+', -- Multiple .+ patterns
    '%[%^.*%]%*', -- Negated character class with *
    '%[%^.*%]%+', -- Negated character class with +
  }

  for _, dangerous in ipairs(dangerous_patterns) do
    if pattern:find(dangerous) then
      return false, 'Dangerous pattern construct detected'
    end
  end

  return true, 'Pattern is safe'
end

---Calculate pattern complexity score
---@param pattern string Pattern to analyze
---@return number complexity_score
function M._calculate_pattern_complexity(pattern)
  local score = 0

  -- Base score from length
  score = score + #pattern / 10

  -- Quantifiers add complexity
  local quantifiers = { '%*', '%+', '%?', '%{.-}' }
  for _, q in ipairs(quantifiers) do
    local _, count = pattern:gsub(q, '')
    score = score + count * 5
  end

  -- Character classes add complexity
  local _, class_count = pattern:gsub('%[.-%]', '')
  score = score + class_count * 3

  -- Groups add complexity
  local _, group_count = pattern:gsub('%(.-%)', '')
  score = score + group_count * 4

  -- Alternation adds complexity
  local _, alt_count = pattern:gsub('%|', '')
  score = score + alt_count * 6

  -- Anchors are generally safe
  local _, anchor_count = pattern:gsub('[%^%$]', '')
  score = score + anchor_count * 1

  return score
end

---Safely compile pattern with timeout protection
---@param pattern string Original pattern
---@return boolean success, string? compiled_pattern
function M._safe_pattern_compile(pattern)
  local start_time = vim.loop.hrtime()
  local timeout_ns = REGEX_TIMEOUT_MS * 1000000 -- Convert to nanoseconds

  local success, result = pcall(function()
    local p = pattern
    if not default_config.rules.patterns.case_sensitive then
      p = p:lower()
    end

    if default_config.rules.patterns.whole_word then
      p = '%f[%w]' .. p .. '%f[%W]'
    end

    -- Test pattern compilation with timeout check
    local compile_start = vim.loop.hrtime()
    local test_result = string.match('test', p)
    local compile_time = vim.loop.hrtime() - compile_start

    if compile_time > timeout_ns then
      error('Pattern compilation timeout')
    end

    return p
  end)

  local total_time = vim.loop.hrtime() - start_time
  if total_time > timeout_ns then
    utils.log(
      vim.log.levels.WARN,
      'Pattern compilation took too long: ' .. (total_time / 1000000) .. 'ms'
    )
    return false, nil
  end

  return success, result
end

---Validate filter rule
---@param rule FilterRule Rule to validate
---@return boolean valid, string? error_msg
function M._validate_rule(rule)
  if not rule.name or rule.name == '' then
    return false, 'Rule name is required'
  end

  if
    not rule.type
    or not utils.table_contains({ 'pattern', 'user', 'content', 'command' }, rule.type)
  then
    return false, 'Invalid rule type'
  end

  if not rule.action or not utils.table_contains({ 'block', 'allow' }, rule.action) then
    return false, 'Invalid rule action'
  end

  if rule.type == 'pattern' and (not rule.pattern or rule.pattern == '') then
    return false, 'Pattern is required for pattern rules'
  end

  if rule.type == 'user' and (not rule.user or rule.user == '') then
    return false, 'User is required for user rules'
  end

  if rule.type == 'pattern' then
    -- Use enhanced security validation for patterns
    local is_safe, reason = M._validate_pattern_security(rule.pattern)
    if not is_safe then
      return false, 'Pattern security validation failed: ' .. reason
    end

    -- Test pattern compilation with sandboxing
    local success, compiled = M._safe_pattern_compile(rule.pattern)
    if not success or not compiled then
      return false, 'Invalid regex pattern or compilation failed'
    end
  end

  return true
end

---Check if user is timed out
---@param username string Username to check
---@return boolean
function M._is_user_timed_out(username)
  local timeout = filter_state.user_timeouts[username]
  if not timeout then
    return false
  end

  if os.time() > timeout.expires then
    filter_state.user_timeouts[username] = nil
    return false
  end

  return true
end

---Check content filters (links, caps, emotes, spam)
---@param message table Message data
---@return table|nil filter_result
function M._check_content_filters(message)
  if not message or not message.content then
    return nil
  end

  local content = message.content
  local config = default_config.rules.content

  -- Check for links
  if config.filter_links then
    if content:match('https?://[%w%.%-_]+') then
      return {
        allowed = false,
        reason = 'Message contains links',
        rule_type = 'content_filter',
        match_text = content:match('https?://[%w%.%-_]+'),
      }
    end
  end

  -- Check for excessive caps
  if config.filter_caps then
    local caps_count = 0
    local total_letters = 0
    for i = 1, #content do
      local char = content:sub(i, i)
      if char:match('%a') then
        total_letters = total_letters + 1
        if char:match('%u') then
          caps_count = caps_count + 1
        end
      end
    end

    if total_letters > 0 and (caps_count / total_letters) > config.caps_threshold then
      return {
        allowed = false,
        reason = 'Message has excessive caps',
        rule_type = 'content_filter',
        match_text = string.format('%.1f%% caps', (caps_count / total_letters) * 100),
      }
    end
  end

  -- Check for emote spam
  if config.filter_emote_spam and message.emotes then
    local emote_count = 0
    if type(message.emotes) == 'table' then
      emote_count = #message.emotes
    end

    if emote_count > config.emote_spam_threshold then
      return {
        allowed = false,
        reason = 'Message has too many emotes',
        rule_type = 'content_filter',
        match_text = string.format('%d emotes', emote_count),
      }
    end
  end

  -- Check for spam using existing function
  if config.filter_spam then
    if M._is_spam(message) then
      return {
        allowed = false,
        reason = 'Message identified as spam',
        rule_type = 'content_filter',
        match_text = 'Duplicate message',
      }
    end
  end

  return { allowed = true }
end

---Check command filters
---@param message table Message data
---@return table|nil filter_result
function M._check_command_filters(message)
  if not message or not message.content then
    return nil
  end

  local content = message.content
  local config = default_config.rules.commands

  -- Check if message is a command
  local command_match = content:match('^/([%w_]+)')
  if not command_match then
    return { allowed = true } -- Not a command
  end

  local command = command_match:lower()

  -- Check blocked commands
  if config.blocked_commands and vim.tbl_contains(config.blocked_commands, command) then
    return {
      allowed = false,
      reason = 'Command is blocked',
      rule_type = 'command_filter',
      match_text = '/' .. command,
    }
  end

  -- Check allowed commands (if allow list exists, only these are allowed)
  if config.allowed_commands and #config.allowed_commands > 0 then
    if not vim.tbl_contains(config.allowed_commands, command) then
      return {
        allowed = false,
        reason = 'Command not in allow list',
        rule_type = 'command_filter',
        match_text = '/' .. command,
      }
    end
  end

  return { allowed = true }
end

---Check if message is spam
---@param message table Message data
---@return boolean
function M._is_spam(message)
  if not default_config.rules.content.filter_spam then
    return false
  end

  -- Validate message structure
  if not message or not message.content or not message.username then
    return false
  end

  local content = message.content
  local username = message.username

  -- Add to recent messages
  if not filter_state.recent_messages[username] then
    filter_state.recent_messages[username] = {}
  end

  local recent = filter_state.recent_messages[username]
  table.insert(recent, content)

  -- Keep only recent messages
  if #recent > 10 then
    table.remove(recent, 1)
  end

  -- Check for repeated messages
  local count = 0
  for _, msg in ipairs(recent) do
    if msg == content then
      count = count + 1
    end
  end

  return count >= default_config.rules.content.spam_threshold
end

---Check if user is moderator
---@param message table Message data
---@return boolean
function M._is_moderator(message)
  if not message.badges then
    return false
  end

  for _, badge in ipairs(message.badges) do
    if badge == 'moderator' or badge == 'broadcaster' then
      return true
    end
  end

  return false
end

---Check if user is VIP
---@param message table Message data
---@return boolean
function M._is_vip(message)
  if not message.badges then
    return false
  end

  for _, badge in ipairs(message.badges) do
    if badge == 'vip' then
      return true
    end
  end

  return false
end

---Check if user is subscriber
---@param message table Message data
---@return boolean
function M._is_subscriber(message)
  if not message.badges then
    return false
  end

  for _, badge in ipairs(message.badges) do
    if badge:match('^subscriber') then
      return true
    end
  end

  return false
end

---Check user timeout conditions
---@param username string Username to check
---@return nil
function M._check_user_timeout(username)
  if not filter_state.user_timeouts[username] then
    filter_state.user_timeouts[username] = {
      expires = 0,
      violations = 0,
    }
  end

  local timeout = filter_state.user_timeouts[username]
  timeout.violations = timeout.violations + 1

  if timeout.violations >= default_config.rules.timeouts.max_violations then
    M.timeout_user(username, default_config.rules.timeouts.timeout_duration)
  end
end

---Record blocked message
---@param message table Message data
---@param result FilterResult Filter result
---@return nil
function M._record_blocked_message(message, result)
  filter_state.stats.blocked_messages = filter_state.stats.blocked_messages + 1

  -- Record user violations
  if not filter_state.stats.user_violations[message.username] then
    filter_state.stats.user_violations[message.username] = 0
  end
  filter_state.stats.user_violations[message.username] = filter_state.stats.user_violations[message.username]
    + 1

  -- Log if enabled
  if default_config.logging.enabled and default_config.logging.log_blocked then
    M._log_message('BLOCKED', message, result)
  end
end

---Record allowed message
---@param message table Message data
---@param result FilterResult Filter result
---@return nil
function M._record_allowed_message(message, result)
  filter_state.stats.allowed_messages = filter_state.stats.allowed_messages + 1

  -- Log if enabled
  if default_config.logging.enabled and default_config.logging.log_allowed then
    M._log_message('ALLOWED', message, result)
  end
end

---Update rule statistics
---@param rule_id string Rule ID
---@return nil
function M._update_rule_stats(rule_id)
  local rule = filter_state.rules[rule_id]
  if not rule then
    return
  end

  -- Update rule usage using cache-aware mechanism
  M._update_rule_usage(rule_id)

  -- Update global stats
  if not filter_state.stats.rules_triggered[rule_id] then
    filter_state.stats.rules_triggered[rule_id] = 0
  end
  filter_state.stats.rules_triggered[rule_id] = filter_state.stats.rules_triggered[rule_id] + 1
end

---Log message
---@param action string Action taken
---@param message table Message data
---@param result FilterResult Filter result
---@return nil
function M._log_message(action, message, result)
  local log_file = default_config.logging.log_file
  if not log_file then
    return
  end

  local timestamp = utils.format_timestamp(os.time())
  local log_entry = string.format(
    '[%s] %s: %s@%s: %s (reason: %s)\n',
    timestamp,
    action,
    message.username,
    message.channel,
    message.content,
    result.reason or 'none'
  )

  -- Append to log file
  local file = io.open(log_file, 'a')
  if file then
    file:write(log_entry)
    file:close()
  end
end

---Save rules to disk
---@return boolean success
function M._save_rules()
  if not default_config.persistence.enabled or not default_config.persistence.save_rules then
    return false
  end

  local rules_file = default_config.persistence.rules_file
  if not rules_file then
    -- Fallback to default path for tests
    rules_file = vim.fn.stdpath('cache') .. '/twitch-chat/filter_rules.json'
  end

  local rules_dir = vim.fn.fnamemodify(rules_file, ':h')

  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(rules_dir) == 0 then
    vim.fn.mkdir(rules_dir, 'p')
  end

  -- Convert rules table to array for JSON serialization
  local rules_array = {}
  for _, rule in pairs(filter_state.rules) do
    table.insert(rules_array, rule)
  end

  local data = {
    version = 1,
    timestamp = os.time(),
    rules = rules_array,
  }

  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end

  return require('twitch-chat.utils').write_file(rules_file, encoded)
end

---Load rules from disk
---@return nil
function M._load_rules()
  local rules_file = default_config.persistence.rules_file
  if not rules_file or not utils.file_exists(rules_file) then
    return
  end

  local content = utils.read_file(rules_file)
  if not content then
    return
  end

  local success, rules_data = pcall(vim.fn.json_decode, content)
  if success and rules_data.rules then
    filter_state.rules = rules_data.rules

    -- Recompile patterns
    for rule_id, rule in pairs(filter_state.rules) do
      if rule.type == 'pattern' and rule.pattern then
        M._compile_pattern(rule_id, rule.pattern)
      end
    end
  end
end

---Save statistics to disk
---@return boolean success
function M._save_stats()
  if not default_config.persistence.enabled or not default_config.persistence.save_stats then
    return false
  end

  local stats_file = default_config.persistence.stats_file
  if not stats_file then
    -- Fallback to default path for tests
    stats_file = vim.fn.stdpath('cache') .. '/twitch-chat/filter_stats.json'
  end

  local stats_dir = vim.fn.fnamemodify(stats_file, ':h')

  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(stats_dir) == 0 then
    vim.fn.mkdir(stats_dir, 'p')
  end

  local data = {
    version = 1,
    timestamp = os.time(),
    stats = filter_state.stats,
  }

  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end

  return require('twitch-chat.utils').write_file(stats_file, encoded)
end

---Load statistics from disk
---@return nil
function M._load_stats()
  local stats_file = default_config.persistence.stats_file
  if not stats_file or not utils.file_exists(stats_file) then
    return
  end

  local content = utils.read_file(stats_file)
  if not content then
    return
  end

  local success, stats_data = pcall(vim.fn.json_decode, content)
  if success and stats_data.stats then
    filter_state.stats = utils.deep_merge(filter_state.stats, stats_data.stats)
  end
end

---Cleanup function
---@return boolean success
function M.cleanup()
  -- Save persistent data before cleanup
  local save_success = true
  if default_config.persistence.enabled then
    if default_config.persistence.save_rules then
      save_success = save_success and M._save_rules()
    end

    if default_config.persistence.save_stats then
      save_success = save_success and M._save_stats()
    end
  end

  -- Clear all state
  filter_state = {
    rules = {},
    compiled_patterns = {},
    stats = {
      total_messages = 0,
      blocked_messages = 0,
      allowed_messages = 0,
      rules_triggered = {},
      user_violations = {},
      pattern_matches = {},
    },
    user_timeouts = {},
    recent_messages = {},
  }

  -- Reset ID counter
  rule_id_counter = 0

  -- Remove event listeners
  local events_module = require('twitch-chat.events')
  if events_module.off and message_received_handler then
    events_module.off(events_module.MESSAGE_RECEIVED, message_received_handler)
    message_received_handler = nil
  end

  -- Clear compiled patterns cache
  if default_config.performance.cache_compiled_patterns then
    for pattern, _ in pairs(filter_state.compiled_patterns) do
      filter_state.compiled_patterns[pattern] = nil
    end
  end

  -- Clear caches
  pattern_cache:clear()
  user_cache:clear()

  return save_success
end

-- Rule Cache Management Functions

---Check if rule cache is valid
---@return boolean valid
function M._is_rule_cache_valid()
  local current_time = os.time()
  local cache_age = current_time - filter_state.rule_cache.last_updated
  local max_cache_age = 300 -- 5 minutes

  return cache_age < max_cache_age and #filter_state.rule_cache.sorted_rules > 0
end

---Invalidate rule cache
function M._invalidate_rule_cache()
  filter_state.rule_cache = {
    by_type = {
      pattern = {},
      user = {},
      content = {},
      command = {},
    },
    by_priority = {},
    sorted_rules = {},
    last_updated = 0,
  }
end

---Rebuild rule cache with optimizations
function M._rebuild_rule_cache()
  local current_time = os.time()

  -- Clear existing cache
  M._invalidate_rule_cache()

  -- Build sorted rules list
  local rules = {}
  for _, rule in pairs(filter_state.rules) do
    table.insert(rules, rule)
  end

  -- Sort by priority (highest first)
  table.sort(rules, function(a, b)
    if a.priority == b.priority then
      -- Secondary sort by use count for equal priorities
      return a.use_count > b.use_count
    end
    return a.priority > b.priority
  end)

  filter_state.rule_cache.sorted_rules = rules

  -- Build type-based indexes for fast lookups
  for _, rule in ipairs(rules) do
    local type_cache = filter_state.rule_cache.by_type[rule.type]
    if type_cache then
      table.insert(type_cache, rule)
    end

    -- Build priority-based index
    local priority = rule.priority
    if not filter_state.rule_cache.by_priority[priority] then
      filter_state.rule_cache.by_priority[priority] = {}
    end
    table.insert(filter_state.rule_cache.by_priority[priority], rule)
  end

  filter_state.rule_cache.last_updated = current_time

  utils.log(vim.log.levels.DEBUG, string.format('Rebuilt rule cache with %d rules', #rules))
end

---Get rules by type from cache
---@param rule_type string Rule type ('pattern', 'user', 'content', 'command')
---@return FilterRule[]
function M._get_rules_by_type(rule_type)
  if not M._is_rule_cache_valid() then
    M._rebuild_rule_cache()
  end

  return filter_state.rule_cache.by_type[rule_type] or {}
end

---Get rules by priority from cache
---@param priority number Priority level
---@return FilterRule[]
function M._get_rules_by_priority(priority)
  if not M._is_rule_cache_valid() then
    M._rebuild_rule_cache()
  end

  return filter_state.rule_cache.by_priority[priority] or {}
end

---Update rule usage statistics for cache optimization
---@param rule_id string Rule ID
function M._update_rule_usage(rule_id)
  local rule = filter_state.rules[rule_id]
  if rule then
    rule.use_count = rule.use_count + 1
    rule.last_used = os.time()

    -- Track hit counts for performance metrics
    if not filter_state.performance_metrics.rule_hit_counts[rule_id] then
      filter_state.performance_metrics.rule_hit_counts[rule_id] = 0
    end
    filter_state.performance_metrics.rule_hit_counts[rule_id] = filter_state.performance_metrics.rule_hit_counts[rule_id]
      + 1

    -- Invalidate cache if usage patterns have changed significantly
    -- This helps keep frequently used rules at the top
    if rule.use_count % 10 == 0 then
      M._invalidate_rule_cache()
    end
  end
end

---Get cache performance statistics
---@return table stats
function M.get_cache_stats()
  return {
    cache_hits = filter_state.performance_metrics.cache_hits,
    cache_misses = filter_state.performance_metrics.cache_misses,
    hit_ratio = filter_state.performance_metrics.cache_hits
      / math.max(
        1,
        filter_state.performance_metrics.cache_hits + filter_state.performance_metrics.cache_misses
      ),
    cached_rules = #filter_state.rule_cache.sorted_rules,
    last_cache_update = filter_state.rule_cache.last_updated,
    rule_hit_counts = filter_state.performance_metrics.rule_hit_counts,
  }
end

return M
