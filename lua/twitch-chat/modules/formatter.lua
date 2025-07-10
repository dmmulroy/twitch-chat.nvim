---@class TwitchChatFormatter
---Message formatting logic separated from display concerns
local M = {}

---@class FormatterConfig
---@field timestamp_format string Format string for timestamps
---@field username_format string Format string for usernames
---@field content_format string Format string for message content
---@field badge_format string Format string for badges
---@field mention_detection boolean Enable mention detection
---@field command_detection boolean Enable command detection
---@field emote_detection boolean Enable emote detection
---@field url_detection boolean Enable URL detection
---@field custom_formatters table<string, function> Custom formatting functions

---@class MessageComponent
---@field type string Component type ('timestamp', 'badge', 'username', 'content', 'emote', 'url', 'mention')
---@field content string Raw content
---@field formatted string Formatted content
---@field start_pos number Start position in formatted line
---@field end_pos number End position in formatted line
---@field metadata table? Additional metadata for the component

---@class FormattedMessage
---@field raw_message table Original message data
---@field formatted_line string Complete formatted line
---@field components MessageComponent[] Individual message components
---@field total_length number Total length of formatted line
---@field metadata table Additional formatting metadata

local config = require('twitch-chat.config')
local utils = require('twitch-chat.utils')

---@type FormatterConfig
local default_config = {
  timestamp_format = '[%H:%M:%S]',
  username_format = '<%s>',
  content_format = '%s',
  badge_format = '[%s]',
  mention_detection = true,
  command_detection = true,
  emote_detection = true,
  url_detection = true,
  custom_formatters = {},
}

-- Pattern cache for performance
local pattern_cache = {
  mention = '@([%w_]+)',
  command = '^!([%w_]+)',
  url = 'https?://[%w%.%-_/#%%&%?=]+',
  emote_word = '%w+',
}

---Initialize the formatter module
---@param user_config FormatterConfig?
---@return boolean success
function M.setup(user_config)
  if user_config then
    default_config = utils.deep_merge(default_config, user_config)
  end

  return true
end

---Format a message into components and assembled line
---@param message table Raw message data
---@param options table? Formatting options
---@return FormattedMessage formatted_message
function M.format_message(message, options)
  vim.validate({
    message = { message, 'table' },
    options = { options, 'table', true },
  })

  options = options or {}

  -- Ensure required message fields
  local safe_message = M._normalize_message(message)

  -- Extract and format individual components
  local components = {}
  local current_pos = 1

  -- 1. Timestamp component
  if options.include_timestamp ~= false then
    local timestamp_comp = M._format_timestamp(safe_message, current_pos)
    table.insert(components, timestamp_comp)
    current_pos = timestamp_comp.end_pos + 1
  end

  -- 2. Badges component
  if safe_message.badges and #safe_message.badges > 0 then
    local badges_comp = M._format_badges(safe_message, current_pos)
    table.insert(components, badges_comp)
    current_pos = badges_comp.end_pos + 1
  end

  -- 3. Username component
  local username_comp = M._format_username(safe_message, current_pos)
  table.insert(components, username_comp)
  current_pos = username_comp.end_pos + 1

  -- 4. Content components (may include multiple parts)
  local content_components = M._format_content(safe_message, current_pos, options)
  for _, comp in ipairs(content_components) do
    table.insert(components, comp)
    current_pos = comp.end_pos + 1
  end

  -- Assemble final formatted line
  local formatted_line = M._assemble_line(components)

  return {
    raw_message = safe_message,
    formatted_line = formatted_line,
    components = components,
    total_length = #formatted_line,
    metadata = {
      format_time = os.time(),
      has_mentions = M._has_component_type(components, 'mention'),
      has_commands = M._has_component_type(components, 'command'),
      has_emotes = M._has_component_type(components, 'emote'),
      has_urls = M._has_component_type(components, 'url'),
    },
  }
end

---Format message content and detect special elements
---@param message table Message data
---@param start_pos number Starting position
---@param options table Formatting options
---@return MessageComponent[] content_components
function M._format_content(message, start_pos, options)
  local content = message.content or ''
  local components = {}
  local current_pos = start_pos
  local text_pos = 1

  -- Process content character by character to detect patterns
  local processed_ranges = {}

  -- 1. Detect and extract URLs
  if default_config.url_detection and options.detect_urls ~= false then
    for url_start, url_end in content:gmatch('()' .. pattern_cache.url .. '()') do
      local url = content:sub(url_start, url_end - 1)
      table.insert(processed_ranges, {
        start = url_start,
        end_pos = url_end - 1,
        type = 'url',
        content = url,
      })
    end
  end

  -- 2. Detect mentions
  if default_config.mention_detection and options.detect_mentions ~= false then
    for mention_start, mention_end in content:gmatch('()' .. pattern_cache.mention .. '()') do
      local mention = content:sub(mention_start, mention_end - 1)
      -- Check if this range overlaps with URLs
      if not M._overlaps_with_ranges(mention_start, mention_end - 1, processed_ranges) then
        table.insert(processed_ranges, {
          start = mention_start,
          end_pos = mention_end - 1,
          type = 'mention',
          content = mention,
        })
      end
    end
  end

  -- 3. Detect commands (only at the beginning)
  if default_config.command_detection and options.detect_commands ~= false then
    local command_match = content:match('^(' .. pattern_cache.command .. ')')
    if command_match then
      table.insert(processed_ranges, {
        start = 1,
        end_pos = #command_match,
        type = 'command',
        content = command_match,
      })
    end
  end

  -- 4. Detect emotes (delegate to emote module if available)
  if default_config.emote_detection and options.detect_emotes ~= false then
    local emote_ranges = M._detect_emotes(content, message.channel)
    for _, emote_range in ipairs(emote_ranges) do
      if not M._overlaps_with_ranges(emote_range.start, emote_range.end_pos, processed_ranges) then
        table.insert(processed_ranges, emote_range)
      end
    end
  end

  -- Sort ranges by position
  table.sort(processed_ranges, function(a, b)
    return a.start < b.start
  end)

  -- Build components from ranges
  local last_end = 0

  for _, range in ipairs(processed_ranges) do
    -- Add plain text before this range
    if range.start > last_end + 1 then
      local plain_text = content:sub(last_end + 1, range.start - 1)
      if plain_text ~= '' then
        table.insert(components, {
          type = 'content',
          content = plain_text,
          formatted = plain_text,
          start_pos = current_pos,
          end_pos = current_pos + #plain_text - 1,
          metadata = { is_plain_text = true },
        })
        current_pos = current_pos + #plain_text
      end
    end

    -- Add the special component
    table.insert(components, {
      type = range.type,
      content = range.content,
      formatted = range.content,
      start_pos = current_pos,
      end_pos = current_pos + #range.content - 1,
      metadata = range.metadata or {},
    })
    current_pos = current_pos + #range.content
    last_end = range.end_pos
  end

  -- Add remaining plain text
  if last_end < #content then
    local remaining_text = content:sub(last_end + 1)
    if remaining_text ~= '' then
      table.insert(components, {
        type = 'content',
        content = remaining_text,
        formatted = remaining_text,
        start_pos = current_pos,
        end_pos = current_pos + #remaining_text - 1,
        metadata = { is_plain_text = true },
      })
    end
  end

  -- If no special components found, treat entire content as plain text
  if #components == 0 and content ~= '' then
    table.insert(components, {
      type = 'content',
      content = content,
      formatted = content,
      start_pos = current_pos,
      end_pos = current_pos + #content - 1,
      metadata = { is_plain_text = true },
    })
  end

  return components
end

---Format timestamp component
---@param message table Message data
---@param start_pos number Starting position
---@return MessageComponent timestamp_component
function M._format_timestamp(message, start_pos)
  local timestamp = os.date(default_config.timestamp_format, message.timestamp or os.time())

  return {
    type = 'timestamp',
    content = tostring(message.timestamp or os.time()),
    formatted = timestamp,
    start_pos = start_pos,
    end_pos = start_pos + #timestamp - 1,
    metadata = {
      raw_timestamp = message.timestamp,
      format_string = default_config.timestamp_format,
    },
  }
end

---Format badges component
---@param message table Message data
---@param start_pos number Starting position
---@return MessageComponent badges_component
function M._format_badges(message, start_pos)
  local badges_list = {}

  if message.badges then
    if type(message.badges) == 'table' then
      -- Handle both array and key-value badge formats
      for badge, value in pairs(message.badges) do
        if type(badge) == 'number' then
          -- Array format: badges = {'mod', 'subscriber'}
          table.insert(badges_list, value)
        else
          -- Key-value format: badges = {mod = '1', subscriber = '12'}
          if value and value ~= '' and value ~= '0' then
            table.insert(badges_list, badge .. (value ~= '1' and '/' .. value or ''))
          else
            table.insert(badges_list, badge)
          end
        end
      end
    end
  end

  local badges_str = table.concat(badges_list, ',')
  local formatted = string.format(default_config.badge_format, badges_str)

  return {
    type = 'badge',
    content = badges_str,
    formatted = formatted,
    start_pos = start_pos,
    end_pos = start_pos + #formatted - 1,
    metadata = {
      badge_count = #badges_list,
      individual_badges = badges_list,
    },
  }
end

---Format username component
---@param message table Message data
---@param start_pos number Starting position
---@return MessageComponent username_component
function M._format_username(message, start_pos)
  local username = message.username or message.display_name or 'unknown'
  local formatted = string.format(default_config.username_format, username)

  return {
    type = 'username',
    content = username,
    formatted = formatted,
    start_pos = start_pos,
    end_pos = start_pos + #formatted - 1,
    metadata = {
      display_name = message.display_name,
      user_color = message.color,
      is_mod = message.is_mod or message.mod,
      is_vip = message.is_vip or message.vip,
      is_subscriber = message.is_subscriber or message.subscriber,
    },
  }
end

---Detect emotes in content
---@param content string Message content
---@param channel string? Channel name
---@return table[] emote_ranges
function M._detect_emotes(content, channel)
  local emote_ranges = {}

  -- Try to use emote module if available
  local ok, emotes = pcall(require, 'twitch-chat.modules.emotes')
  if ok and emotes and emotes.parse_emotes then
    local emote_matches = emotes.parse_emotes(content, channel or '')

    for _, match in ipairs(emote_matches) do
      table.insert(emote_ranges, {
        start = match.start_pos,
        end_pos = match.end_pos,
        type = 'emote',
        content = match.text,
        metadata = {
          emote_data = match.emote,
          provider = match.emote.provider,
        },
      })
    end
  end

  return emote_ranges
end

---Check if a range overlaps with existing ranges
---@param start number Start position
---@param end_pos number End position
---@param ranges table[] Existing ranges
---@return boolean overlaps
function M._overlaps_with_ranges(start, end_pos, ranges)
  for _, range in ipairs(ranges) do
    if
      (start >= range.start and start <= range.end_pos)
      or (end_pos >= range.start and end_pos <= range.end_pos)
      or (start <= range.start and end_pos >= range.end_pos)
    then
      return true
    end
  end
  return false
end

---Check if components contain a specific type
---@param components MessageComponent[] Components list
---@param component_type string Type to check for
---@return boolean has_type
function M._has_component_type(components, component_type)
  for _, comp in ipairs(components) do
    if comp.type == component_type then
      return true
    end
  end
  return false
end

---Assemble components into final formatted line
---@param components MessageComponent[] Message components
---@return string formatted_line
function M._assemble_line(components)
  local parts = {}

  for i, comp in ipairs(components) do
    table.insert(parts, comp.formatted)

    -- Add spacing between components (except last)
    if i < #components then
      local next_comp = components[i + 1]
      -- Add space unless next component starts with space
      if not next_comp.formatted:match('^%s') and not comp.formatted:match('%s$') then
        table.insert(parts, ' ')
      end
    end
  end

  return table.concat(parts)
end

---Normalize message data to ensure required fields
---@param message table Raw message data
---@return table normalized_message
function M._normalize_message(message)
  return {
    username = message.username or message.display_name or 'unknown',
    display_name = message.display_name or message.username,
    content = message.content or message.text or '',
    timestamp = message.timestamp or os.time(),
    badges = message.badges or {},
    color = message.color,
    channel = message.channel,
    is_mod = message.is_mod or message.mod,
    is_vip = message.is_vip or message.vip,
    is_subscriber = message.is_subscriber or message.subscriber,
    emotes = message.emotes or {},
  }
end

---Get highlight information for display modules
---@param formatted_message FormattedMessage Formatted message data
---@param highlight_config table? Highlight configuration
---@return table[] highlights
function M.get_highlights(formatted_message, highlight_config)
  vim.validate({
    formatted_message = { formatted_message, 'table' },
    highlight_config = { highlight_config, 'table', true },
  })

  highlight_config = highlight_config or {}
  local highlights = {}

  for _, component in ipairs(formatted_message.components) do
    local hl_group = M._get_highlight_group(component, highlight_config)
    if hl_group then
      table.insert(highlights, {
        col_start = component.start_pos - 1, -- 0-indexed for Neovim
        col_end = component.end_pos,
        hl_group = hl_group,
        component_type = component.type,
        metadata = component.metadata,
      })
    end
  end

  return highlights
end

---Get appropriate highlight group for component
---@param component MessageComponent Message component
---@param highlight_config table Highlight configuration
---@return string? highlight_group
function M._get_highlight_group(component, highlight_config)
  local base_config = config.get('ui.highlights') or {}
  local custom_config = highlight_config or {}

  -- Check for custom highlight group first
  if custom_config[component.type] then
    return custom_config[component.type]
  end

  -- Default highlight groups by component type
  local type_mapping = {
    timestamp = base_config.timestamp or 'Comment',
    badge = base_config.badge or 'Special',
    username = M._get_username_highlight(component, base_config),
    content = base_config.message or 'Normal',
    mention = base_config.mention or 'WarningMsg',
    command = base_config.command or 'Function',
    emote = base_config.emote or 'Special',
    url = base_config.url or 'Underlined',
  }

  return type_mapping[component.type]
end

---Get username-specific highlight group
---@param component MessageComponent Username component
---@param base_config table Base highlight configuration
---@return string highlight_group
function M._get_username_highlight(component, base_config)
  -- Use user color if available
  if component.metadata.user_color then
    local sanitized_name = component.content:gsub('%W', '')
    return 'TwitchChatUser' .. sanitized_name
  end

  -- Use role-based highlighting
  if component.metadata.is_mod then
    return base_config.moderator or 'Function'
  elseif component.metadata.is_vip then
    return base_config.vip or 'Special'
  elseif component.metadata.is_subscriber then
    return base_config.subscriber or 'Identifier'
  end

  return base_config.username or 'Identifier'
end

---Apply custom formatter function
---@param message table Message data
---@param formatter_name string Custom formatter name
---@param ... any Additional arguments
---@return FormattedMessage? formatted_message
function M.apply_custom_formatter(message, formatter_name, ...)
  local formatter = default_config.custom_formatters[formatter_name]
  if not formatter or type(formatter) ~= 'function' then
    return nil
  end

  local success, result = pcall(formatter, message, ...)
  if success then
    return result
  else
    utils.log(vim.log.levels.ERROR, 'Custom formatter error: ' .. tostring(result))
    return nil
  end
end

---Register custom formatter function
---@param name string Formatter name
---@param formatter function Formatter function
function M.register_custom_formatter(name, formatter)
  vim.validate({
    name = { name, 'string' },
    formatter = { formatter, 'function' },
  })

  default_config.custom_formatters[name] = formatter
end

---Get formatter statistics
---@return table stats
function M.get_stats()
  return {
    custom_formatters = vim.tbl_count(default_config.custom_formatters),
    config = default_config,
    pattern_cache_size = vim.tbl_count(pattern_cache),
  }
end

return M
