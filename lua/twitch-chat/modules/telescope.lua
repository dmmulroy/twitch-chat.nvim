---@class TwitchChatTelescope
---Telescope integration for Twitch chat channel selection
local M = {}
local logger = require('twitch-chat.modules.logger')

---@class TelescopeConfig
---@field enabled boolean
---@field default_layout string
---@field layout_config table
---@field previewer_config TelescopePreviewerConfig
---@field sorter_config TelescopeSorterConfig
---@field actions TelescopeActionsConfig

---@class TelescopePreviewerConfig
---@field enabled boolean
---@field show_recent_messages boolean
---@field message_limit number
---@field show_channel_info boolean

---@class TelescopeSorterConfig
---@field enabled boolean
---@field ignore_case boolean
---@field smart_case boolean

---@class TelescopeActionsConfig
---@field select_default string
---@field select_horizontal string
---@field select_vertical string
---@field select_tab string
---@field close string
---@field preview_scrolling_up string
---@field preview_scrolling_down string

---@class ChannelInfo
---@field name string
---@field display_name string?
---@field is_connected boolean
---@field is_active boolean
---@field message_count number?
---@field last_message_time number?
---@field user_count number?
---@field recent_messages table[]?

local config = require('twitch-chat.config')
local utils = require('twitch-chat.utils')
local events = require('twitch-chat.events')
local api = require('twitch-chat.api')

---@type TelescopeConfig
local default_config = {
  enabled = true,
  default_layout = 'vertical',
  layout_config = {
    vertical = {
      width = 0.9,
      height = 0.9,
      preview_height = 0.6,
      preview_cutoff = 40,
    },
    horizontal = {
      width = 0.9,
      height = 0.9,
      preview_width = 0.6,
      preview_cutoff = 120,
    },
    center = {
      width = 0.8,
      height = 0.8,
      preview_cutoff = 40,
    },
  },
  previewer_config = {
    enabled = true,
    show_recent_messages = true,
    message_limit = 50,
    show_channel_info = true,
  },
  sorter_config = {
    enabled = true,
    ignore_case = true,
    smart_case = true,
  },
  actions = {
    select_default = '<CR>',
    select_horizontal = '<C-x>',
    select_vertical = '<C-v>',
    select_tab = '<C-t>',
    close = '<C-c>',
    preview_scrolling_up = '<C-u>',
    preview_scrolling_down = '<C-d>',
  },
}

-- Cache for channel data
local channel_cache = {}
local recent_channels = {}
local favorite_channels = {}

---Initialize the telescope module
---@param user_config table?
---@return boolean success
function M.setup(user_config)
  if user_config and type(user_config) == 'table' then
    default_config = utils.deep_merge(default_config, user_config)
  end

  -- Check if plugin is enabled
  if not config.is_integration_enabled('telescope') then
    return false
  end

  -- Try to load telescope
  local ok, telescope = pcall(require, 'telescope')
  if not ok then
    if config.is_debug() then
      utils.log(vim.log.levels.DEBUG, 'telescope.nvim not found, telescope integration disabled')
    end
    return false
  end

  -- Register telescope extensions
  telescope.register_extension({
    exports = {
      channels = M.channels,
      recent_channels = M.recent_channels,
      favorite_channels = M.favorite_channels,
      search_channels = M.search_channels,
    },
  })

  -- Setup event listeners
  M._setup_event_listeners()

  -- Initialize caches
  M._init_caches()

  return true
end

---Check if telescope is available
---@return boolean available
function M.is_available()
  return pcall(require, 'telescope') and config.is_integration_enabled('telescope')
end

---Show channel picker
---@param opts table? Telescope options
---@return nil
function M.channels(opts)
  if not M.is_available() then
    logger.warn(
      'Telescope integration not available',
      { module = 'telescope' },
      { notify = false, category = 'background_operation' }
    )
    return
  end

  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    logger.warn('Telescope pickers not available', { module = 'telescope' })
    return
  end

  local ok_f, finders = pcall(require, 'telescope.finders')
  if not ok_f then
    logger.warn('Telescope finders not available', { module = 'telescope' })
    return
  end

  local ok_a, actions = pcall(require, 'telescope.actions')
  if not ok_a then
    logger.warn('Telescope actions not available', { module = 'telescope' })
    return
  end

  local ok_s, action_state = pcall(require, 'telescope.actions.state')
  if not ok_s then
    logger.warn('Telescope action state not available', { module = 'telescope' })
    return
  end

  local ok_c, conf_module = pcall(require, 'telescope.config')
  if not ok_c then
    logger.warn('Telescope config not available', { module = 'telescope' })
    return
  end
  local conf = conf_module.values

  opts = opts or {}

  -- Get channel data
  local channels = M._get_channel_data()

  pickers
    .new(opts, {
      prompt_title = 'Twitch Chat Channels',
      finder = finders.new_table({
        results = channels,
        entry_maker = function(entry)
          return {
            value = entry,
            display = M._format_channel_entry(entry),
            ordinal = entry.name,
            path = entry.name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = M._create_channel_previewer(opts),
      attach_mappings = function(prompt_bufnr, map)
        -- Default action - join channel
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name)
          end
        end)

        -- Horizontal split
        map('i', default_config.actions.select_horizontal, function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name, 'horizontal')
          end
        end)

        -- Vertical split
        map('i', default_config.actions.select_vertical, function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name, 'vertical')
          end
        end)

        -- Tab
        map('i', default_config.actions.select_tab, function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name, 'tab')
          end
        end)

        return true
      end,
    })
    :find()
end

---Show recent channels picker
---@param opts table? Telescope options
---@return nil
function M.recent_channels(opts)
  if not M.is_available() then
    logger.warn(
      'Telescope integration not available',
      { module = 'telescope' },
      { notify = false, category = 'background_operation' }
    )
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local conf = require('telescope.config').values

  opts = opts or {}

  -- Get recent channel data
  local channels = M._get_recent_channel_data()

  if #channels == 0 then
    logger.info('No recent channels found', { module = 'telescope' })
    return
  end

  pickers
    .new(opts, {
      prompt_title = 'Recent Twitch Channels',
      finder = finders.new_table({
        results = channels,
        entry_maker = function(entry)
          return {
            value = entry,
            display = M._format_channel_entry(entry, true),
            ordinal = entry.name,
            path = entry.name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = M._create_channel_previewer(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name)
          end
        end)

        return true
      end,
    })
    :find()
end

---Show favorite channels picker
---@param opts table? Telescope options
---@return nil
function M.favorite_channels(opts)
  if not M.is_available() then
    logger.warn(
      'Telescope integration not available',
      { module = 'telescope' },
      { notify = false, category = 'background_operation' }
    )
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local conf = require('telescope.config').values

  opts = opts or {}

  -- Get favorite channel data
  local channels = M._get_favorite_channel_data()

  if #channels == 0 then
    logger.info('No favorite channels found', { module = 'telescope' })
    return
  end

  pickers
    .new(opts, {
      prompt_title = 'Favorite Twitch Channels',
      finder = finders.new_table({
        results = channels,
        entry_maker = function(entry)
          return {
            value = entry,
            display = M._format_channel_entry(entry, false, true),
            ordinal = entry.name,
            path = entry.name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = M._create_channel_previewer(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name)
          end
        end)

        return true
      end,
    })
    :find()
end

---Show channel search picker
---@param opts table? Telescope options
---@return nil
function M.search_channels(opts)
  if not M.is_available() then
    logger.warn(
      'Telescope integration not available',
      { module = 'telescope' },
      { notify = false, category = 'background_operation' }
    )
    return
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local conf = require('telescope.config').values

  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = 'Search Twitch Channels',
      finder = finders.new_dynamic({
        fn = function(prompt)
          if prompt and #prompt > 0 then
            return M._search_channels(prompt)
          end
          return {}
        end,
        entry_maker = function(entry)
          return {
            value = entry,
            display = M._format_search_result(entry),
            ordinal = entry.name,
            path = entry.name,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = M._create_search_previewer(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            M._join_channel(selection.value.name)
          end
        end)

        return true
      end,
    })
    :find()
end

---Create channel previewer
---@param opts table Telescope options
---@return table? previewer
function M._create_channel_previewer(opts)
  if not default_config.previewer_config.enabled then
    return nil
  end

  local previewers = require('telescope.previewers')

  return previewers.new_buffer_previewer({
    title = 'Channel Info',
    define_preview = function(self, entry, status)
      local channel = entry.value
      local lines = {}

      -- Channel info
      if default_config.previewer_config.show_channel_info then
        table.insert(lines, 'Channel: ' .. channel.name)

        if channel.display_name then
          table.insert(lines, 'Display Name: ' .. channel.display_name)
        end

        table.insert(lines, 'Status: ' .. (channel.is_connected and 'Connected' or 'Disconnected'))
        table.insert(lines, 'Active: ' .. (channel.is_active and 'Yes' or 'No'))

        if channel.message_count then
          table.insert(lines, 'Messages: ' .. channel.message_count)
        end

        if channel.last_message_time then
          local time_str = utils.format_timestamp(channel.last_message_time)
          table.insert(lines, 'Last Message: ' .. time_str)
        end

        if channel.user_count then
          table.insert(lines, 'Users: ' .. channel.user_count)
        end

        table.insert(lines, '')
      end

      -- Recent messages
      if default_config.previewer_config.show_recent_messages and channel.recent_messages then
        table.insert(lines, 'Recent Messages:')
        table.insert(lines, string.rep('-', 40))

        for _, message in ipairs(channel.recent_messages) do
          local timestamp = utils.format_timestamp(message.timestamp, '%H:%M:%S')
          local line = string.format('[%s] %s: %s', timestamp, message.username, message.content)
          table.insert(lines, line)
        end

        if #channel.recent_messages == 0 then
          table.insert(lines, 'No recent messages')
        end
      end

      -- Set preview content
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

      -- Set syntax highlighting
      vim.api.nvim_buf_set_option(self.state.bufnr, 'filetype', 'twitchchat')

      return status
    end,
  })
end

---Create search previewer
---@param opts table Telescope options
---@return table? previewer
function M._create_search_previewer(opts)
  if not default_config.previewer_config.enabled then
    return nil
  end

  local previewers = require('telescope.previewers')

  return previewers.new_buffer_previewer({
    title = 'Channel Preview',
    define_preview = function(self, entry, status)
      local channel = entry.value
      local lines = {}

      -- Basic info
      table.insert(lines, 'Channel: ' .. channel.name)

      if channel.display_name then
        table.insert(lines, 'Display Name: ' .. channel.display_name)
      end

      if channel.description then
        table.insert(lines, 'Description: ' .. channel.description)
      end

      if channel.followers then
        table.insert(lines, 'Followers: ' .. channel.followers)
      end

      if channel.is_live then
        table.insert(lines, 'Status: Live')
        if channel.game then
          table.insert(lines, 'Game: ' .. channel.game)
        end
        if channel.viewers then
          table.insert(lines, 'Viewers: ' .. channel.viewers)
        end
      else
        table.insert(lines, 'Status: Offline')
      end

      -- Set preview content
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

      -- Set syntax highlighting
      vim.api.nvim_buf_set_option(self.state.bufnr, 'filetype', 'twitchchat')

      return status
    end,
  })
end

---Format channel entry for display
---@param channel ChannelInfo
---@param show_recent boolean?
---@param show_favorite boolean?
---@return string
function M._format_channel_entry(channel, show_recent, show_favorite)
  local parts = {}

  -- Status indicator
  if channel.is_connected then
    table.insert(parts, '●')
  else
    table.insert(parts, '○')
  end

  -- Channel name
  table.insert(parts, channel.name)

  -- Additional info
  local info_parts = {}

  if show_recent and channel.last_message_time then
    local time_str = utils.format_timestamp(channel.last_message_time, '%H:%M')
    table.insert(info_parts, time_str)
  end

  if show_favorite then
    table.insert(info_parts, '★')
  end

  if channel.message_count then
    table.insert(info_parts, tostring(channel.message_count) .. ' msgs')
  end

  if channel.is_active then
    table.insert(info_parts, 'active')
  end

  if #info_parts > 0 then
    table.insert(parts, '(' .. table.concat(info_parts, ', ') .. ')')
  end

  return table.concat(parts, ' ')
end

---Format search result for display
---@param result table
---@return string
function M._format_search_result(result)
  local parts = {}

  -- Live indicator
  if result.is_live then
    table.insert(parts, '🔴')
  else
    table.insert(parts, '○')
  end

  -- Channel name
  table.insert(parts, result.name)

  -- Additional info
  local info_parts = {}

  if result.game then
    table.insert(info_parts, result.game)
  end

  if result.viewers then
    table.insert(info_parts, result.viewers .. ' viewers')
  end

  if result.followers then
    table.insert(info_parts, result.followers .. ' followers')
  end

  if #info_parts > 0 then
    table.insert(parts, '(' .. table.concat(info_parts, ', ') .. ')')
  end

  return table.concat(parts, ' ')
end

---Setup event listeners
---@return nil
function M._setup_event_listeners()
  -- Update channel cache when channels are joined/left
  events.on(events.CHANNEL_JOINED, function(data)
    if data.channel then
      M._update_channel_cache(data.channel, { is_connected = true })
      M._add_to_recent_channels(data.channel)
    end
  end)

  events.on(events.CHANNEL_LEFT, function(data)
    if data.channel then
      M._update_channel_cache(data.channel, { is_connected = false })
    end
  end)

  -- Update message counts and timestamps
  events.on(events.MESSAGE_RECEIVED, function(data)
    if data.channel then
      M._update_channel_cache(data.channel, {
        message_count = (
          channel_cache[data.channel] and channel_cache[data.channel].message_count or 0
        ) + 1,
        last_message_time = os.time(),
      })
      M._add_recent_message(data.channel, data)
    end
  end)
end

---Initialize caches
---@return nil
function M._init_caches()
  channel_cache = {}
  recent_channels = {}
  favorite_channels = {}

  -- Load favorites from config or file
  M._load_favorites()
end

---Get channel data for picker
---@return ChannelInfo[]
function M._get_channel_data()
  local channels = {}

  -- Get from buffer module
  local buffer_module = require('twitch-chat.modules.buffer')
  local buffers = buffer_module.get_all_buffers()

  for channel_name, buffer_data in pairs(buffers) do
    local channel_info = channel_cache[channel_name] or {}

    table.insert(channels, {
      name = channel_name,
      display_name = channel_info.display_name,
      is_connected = channel_info.is_connected or false,
      is_active = buffer_data.winid ~= nil,
      message_count = channel_info.message_count or 0,
      last_message_time = channel_info.last_message_time,
      user_count = channel_info.user_count,
      recent_messages = channel_info.recent_messages or {},
    })
  end

  -- Sort by connection status, then by recent activity
  table.sort(channels, function(a, b)
    if a.is_connected ~= b.is_connected then
      return a.is_connected
    end

    if a.is_active ~= b.is_active then
      return a.is_active
    end

    local a_time = a.last_message_time or 0
    local b_time = b.last_message_time or 0

    return a_time > b_time
  end)

  return channels
end

---Get recent channel data
---@return ChannelInfo[]
function M._get_recent_channel_data()
  local channels = {}

  for _, channel_name in ipairs(recent_channels) do
    local channel_info = channel_cache[channel_name] or {}

    table.insert(channels, {
      name = channel_name,
      display_name = channel_info.display_name,
      is_connected = channel_info.is_connected or false,
      is_active = channel_name == api.get_current_channel(),
      message_count = channel_info.message_count or 0,
      last_message_time = channel_info.last_message_time,
      user_count = channel_info.user_count,
      recent_messages = channel_info.recent_messages or {},
    })
  end

  return channels
end

---Get favorite channel data
---@return ChannelInfo[]
function M._get_favorite_channel_data()
  local channels = {}

  for _, channel_name in ipairs(favorite_channels) do
    local channel_info = channel_cache[channel_name] or {}

    table.insert(channels, {
      name = channel_name,
      display_name = channel_info.display_name,
      is_connected = channel_info.is_connected or false,
      is_active = channel_name == api.get_current_channel(),
      message_count = channel_info.message_count or 0,
      last_message_time = channel_info.last_message_time,
      user_count = channel_info.user_count,
      recent_messages = channel_info.recent_messages or {},
    })
  end

  return channels
end

---Search channels using Twitch Helix API
---@param query string Search query
---@return table[] channels Array of channel results
function M._search_channels(query)
  local auth = require('twitch-chat.modules.auth')
  local curl = require('plenary.curl')
  local results = {}

  -- Check if we have authentication
  if not auth.is_authenticated() then
    utils.log(vim.log.levels.WARN, 'Cannot search channels: not authenticated')
    return results
  end

  local access_token = auth.get_access_token()
  if not access_token then
    utils.log(vim.log.levels.WARN, 'Cannot search channels: no access token')
    return results
  end

  -- Search for channels
  local search_url = string.format(
    'https://api.twitch.tv/helix/search/channels?query=%s&first=20',
    vim.uri_encode(query)
  )

  -- This needs to be synchronous for telescope picker
  local response = curl.get(search_url, {
    headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
      ['Client-Id'] = auth.config and auth.config.client_id or config.get('auth.client_id') or '',
    },
    timeout = 5000,
  })

  if response.status == 200 then
    local success, data = pcall(vim.json.decode, response.body)
    if success and data and data.data then
      for _, channel_data in ipairs(data.data) do
        table.insert(results, {
          name = channel_data.broadcaster_login,
          display_name = channel_data.display_name,
          description = channel_data.title or '',
          is_live = channel_data.is_live or false,
          game = channel_data.game_name,
          viewers = channel_data.viewer_count or 0,
          language = channel_data.broadcaster_language,
          started_at = channel_data.started_at,
          thumbnail_url = channel_data.thumbnail_url,
        })
      end

      utils.log(
        vim.log.levels.INFO,
        string.format('Found %d channels for query: %s', #results, query)
      )
    else
      utils.log(vim.log.levels.ERROR, 'Failed to parse channel search response')
    end
  else
    utils.log(vim.log.levels.ERROR, string.format('Failed to search channels: %d', response.status))
  end

  return results
end

---Join a channel
---@param channel string
---@param layout string?
---@return nil
function M._join_channel(channel, layout)
  -- Emit channel join event
  events.emit(events.CHANNEL_JOINED, { channel = channel })

  -- Show channel with specified layout
  if layout then
    local ui_module = require('twitch-chat.modules.ui')
    if ui_module then
      ui_module.show_buffer(channel, layout)
    end
  end

  logger.info(
    'Joined channel',
    { channel = channel, module = 'telescope' },
    { notify = true, category = 'user_action' }
  )
end

---Update channel cache
---@param channel string
---@param data table
---@return nil
function M._update_channel_cache(channel, data)
  if not channel_cache[channel] then
    channel_cache[channel] = {
      recent_messages = {},
    }
  end

  for key, value in pairs(data) do
    channel_cache[channel][key] = value
  end
end

---Add channel to recent channels
---@param channel string
---@return nil
function M._add_to_recent_channels(channel)
  -- Remove if already exists
  for i, ch in ipairs(recent_channels) do
    if ch == channel then
      table.remove(recent_channels, i)
      break
    end
  end

  -- Add to front
  table.insert(recent_channels, 1, channel)

  -- Limit to 20 recent channels
  if #recent_channels > 20 then
    table.remove(recent_channels)
  end
end

---Add recent message to channel cache
---@param channel string
---@param message table
---@return nil
function M._add_recent_message(channel, message)
  if not channel_cache[channel] then
    channel_cache[channel] = {
      recent_messages = {},
    }
  end

  local messages = channel_cache[channel].recent_messages
  table.insert(messages, 1, {
    username = message.username,
    content = message.content,
    timestamp = message.timestamp or os.time(),
  })

  -- Limit to configured number of messages
  local limit = default_config.previewer_config.message_limit
  if #messages > limit then
    for i = #messages, limit + 1, -1 do
      table.remove(messages, i)
    end
  end
end

---Load favorite channels
---@return nil
function M._load_favorites()
  -- Try to load from config
  local favorites_config = config.get('telescope.favorites')
  if favorites_config then
    favorite_channels = favorites_config
    return
  end

  -- Try to load from file
  local favorites_file = vim.fn.stdpath('cache') .. '/twitch-chat/favorites.json'
  if utils.file_exists(favorites_file) then
    local content = utils.read_file(favorites_file)
    if content then
      local success, favorites = pcall(vim.fn.json_decode, content)
      if success and type(favorites) == 'table' then
        favorite_channels = favorites
      end
    end
  end
end

---Save favorite channels
---@return nil
function M._save_favorites()
  local favorites_file = vim.fn.stdpath('cache') .. '/twitch-chat/favorites.json'
  local content = vim.fn.json_encode(favorite_channels)
  utils.write_file(favorites_file, content)
end

---Add channel to favorites
---@param channel string
---@return nil
function M.add_favorite(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  if not utils.table_contains(favorite_channels, channel) then
    table.insert(favorite_channels, channel)
    M._save_favorites()
    logger.info('Added channel to favorites', { channel = channel, module = 'telescope' })
  else
    logger.warn('Channel already in favorites', { channel = channel, module = 'telescope' })
  end
end

---Remove channel from favorites
---@param channel string
---@return nil
function M.remove_favorite(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  for i, ch in ipairs(favorite_channels) do
    if ch == channel then
      table.remove(favorite_channels, i)
      M._save_favorites()
      logger.info('Removed channel from favorites', { channel = channel, module = 'telescope' })
      return
    end
  end

  logger.warn('Channel not in favorites', { channel = channel, module = 'telescope' })
end

---Check if channel is in favorites
---@param channel string
---@return boolean
function M.is_favorite(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  return utils.table_contains(favorite_channels, channel)
end

---Get all favorite channels
---@return string[]
function M.get_favorites()
  return vim.deepcopy(favorite_channels)
end

---Get all recent channels
---@return string[]
function M.get_recent_channels()
  return vim.deepcopy(recent_channels)
end

---Clear recent channels
---@return nil
function M.clear_recent_channels()
  recent_channels = {}
  logger.info('Cleared recent channels', { module = 'telescope' })
end

---Get telescope cache statistics
---@return table
function M.get_cache_stats()
  return {
    cached_channels = utils.table_length(channel_cache),
    recent_channels = #recent_channels,
    favorite_channels = #favorite_channels,
    total_recent_messages = vim.tbl_map(function(ch)
      return ch.recent_messages and #ch.recent_messages or 0
    end, channel_cache),
  }
end

return M
