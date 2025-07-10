---@class TwitchChatCompletion
---nvim-cmp integration for Twitch chat completion
local M = {}

---@class CompletionItem
---@field label string
---@field kind number
---@field detail string?
---@field documentation string?
---@field insertText string?
---@field filterText string?
---@field sortText string?
---@field additionalTextEdits table[]?
---@field data any?

---@class CompletionContext
---@field bufnr number
---@field cursor_pos number[]
---@field line_to_cursor string
---@field word_to_cursor string
---@field channel string?

---@class CompletionConfig
---@field enabled boolean
---@field commands CompletionCommandConfig
---@field users CompletionUserConfig
---@field channels CompletionChannelConfig
---@field emotes CompletionEmoteConfig

---@class CompletionCommandConfig
---@field enabled boolean
---@field trigger_chars string[]
---@field max_items number

---@class CompletionUserConfig
---@field enabled boolean
---@field trigger_chars string[]
---@field max_items number
---@field include_recent boolean
---@field recent_limit number

---@class CompletionChannelConfig
---@field enabled boolean
---@field trigger_chars string[]
---@field max_items number
---@field include_recent boolean
---@field recent_limit number

---@class CompletionEmoteConfig
---@field enabled boolean
---@field trigger_chars string[]
---@field max_items number
---@field include_global boolean
---@field include_channel boolean

local config = require('twitch-chat.config')
local utils = require('twitch-chat.utils')
local events = require('twitch-chat.events')

---@type CompletionConfig
local default_config = {
  enabled = true,
  commands = {
    enabled = true,
    trigger_chars = { '/' },
    max_items = 20,
  },
  users = {
    enabled = true,
    trigger_chars = { '@' },
    max_items = 50,
    include_recent = true,
    recent_limit = 100,
  },
  channels = {
    enabled = true,
    trigger_chars = { '#' },
    max_items = 30,
    include_recent = true,
    recent_limit = 50,
  },
  emotes = {
    enabled = true,
    trigger_chars = { ':' },
    max_items = 100,
    include_global = true,
    include_channel = true,
  },
}

-- Caches for different completion types
local completion_cache = {
  commands = {},
  users = {},
  channels = {},
  emotes = {},
  recent_users = {},
  recent_channels = {},
}

-- Twitch chat commands
local twitch_commands = {
  {
    label = '/ban',
    detail = 'Ban a user from the channel',
    documentation = 'Usage: /ban <username> [reason]',
  },
  {
    label = '/unban',
    detail = 'Unban a user from the channel',
    documentation = 'Usage: /unban <username>',
  },
  {
    label = '/timeout',
    detail = 'Timeout a user for specified duration',
    documentation = 'Usage: /timeout <username> [duration] [reason]',
  },
  {
    label = '/untimeout',
    detail = 'Remove timeout from a user',
    documentation = 'Usage: /untimeout <username>',
  },
  {
    label = '/mod',
    detail = 'Grant moderator privileges',
    documentation = 'Usage: /mod <username>',
  },
  {
    label = '/unmod',
    detail = 'Remove moderator privileges',
    documentation = 'Usage: /unmod <username>',
  },
  { label = '/vip', detail = 'Grant VIP status', documentation = 'Usage: /vip <username>' },
  { label = '/unvip', detail = 'Remove VIP status', documentation = 'Usage: /unvip <username>' },
  {
    label = '/color',
    detail = 'Change your username color',
    documentation = 'Usage: /color <color>',
  },
  { label = '/me', detail = 'Send an action message', documentation = 'Usage: /me <action>' },
  {
    label = '/whisper',
    detail = 'Send a private message',
    documentation = 'Usage: /whisper <username> <message>',
  },
  {
    label = '/w',
    detail = 'Send a private message (short)',
    documentation = 'Usage: /w <username> <message>',
  },
  { label = '/clear', detail = 'Clear the chat', documentation = 'Usage: /clear' },
  { label = '/emoteonly', detail = 'Enable emote-only mode', documentation = 'Usage: /emoteonly' },
  {
    label = '/emoteonlyoff',
    detail = 'Disable emote-only mode',
    documentation = 'Usage: /emoteonlyoff',
  },
  {
    label = '/followers',
    detail = 'Enable followers-only mode',
    documentation = 'Usage: /followers [duration]',
  },
  {
    label = '/followersoff',
    detail = 'Disable followers-only mode',
    documentation = 'Usage: /followersoff',
  },
  { label = '/slow', detail = 'Enable slow mode', documentation = 'Usage: /slow [duration]' },
  { label = '/slowoff', detail = 'Disable slow mode', documentation = 'Usage: /slowoff' },
  {
    label = '/subscribers',
    detail = 'Enable subscribers-only mode',
    documentation = 'Usage: /subscribers',
  },
  {
    label = '/subscribersoff',
    detail = 'Disable subscribers-only mode',
    documentation = 'Usage: /subscribersoff',
  },
  { label = '/host', detail = 'Host another channel', documentation = 'Usage: /host <channel>' },
  { label = '/unhost', detail = 'Stop hosting', documentation = 'Usage: /unhost' },
  { label = '/raid', detail = 'Raid another channel', documentation = 'Usage: /raid <channel>' },
  { label = '/unraid', detail = 'Cancel raid', documentation = 'Usage: /unraid' },
}

-- CMP completion kinds
local cmp_kinds = {
  COMMAND = 1,
  USER = 2,
  CHANNEL = 3,
  EMOTE = 4,
}

-- nvim-cmp integration
local cmp_source = {}

---Initialize the completion module
---@param user_config table?
---@return boolean success
function M.setup(user_config)
  if user_config then
    default_config = utils.deep_merge(default_config, user_config)
  end

  -- Check if plugin is enabled
  if not config.is_integration_enabled('cmp') then
    return false
  end

  -- Try to register with nvim-cmp
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    if config.is_debug() then
      utils.log(vim.log.levels.DEBUG, 'nvim-cmp not found, completion disabled')
    end
    return false
  end

  -- Register completion source
  cmp.register_source('twitch-chat', cmp_source)

  -- Setup event listeners for cache management
  M._setup_event_listeners()

  -- Initialize caches
  M._init_caches()

  return true
end

---Check if completion is available
---@return boolean available
function M.is_available()
  return pcall(require, 'cmp') and config.is_integration_enabled('cmp')
end

---Get completion items for current context
---@param params table nvim-cmp completion parameters
---@param callback function Callback to call with completion items
---@return nil
function cmp_source:complete(params, callback)
  local context = M._get_completion_context(params)
  if not context then
    callback()
    return
  end

  -- Only complete in Twitch chat buffers
  if not context.channel then
    callback()
    return
  end

  local items = {}

  -- Check what type of completion is needed
  if M._should_complete_commands(context) then
    vim.list_extend(items, M._get_command_completions(context))
  elseif M._should_complete_users(context) then
    vim.list_extend(items, M._get_user_completions(context))
  elseif M._should_complete_channels(context) then
    vim.list_extend(items, M._get_channel_completions(context))
  elseif M._should_complete_emotes(context) then
    vim.list_extend(items, M._get_emote_completions(context))
  end

  callback(items)
end

---Check if source is available for current buffer
---@return boolean available
function cmp_source:is_available()
  -- Only available in Twitch chat buffers
  local bufname = vim.api.nvim_buf_get_name(0)
  return bufname:match('^twitch%-chat://') ~= nil
end

---Get trigger characters for completion
---@return string[]
function cmp_source:get_trigger_characters()
  local triggers = {}

  if default_config.commands.enabled then
    vim.list_extend(triggers, default_config.commands.trigger_chars)
  end

  if default_config.users.enabled then
    vim.list_extend(triggers, default_config.users.trigger_chars)
  end

  if default_config.channels.enabled then
    vim.list_extend(triggers, default_config.channels.trigger_chars)
  end

  if default_config.emotes.enabled then
    vim.list_extend(triggers, default_config.emotes.trigger_chars)
  end

  return triggers
end

---Get completion context from cmp parameters
---@param params table nvim-cmp parameters
---@return CompletionContext?
function M._get_completion_context(params)
  local bufnr = params.context.bufnr
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local col = cursor_pos[2]

  -- Get channel from buffer name
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local channel = bufname:match('^twitch%-chat://(.+)$')

  if not channel then
    return nil
  end

  local line_to_cursor = line:sub(1, col)
  local word_to_cursor = line_to_cursor:match('%S+$') or ''

  return {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    line_to_cursor = line_to_cursor,
    word_to_cursor = word_to_cursor,
    channel = channel,
  }
end

---Check if should complete commands
---@param context CompletionContext
---@return boolean
function M._should_complete_commands(context)
  if not default_config.commands.enabled then
    return false
  end

  for _, trigger in ipairs(default_config.commands.trigger_chars) do
    if context.word_to_cursor:find('^' .. vim.pesc(trigger)) then
      return true
    end
  end

  return false
end

---Check if should complete users
---@param context CompletionContext
---@return boolean
function M._should_complete_users(context)
  if not default_config.users.enabled then
    return false
  end

  for _, trigger in ipairs(default_config.users.trigger_chars) do
    if context.word_to_cursor:find('^' .. vim.pesc(trigger)) then
      return true
    end
  end

  return false
end

---Check if should complete channels
---@param context CompletionContext
---@return boolean
function M._should_complete_channels(context)
  if not default_config.channels.enabled then
    return false
  end

  for _, trigger in ipairs(default_config.channels.trigger_chars) do
    if context.word_to_cursor:find('^' .. vim.pesc(trigger)) then
      return true
    end
  end

  return false
end

---Check if should complete emotes
---@param context CompletionContext
---@return boolean
function M._should_complete_emotes(context)
  if not default_config.emotes.enabled then
    return false
  end

  for _, trigger in ipairs(default_config.emotes.trigger_chars) do
    if context.word_to_cursor:find('^' .. vim.pesc(trigger)) then
      return true
    end
  end

  return false
end

---Get command completions
---@param context CompletionContext
---@return CompletionItem[]
function M._get_command_completions(context)
  local items = {}
  local query = context.word_to_cursor:sub(2) -- Remove trigger character

  for _, command in ipairs(twitch_commands) do
    local label = command.label:sub(2) -- Remove leading /
    if query == '' or label:lower():find(query:lower(), 1, true) then
      table.insert(items, {
        label = command.label,
        kind = cmp_kinds.COMMAND,
        detail = command.detail,
        documentation = command.documentation,
        insertText = command.label,
        filterText = label,
        sortText = string.format('%02d%s', #items, label),
      })
    end
  end

  -- Limit results
  if #items > default_config.commands.max_items then
    local limited = {}
    for i = 1, default_config.commands.max_items do
      limited[i] = items[i]
    end
    items = limited
  end

  return items
end

---Filter and combine user data from cache
---@param context CompletionContext
---@return table[] all_users Combined user data with priority
function M._get_filtered_users(context)
  -- Get users from cache
  local users = completion_cache.users[context.channel] or {}
  local recent_users = completion_cache.recent_users[context.channel] or {}

  -- Combine and deduplicate users
  local all_users = {}
  local seen = {}

  -- Add recent users first (higher priority)
  if default_config.users.include_recent then
    for _, user in ipairs(recent_users) do
      if not seen[user] then
        table.insert(all_users, { username = user, is_recent = true })
        seen[user] = true
      end
    end
  end

  -- Add regular users
  for _, user in ipairs(users) do
    if not seen[user] then
      table.insert(all_users, { username = user, is_recent = false })
      seen[user] = true
    end
  end

  return all_users
end

---Create completion items from user data
---@param all_users table[] User data array
---@param query string Search query
---@return CompletionItem[] items Completion items
function M._create_user_completion_items(all_users, query)
  local items = {}

  -- Filter and create completion items
  for _, user_data in ipairs(all_users) do
    local username = user_data.username
    if query == '' or username:lower():find(query:lower(), 1, true) then
      table.insert(items, {
        label = '@' .. username,
        kind = cmp_kinds.USER,
        detail = user_data.is_recent and 'Recent user' or 'User',
        insertText = '@' .. username,
        filterText = username,
        sortText = string.format(
          '%s%02d%s',
          user_data.is_recent and 'a' or 'b',
          #items,
          username:lower()
        ),
      })
    end
  end

  return items
end

---Get user completions
---@param context CompletionContext
---@return CompletionItem[]
function M._get_user_completions(context)
  local query = context.word_to_cursor:sub(2) -- Remove trigger character

  -- Get filtered user data
  local all_users = M._get_filtered_users(context)

  -- Create completion items
  local items = M._create_user_completion_items(all_users, query)

  -- Limit results
  if #items > default_config.users.max_items then
    local limited = {}
    for i = 1, default_config.users.max_items do
      limited[i] = items[i]
    end
    items = limited
  end

  return items
end

---Get channel completions
---@param context CompletionContext
---@return CompletionItem[]
function M._get_channel_completions(context)
  local items = {}
  local query = context.word_to_cursor:sub(2) -- Remove trigger character

  -- Get channels from cache
  local channels = completion_cache.channels
  local recent_channels = completion_cache.recent_channels

  -- Combine and deduplicate channels
  local all_channels = {}
  local seen = {}

  -- Add recent channels first (higher priority)
  if default_config.channels.include_recent then
    for _, channel in ipairs(recent_channels) do
      if not seen[channel] then
        table.insert(all_channels, { channel = channel, is_recent = true })
        seen[channel] = true
      end
    end
  end

  -- Add regular channels
  for _, channel in ipairs(channels) do
    if not seen[channel] then
      table.insert(all_channels, { channel = channel, is_recent = false })
      seen[channel] = true
    end
  end

  -- Filter and create completion items
  for _, channel_data in ipairs(all_channels) do
    local channel = channel_data.channel
    if query == '' or channel:lower():find(query:lower(), 1, true) then
      table.insert(items, {
        label = '#' .. channel,
        kind = cmp_kinds.CHANNEL,
        detail = channel_data.is_recent and 'Recent channel' or 'Channel',
        insertText = '#' .. channel,
        filterText = channel,
        sortText = string.format(
          '%s%02d%s',
          channel_data.is_recent and 'a' or 'b',
          #items,
          channel:lower()
        ),
      })
    end
  end

  -- Limit results
  if #items > default_config.channels.max_items then
    local limited = {}
    for i = 1, default_config.channels.max_items do
      limited[i] = items[i]
    end
    items = limited
  end

  return items
end

---Get and categorize emotes from cache
---@param context CompletionContext
---@return table[] all_emotes Combined emote data with type categorization
function M._get_categorized_emotes(context)
  -- Get emotes from cache
  local global_emotes = completion_cache.emotes.global or {}
  local channel_emotes = completion_cache.emotes[context.channel] or {}

  -- Combine emotes
  local all_emotes = {}

  if default_config.emotes.include_global then
    for _, emote in ipairs(global_emotes) do
      table.insert(all_emotes, { name = emote.name, type = 'global', url = emote.url })
    end
  end

  if default_config.emotes.include_channel then
    for _, emote in ipairs(channel_emotes) do
      table.insert(all_emotes, { name = emote.name, type = 'channel', url = emote.url })
    end
  end

  return all_emotes
end

---Create completion items from emote data
---@param all_emotes table[] Emote data array
---@param query string Search query
---@return CompletionItem[] items Completion items
function M._create_emote_completion_items(all_emotes, query)
  local items = {}

  -- Filter and create completion items
  for _, emote in ipairs(all_emotes) do
    if query == '' or emote.name:lower():find(query:lower(), 1, true) then
      table.insert(items, {
        label = ':' .. emote.name .. ':',
        kind = cmp_kinds.EMOTE,
        detail = emote.type == 'global' and 'Global emote' or 'Channel emote',
        insertText = emote.name,
        filterText = emote.name,
        sortText = string.format(
          '%s%02d%s',
          emote.type == 'channel' and 'a' or 'b',
          #items,
          emote.name:lower()
        ),
        data = {
          url = emote.url,
          type = emote.type,
        },
      })
    end
  end

  return items
end

---Get emote completions
---@param context CompletionContext
---@return CompletionItem[]
function M._get_emote_completions(context)
  local query = context.word_to_cursor:sub(2) -- Remove trigger character

  -- Get categorized emote data
  local all_emotes = M._get_categorized_emotes(context)

  -- Create completion items
  local items = M._create_emote_completion_items(all_emotes, query)

  -- Limit results
  if #items > default_config.emotes.max_items then
    local limited = {}
    for i = 1, default_config.emotes.max_items do
      limited[i] = items[i]
    end
    items = limited
  end

  return items
end

---Setup event listeners for cache management
---@return nil
function M._setup_event_listeners()
  -- Listen for messages to update user cache
  events.on(events.MESSAGE_RECEIVED, function(data)
    if data.username and data.channel then
      M._add_user_to_cache(data.channel, data.username)
    end
  end)

  -- Listen for channel joins to update channel cache
  events.on(events.CHANNEL_JOINED, function(data)
    if data.channel then
      M._add_channel_to_cache(data.channel)
    end
  end)

  -- Listen for user joins to update user cache
  events.on(events.USER_JOINED, function(data)
    if data.username and data.channel then
      M._add_user_to_cache(data.channel, data.username)
    end
  end)
end

---Initialize completion caches
---@return nil
function M._init_caches()
  -- Initialize empty caches
  completion_cache.commands = vim.deepcopy(twitch_commands)
  completion_cache.users = {}
  completion_cache.channels = {}
  completion_cache.emotes = {
    global = {},
  }
  completion_cache.recent_users = {}
  completion_cache.recent_channels = {}
end

---Add user to completion cache
---@param channel string
---@param username string
---@return nil
function M._add_user_to_cache(channel, username)
  -- Add to channel-specific users
  if not completion_cache.users[channel] then
    completion_cache.users[channel] = {}
  end

  local users = completion_cache.users[channel]
  if not utils.table_contains(users, username) then
    table.insert(users, username)
  end

  -- Add to recent users
  if not completion_cache.recent_users[channel] then
    completion_cache.recent_users[channel] = {}
  end

  local recent_users = completion_cache.recent_users[channel]

  -- Remove if already exists
  for i, user in ipairs(recent_users) do
    if user == username then
      table.remove(recent_users, i)
      break
    end
  end

  -- Add to front
  table.insert(recent_users, 1, username)

  -- Limit recent users
  if #recent_users > default_config.users.recent_limit then
    table.remove(recent_users)
  end
end

---Add channel to completion cache
---@param channel string
---@return nil
function M._add_channel_to_cache(channel)
  -- Add to channels
  if not utils.table_contains(completion_cache.channels, channel) then
    table.insert(completion_cache.channels, channel)
  end

  -- Add to recent channels
  local recent_channels = completion_cache.recent_channels

  -- Remove if already exists
  for i, ch in ipairs(recent_channels) do
    if ch == channel then
      table.remove(recent_channels, i)
      break
    end
  end

  -- Add to front
  table.insert(recent_channels, 1, channel)

  -- Limit recent channels
  if #recent_channels > default_config.channels.recent_limit then
    table.remove(recent_channels)
  end
end

---Add emote to completion cache
---@param channel string?
---@param emote_name string
---@param emote_url string?
---@return nil
function M.add_emote_to_cache(channel, emote_name, emote_url)
  vim.validate({
    channel = { channel, 'string', true },
    emote_name = { emote_name, 'string' },
    emote_url = { emote_url, 'string', true },
  })

  local emote = {
    name = emote_name,
    url = emote_url,
  }

  if channel then
    -- Channel-specific emote
    if not completion_cache.emotes[channel] then
      completion_cache.emotes[channel] = {}
    end

    local channel_emotes = completion_cache.emotes[channel]
    local exists = false

    for _, existing_emote in ipairs(channel_emotes) do
      if existing_emote.name == emote_name then
        exists = true
        break
      end
    end

    if not exists then
      table.insert(channel_emotes, emote)
    end
  else
    -- Global emote
    local global_emotes = completion_cache.emotes.global
    local exists = false

    for _, existing_emote in ipairs(global_emotes) do
      if existing_emote.name == emote_name then
        exists = true
        break
      end
    end

    if not exists then
      table.insert(global_emotes, emote)
    end
  end
end

---Clear completion cache
---@param cache_type string? Cache type to clear ('users', 'channels', 'emotes', 'all')
---@return nil
function M.clear_cache(cache_type)
  vim.validate({
    cache_type = { cache_type, 'string', true },
  })

  cache_type = cache_type or 'all'

  if cache_type == 'all' or cache_type == 'users' then
    completion_cache.users = {}
    completion_cache.recent_users = {}
  end

  if cache_type == 'all' or cache_type == 'channels' then
    completion_cache.channels = {}
    completion_cache.recent_channels = {}
  end

  if cache_type == 'all' or cache_type == 'emotes' then
    completion_cache.emotes = { global = {} }
  end

  if cache_type == 'all' or cache_type == 'commands' then
    completion_cache.commands = vim.deepcopy(twitch_commands)
  end
end

---Get completion cache statistics
---@return table
function M.get_cache_stats()
  local stats = {
    users = {},
    channels = #completion_cache.channels,
    recent_channels = #completion_cache.recent_channels,
    commands = #completion_cache.commands,
    emotes = {
      global = #completion_cache.emotes.global,
    },
  }

  -- Count users per channel
  for channel, users in pairs(completion_cache.users) do
    stats.users[channel] = #users
  end

  -- Count emotes per channel
  for channel, emotes in pairs(completion_cache.emotes) do
    if channel ~= 'global' then
      stats.emotes[channel] = #emotes
    end
  end

  return stats
end

return M
