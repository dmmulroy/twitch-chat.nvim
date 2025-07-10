---@class TwitchChatCommands
local M = {}
local logger = require('twitch-chat.modules.logger')

local utils = require('twitch-chat.utils')
local config = require('twitch-chat.config')
local health = require('twitch-chat.health')

---@class CommandDefinition
---@field name string Command name
---@field func function Command function
---@field opts table Command options
---@field desc string Command description

---List of all command definitions
---@type CommandDefinition[]
local commands = {}

---Setup all plugin commands
---@return nil
function M.setup()
  -- Register all commands
  M.register_command('TwitchChat', M.cmd_twitch_chat, {
    desc = 'Open Twitch chat interface',
    nargs = '?',
    complete = M.complete_channel,
  })

  M.register_command('TwitchConnect', M.cmd_twitch_connect, {
    desc = 'Connect to a Twitch channel',
    nargs = 1,
    complete = M.complete_channel,
  })

  M.register_command('TwitchDisconnect', M.cmd_twitch_disconnect, {
    desc = 'Disconnect from a Twitch channel',
    nargs = '?',
    complete = M.complete_connected_channel,
  })

  M.register_command('TwitchSend', M.cmd_twitch_send, {
    desc = 'Send a message to current channel',
    nargs = '+',
  })

  M.register_command('TwitchAuth', M.cmd_twitch_auth, {
    desc = 'Authenticate with Twitch',
    nargs = '?',
  })

  M.register_command('TwitchStatus', M.cmd_twitch_status, {
    desc = 'Show connection status',
    nargs = 0,
  })

  M.register_command('TwitchChannels', M.cmd_twitch_channels, {
    desc = 'List connected channels',
    nargs = 0,
  })

  M.register_command('TwitchHealth', M.cmd_twitch_health, {
    desc = 'Run health checks',
    nargs = 0,
  })

  M.register_command('TwitchConfig', M.cmd_twitch_config, {
    desc = 'Show or edit configuration',
    nargs = '*',
    complete = M.complete_config_path,
  })

  M.register_command('TwitchReload', M.cmd_twitch_reload, {
    desc = 'Reload the plugin',
    nargs = 0,
  })

  M.register_command('TwitchHelp', M.cmd_twitch_help, {
    desc = 'Show help information',
    nargs = '?',
    complete = M.complete_help_topic,
  })

  M.register_command('TwitchEmote', M.cmd_twitch_emote, {
    desc = 'Insert or browse emotes',
    nargs = '?',
    complete = M.complete_emote,
  })

  M.register_command('TwitchFilter', M.cmd_twitch_filter, {
    desc = 'Manage message filters',
    nargs = '+',
    complete = M.complete_filter_action,
  })

  M.register_command('TwitchLog', M.cmd_twitch_log, {
    desc = 'View plugin logs',
    nargs = '?',
  })

  -- Enhanced logging commands
  M.register_command('TwitchLogLevel', M.cmd_twitch_log_level, {
    desc = 'Set or show log level (DEBUG, INFO, WARN, ERROR)',
    nargs = '?',
    complete = M.complete_log_level,
  })

  M.register_command('TwitchLogStats', M.cmd_twitch_log_stats, {
    desc = 'Show logging statistics',
    nargs = 0,
  })

  M.register_command('TwitchLogFlush', M.cmd_twitch_log_flush, {
    desc = 'Flush log buffer to file',
    nargs = 0,
  })

  M.register_command('TwitchLogModule', M.cmd_twitch_log_module, {
    desc = 'Enable/disable logging for specific module',
    nargs = 2,
    complete = M.complete_log_module,
  })

  M.register_command('TwitchBufferStats', M.cmd_twitch_buffer_stats, {
    desc = 'Show buffer statistics with memory and deduplication info',
    nargs = '?',
    complete = M.complete_connected_channel,
  })

  M.register_command('TwitchNotify', M.cmd_twitch_notify, {
    desc = 'Configure notification settings',
    nargs = '*',
    complete = M.complete_notify_config,
  })
end

---Register a command
---@param name string Command name
---@param func function Command function
---@param opts table Command options
---@return nil
function M.register_command(name, func, opts)
  vim.validate({
    name = { name, 'string' },
    func = { func, 'function' },
    opts = { opts, 'table' },
  })

  opts = opts or {}

  -- Create command definition
  local cmd_def = {
    name = name,
    func = func,
    opts = opts,
    desc = opts.desc or '',
  }

  table.insert(commands, cmd_def)

  -- Register with Neovim
  vim.api.nvim_create_user_command(name, function(cmd_opts)
    local success, err = pcall(func, cmd_opts)
    if not success then
      vim.notify(
        string.format('Error in command %s: %s', name, err),
        vim.log.levels.ERROR,
        { title = 'TwitchChat' }
      )
    end
  end, opts)
end

---Main TwitchChat command
---@param opts table Command options
---@return nil
function M.cmd_twitch_chat(opts)
  local channel = opts.args or ''

  if channel == '' then
    channel = config.get('chat.default_channel')
  end

  if channel == '' then
    -- Show channel picker if no channel specified
    M.show_channel_picker()
  else
    -- Connect to specified channel
    local api = require('twitch-chat.api')
    api.connect(channel)
  end
end

---Connect to channel command
---@param opts table Command options
---@return nil
function M.cmd_twitch_connect(opts)
  local channel = opts.args

  if not channel or channel == '' then
    logger.error('Channel name is required', {}, { notify = true, category = 'user_action' })
    return
  end

  if not utils.is_valid_channel(channel) then
    logger.error('Invalid channel name format', {}, { notify = true, category = 'user_action' })
    return
  end

  local api = require('twitch-chat.api')
  api.connect(channel)
end

---Disconnect from channel command
---@param opts table Command options
---@return nil
function M.cmd_twitch_disconnect(opts)
  local channel = opts.args

  if not channel or channel == '' then
    -- Disconnect from current channel
    local api = require('twitch-chat.api')
    local current_channel = api.get_current_channel()
    if current_channel then
      api.disconnect(current_channel)
    else
      vim.notify('No active channel to disconnect from', vim.log.levels.WARN)
    end
  else
    local api = require('twitch-chat.api')
    api.disconnect(channel)
  end
end

---Send message command
---@param opts table Command options
---@return nil
function M.cmd_twitch_send(opts)
  local message = opts.args

  if not message or message == '' then
    vim.notify('Message is required', vim.log.levels.ERROR)
    return
  end

  local api = require('twitch-chat.api')
  local current_channel = api.get_current_channel()

  if not current_channel then
    vim.notify('No active channel. Connect to a channel first', vim.log.levels.ERROR)
    return
  end

  api.send_message(current_channel, message)
end

---Authentication command
---@param opts table Command options
---@return nil
function M.cmd_twitch_auth(opts)
  local action = opts.args or 'login'

  local auth = require('twitch-chat.modules.auth')

  if action == 'login' then
    auth.login()
  elseif action == 'logout' then
    auth.logout()
  elseif action == 'refresh' then
    auth.refresh_token()
  elseif action == 'status' then
    auth.check_status()
  else
    vim.notify('Invalid auth action. Use: login, logout, refresh, or status', vim.log.levels.ERROR)
  end
end

---Status command
---@param opts table Command options
---@return nil
function M.cmd_twitch_status(opts)
  local api = require('twitch-chat.api')
  local status = api.get_status()

  local lines = {
    'TwitchChat Status:',
    '',
    string.format('  Plugin enabled: %s', status.enabled and 'Yes' or 'No'),
    string.format('  Connected channels: %d', #status.channels),
    string.format('  Authentication: %s', status.authenticated and 'Yes' or 'No'),
    string.format('  Debug mode: %s', status.debug and 'Yes' or 'No'),
    '',
    'Connected channels:',
  }

  for _, channel in ipairs(status.channels) do
    table.insert(lines, string.format('  - %s (%s)', channel.name, channel.status))
  end

  M.show_info_buffer('TwitchChat Status', lines)
end

---Channels command
---@param opts table Command options
---@return nil
function M.cmd_twitch_channels(opts)
  local api = require('twitch-chat.api')
  local channels = api.get_channels()

  if #channels == 0 then
    vim.notify('No connected channels', vim.log.levels.INFO)
    return
  end

  local lines = {
    'Connected Channels:',
    '',
  }

  for _, channel in ipairs(channels) do
    table.insert(
      lines,
      string.format('  %s - %s (%d messages)', channel.name, channel.status, channel.message_count)
    )
  end

  M.show_info_buffer('TwitchChat Channels', lines)
end

---Health check command
---@param opts table Command options
---@return nil
function M.cmd_twitch_health(opts)
  health.run_health_check()
end

---Configuration command
---@param opts table Command options
---@return nil
function M.cmd_twitch_config(opts)
  local args = utils.split(opts.args or '', ' ')

  if #args == 0 then
    -- Show current configuration
    M.show_config()
  elseif #args == 1 then
    -- Show specific config value
    local value = config.get(args[1])
    if value ~= nil then
      vim.notify(string.format('%s = %s', args[1], vim.inspect(value)), vim.log.levels.INFO)
    else
      vim.notify(string.format('Configuration key not found: %s', args[1]), vim.log.levels.ERROR)
    end
  elseif #args == 2 then
    -- Set config value
    local key, value = args[1], args[2]

    -- Try to parse value as JSON
    local parsed_value ---@type string|number|boolean|table
    parsed_value = value
    local success, json_value = pcall(vim.fn.json_decode, value)
    if success and json_value ~= nil then
      -- Type assertion for json_value from vim.fn.json_decode
      ---@cast json_value any
      -- Ensure proper type handling for decoded JSON values
      local json_type = type(json_value)
      if json_type == 'number' then
        ---@cast json_value number
        parsed_value = json_value
      elseif json_type == 'boolean' then
        ---@cast json_value boolean
        parsed_value = json_value
      elseif json_type == 'table' then
        ---@cast json_value table
        parsed_value = json_value
      else
        -- Convert to string if it's not a supported type
        parsed_value = tostring(json_value)
      end
    end

    config.set(key, parsed_value)
    vim.notify(string.format('Set %s = %s', key, vim.inspect(parsed_value)), vim.log.levels.INFO)
  else
    vim.notify('Usage: TwitchConfig [key] [value]', vim.log.levels.ERROR)
  end
end

---Reload command
---@param opts table Command options
---@return nil
function M.cmd_twitch_reload(opts)
  local api = require('twitch-chat.api')
  api.reload()
  logger.info('TwitchChat plugin reloaded', {}, { notify = true, category = 'user_action' })
end

---Help command
---@param opts table Command options
---@return nil
function M.cmd_twitch_help(opts)
  local topic = opts.args or ''

  if topic == '' then
    M.show_general_help()
  else
    M.show_help_topic(topic)
  end
end

---Emote command
---@param opts table Command options
---@return nil
function M.cmd_twitch_emote(opts)
  local emote_name = opts.args or ''

  if emote_name == '' then
    -- Show emote picker
    M.show_emote_picker()
  else
    -- Insert specific emote
    local api = require('twitch-chat.api')
    api.insert_emote(emote_name)
  end
end

---Filter command
---@param opts table Command options
---@return nil
function M.cmd_twitch_filter(opts)
  local args = utils.split(opts.args or '', ' ')

  if #args < 1 then
    vim.notify('Usage: TwitchFilter <action> [arguments]', vim.log.levels.ERROR)
    return
  end

  local action = args[1]
  local filter_module = require('twitch-chat.modules.filter')

  if action == 'add' and #args >= 3 then
    local filter_type = args[2]
    local pattern = table.concat(args, ' ', 3)
    filter_module.add_filter(filter_type, pattern)
  elseif action == 'remove' and #args >= 3 then
    local filter_type = args[2]
    local pattern = table.concat(args, ' ', 3)
    filter_module.remove_filter(filter_type, pattern)
  elseif action == 'list' then
    filter_module.list_filters()
  elseif action == 'clear' then
    filter_module.clear_filters()
  else
    vim.notify('Invalid filter action. Use: add, remove, list, or clear', vim.log.levels.ERROR)
  end
end

---Log command
---@param opts table Command options
---@return nil
function M.cmd_twitch_log(opts)
  local _ = opts.args or 'all' -- Prefix with _ to indicate intentionally unused

  -- Implementation would depend on logging system
  vim.notify('Log viewing not implemented yet', vim.log.levels.INFO)
end

-- Completion functions

---Complete channel names
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_channel(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  -- This would typically fetch from recent channels or favorites
  local channels = { 'shroud', 'ninja', 'pokimane', 'xqc', 'sodapoppin' }

  if arg_lead == '' then
    return channels
  end

  local matches = {}
  for _, channel in ipairs(channels) do
    if channel:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, channel)
    end
  end

  return matches
end

---Complete connected channel names
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_connected_channel(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  local api = require('twitch-chat.api')
  local channels = api.get_channels()
  local channel_names = {}

  for _, channel in ipairs(channels) do
    table.insert(channel_names, channel.name)
  end

  if arg_lead == '' then
    return channel_names
  end

  local matches = {}
  for _, channel in ipairs(channel_names) do
    if channel:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, channel)
    end
  end

  return matches
end

---Complete configuration paths
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_config_path(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  local config_paths = {
    'enabled',
    'debug',
    'auth.client_id',
    'auth.redirect_uri',
    'auth.token_file',
    'ui.width',
    'ui.height',
    'ui.position',
    'ui.border',
    'chat.default_channel',
    'chat.reconnect_delay',
    'integrations.telescope',
    'integrations.cmp',
    'filters.enable_filters',
    'filters.filter_commands',
  }

  if arg_lead == '' then
    return config_paths
  end

  local matches = {}
  for _, path in ipairs(config_paths) do
    if path:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, path)
    end
  end

  return matches
end

---Complete help topics
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_help_topic(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  local topics = {
    'commands',
    'configuration',
    'authentication',
    'keymaps',
    'integrations',
    'filters',
    'emotes',
    'troubleshooting',
  }

  if arg_lead == '' then
    return topics
  end

  local matches = {}
  for _, topic in ipairs(topics) do
    if topic:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, topic)
    end
  end

  return matches
end

---Complete emote names
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_emote(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  -- This would typically fetch from emote cache
  local emotes = { 'Kappa', 'PogChamp', 'LUL', 'EZ', 'Jebaited' }

  if arg_lead == '' then
    return emotes
  end

  local matches = {}
  for _, emote in ipairs(emotes) do
    if emote:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, emote)
    end
  end

  return matches
end

---Complete filter actions
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_filter_action(arg_lead, cmd_line, cursor_pos)
  vim.validate({
    arg_lead = { arg_lead, 'string' },
    cmd_line = { cmd_line, 'string' },
    cursor_pos = { cursor_pos, 'number' },
  })
  local actions = { 'add', 'remove', 'list', 'clear' }
  local filter_types = { 'block_pattern', 'allow_pattern', 'block_user', 'allow_user' }

  local args = utils.split(cmd_line, ' ')

  if #args <= 2 then
    -- Complete action
    if arg_lead == '' then
      return actions
    end

    local matches = {}
    for _, action in ipairs(actions) do
      if action:lower():find(arg_lead:lower(), 1, true) then
        table.insert(matches, action)
      end
    end

    return matches
  elseif #args == 3 then
    -- Complete filter type
    if arg_lead == '' then
      return filter_types
    end

    local matches = {}
    for _, filter_type in ipairs(filter_types) do
      if filter_type:lower():find(arg_lead:lower(), 1, true) then
        table.insert(matches, filter_type)
      end
    end

    return matches
  end

  return {}
end

-- Helper functions

---Show channel picker
---@return nil
function M.show_channel_picker()
  if config.is_integration_enabled('telescope') then
    local _ = require('telescope') -- Will be used in future implementation
    -- Implementation would use telescope picker
    vim.notify('Telescope channel picker not implemented yet', vim.log.levels.INFO)
  else
    vim.ui.input({ prompt = 'Enter channel name: ' }, function(input)
      if input and input ~= '' then
        local api = require('twitch-chat.api')
        api.connect(input)
      end
    end)
  end
end

---Show emote picker
---@return nil
function M.show_emote_picker()
  if config.is_integration_enabled('telescope') then
    local _ = require('telescope') -- Will be used in future implementation
    -- Implementation would use telescope picker
    vim.notify('Telescope emote picker not implemented yet', vim.log.levels.INFO)
  else
    vim.notify('Emote picker requires telescope integration', vim.log.levels.WARN)
  end
end

---Show configuration in buffer
---@return nil
function M.show_config()
  local config_lines = {
    'TwitchChat Configuration:',
    '',
    vim.inspect(config.options),
  }

  M.show_info_buffer('TwitchChat Configuration', config_lines)
end

---Show general help
---@return nil
function M.show_general_help()
  local help_lines = {
    'TwitchChat Help',
    '===============',
    '',
    'Commands:',
    '  :TwitchChat [channel]     - Open chat interface',
    '  :TwitchConnect <channel>  - Connect to channel',
    '  :TwitchDisconnect [channel] - Disconnect from channel',
    '  :TwitchSend <message>     - Send message',
    '  :TwitchAuth [action]      - Authentication',
    '  :TwitchStatus             - Show status',
    '  :TwitchChannels           - List channels',
    '  :TwitchHealth             - Health check',
    '  :TwitchConfig [key] [val] - Configuration',
    '  :TwitchReload             - Reload plugin',
    '  :TwitchHelp [topic]       - Show help',
    '  :TwitchEmote [name]       - Insert emote',
    '  :TwitchFilter <action>    - Manage filters',
    '  :TwitchLog [level]        - View logs',
    '',
    'For more help: :TwitchHelp <topic>',
  }

  M.show_info_buffer('TwitchChat Help', help_lines)
end

---Show help for specific topic
---@param topic string Help topic
---@return nil
function M.show_help_topic(topic)
  local help_topics = {
    commands = 'Commands help not implemented yet',
    configuration = 'Configuration help not implemented yet',
    authentication = 'Authentication help not implemented yet',
    keymaps = 'Keymaps help not implemented yet',
    integrations = 'Integrations help not implemented yet',
    filters = 'Filters help not implemented yet',
    emotes = 'Emotes help not implemented yet',
    troubleshooting = 'Troubleshooting help not implemented yet',
  }

  local help_text = help_topics[topic]
  if help_text then
    vim.notify(help_text, vim.log.levels.INFO)
  else
    vim.notify(string.format('Help topic not found: %s', topic), vim.log.levels.ERROR)
  end
end

---Show information in a buffer
---@param title string Buffer title
---@param lines string[] Buffer content lines
---@return nil
function M.show_info_buffer(title, lines)
  vim.validate({
    title = { title, 'string' },
    lines = { lines, 'table' },
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_name(bufnr, title)

  -- Open in a split
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, bufnr)

  -- Set up buffer keymaps
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', ':q<CR>', { noremap = true, silent = true })
end

---Get all registered commands
---@return CommandDefinition[] commands
function M.get_commands()
  return vim.deepcopy(commands)
end

---Unregister all commands
---@return nil
function M.cleanup()
  for _, cmd in ipairs(commands) do
    pcall(vim.api.nvim_del_user_command, cmd.name)
  end

  commands = {}
end

-- Enhanced Logging Commands

---Set or show log level
---@param opts table Command options
function M.cmd_twitch_log_level(opts)
  local logger = require('twitch-chat.modules.logger')

  if opts.args == '' then
    -- Show current log level
    local stats = logger.get_stats()
    vim.notify('Current log level: ' .. (stats.config.level or 'Unknown'), vim.log.levels.INFO)
    return
  end

  local level = opts.args:upper()
  local valid_levels = { 'DEBUG', 'INFO', 'WARN', 'ERROR' }

  if not vim.tbl_contains(valid_levels, level) then
    vim.notify(
      'Invalid log level. Valid levels: ' .. table.concat(valid_levels, ', '),
      vim.log.levels.ERROR
    )
    return
  end

  logger.set_level(level)
  vim.notify('Log level set to: ' .. level, vim.log.levels.INFO)
end

---Show logging statistics
---@param opts table Command options
function M.cmd_twitch_log_stats(opts)
  local logger = require('twitch-chat.modules.logger')
  local stats = logger.get_stats()

  local info_lines = {
    'TwitchChat Logging Statistics',
    '═══════════════════════════════',
    '',
    'Session ID: ' .. (stats.session_id or 'Unknown'),
    'Current Level: ' .. (stats.config.level or 'Unknown'),
    'Buffer Size: ' .. (stats.buffer_size or 0) .. ' entries',
    'Active Timers: ' .. (stats.active_timers or 0),
    'File Logging: ' .. (stats.config.file_logging and 'Enabled' or 'Disabled'),
    'Log File: ' .. (stats.config.file_path or 'None'),
    'Correlation Counter: ' .. (stats.correlation_counter or 0),
    '',
    'Use :TwitchLogFlush to flush buffered logs to file',
    'Use :TwitchLogLevel <level> to change log level',
  }

  M.show_info_buffer('TwitchChat Log Statistics', info_lines)
end

---Flush log buffer to file
---@param opts table Command options
function M.cmd_twitch_log_flush(opts)
  local logger = require('twitch-chat.modules.logger')
  logger.flush()
  vim.notify('Log buffer flushed to file', vim.log.levels.INFO)
end

---Enable/disable logging for specific module
---@param opts table Command options
function M.cmd_twitch_log_module(opts)
  local args = vim.split(opts.args, ' ', { plain = true })
  if #args < 2 then
    vim.notify('Usage: TwitchLogModule <module_name> <enable|disable>', vim.log.levels.ERROR)
    return
  end

  local module_name = args[1]
  local action = args[2]:lower()

  if action ~= 'enable' and action ~= 'disable' then
    vim.notify('Action must be "enable" or "disable"', vim.log.levels.ERROR)
    return
  end

  local logger = require('twitch-chat.modules.logger')
  local enabled = action == 'enable'

  logger.set_module_filter(module_name, enabled)
  vim.notify(
    string.format('Logging %s for module: %s', action .. 'd', module_name),
    vim.log.levels.INFO
  )
end

-- Completion functions for logging commands

---Complete log levels
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_log_level(arg_lead, cmd_line, cursor_pos)
  local levels = { 'DEBUG', 'INFO', 'WARN', 'ERROR' }

  if arg_lead == '' then
    return levels
  end

  local matches = {}
  for _, level in ipairs(levels) do
    if level:lower():find(arg_lead:lower(), 1, true) then
      table.insert(matches, level)
    end
  end

  return matches
end

---Complete module names and actions for log module command
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_log_module(arg_lead, cmd_line, cursor_pos)
  local args = vim.split(cmd_line, ' ', { plain = true })

  if #args <= 2 then
    -- Complete module names
    local modules = {
      'api',
      'auth',
      'buffer',
      'circuit_breaker',
      'completion',
      'config',
      'connection_monitor',
      'display',
      'emotes',
      'events',
      'filter',
      'formatter',
      'health',
      'irc',
      'logger',
      'telescope',
      'ui',
      'utils',
      'websocket',
    }

    if arg_lead == '' then
      return modules
    end

    local matches = {}
    for _, module in ipairs(modules) do
      if module:find(arg_lead, 1, true) then
        table.insert(matches, module)
      end
    end

    return matches
  elseif #args == 3 then
    -- Complete enable/disable
    local actions = { 'enable', 'disable' }

    if arg_lead == '' then
      return actions
    end

    local matches = {}
    for _, action in ipairs(actions) do
      if action:find(arg_lead:lower(), 1, true) then
        table.insert(matches, action)
      end
    end

    return matches
  end

  return {}
end

---Show buffer statistics command
---@param opts table Command options
function M.cmd_twitch_buffer_stats(opts)
  local channel = opts.args
  local buffer_module = require('twitch-chat.modules.buffer')

  if not channel or channel == '' then
    -- Show overall performance stats
    local stats = buffer_module.get_performance_stats()

    local info_lines = {
      'TwitchChat Buffer Performance Statistics',
      '════════════════════════════════════════',
      '',
      string.format('Total Buffers: %d', stats.total_buffers),
      string.format('Total Messages in Memory: %d', stats.total_messages),
      string.format('Total Pending Updates: %d', stats.total_pending),
      string.format('Average Update Time: %.2f ms', stats.average_update_time),
      '',
      'Memory & Compression:',
      string.format('  Total Memory Usage: %.2f MB', stats.total_memory_usage_mb),
      string.format('  Total Cached Messages: %d', stats.total_cached_messages),
      string.format('  Total Messages Received: %d', stats.total_messages_received),
      string.format('  Average Compression Ratio: %.2f%%', stats.average_compression_ratio * 100),
      '',
      'Deduplication:',
      string.format('  Duplicates Detected: %d', stats.total_duplicates_detected),
      string.format('  Average Deduplication Rate: %.2f%%', stats.average_deduplication_rate * 100),
      string.format('  Hash Map Entries: %d', stats.total_hash_map_entries),
    }

    M.show_info_buffer('TwitchChat Buffer Statistics', info_lines)
  else
    -- Show stats for specific channel
    local stats = buffer_module.get_buffer_stats(channel)

    if not stats then
      vim.notify('No buffer found for channel: ' .. channel, vim.log.levels.ERROR)
      return
    end

    local info_lines = {
      'Buffer Statistics for ' .. channel,
      '═══════════════════════════════════',
      '',
      string.format('Buffer Number: %d', stats.buffer_number),
      string.format('Window ID: %s', stats.window_id or 'None'),
      string.format('Messages in Buffer: %d', stats.message_count),
      string.format('Pending Updates: %d', stats.pending_count),
      string.format('Last Update Time: %.2f ms', stats.last_update_time),
      string.format('Auto-scroll: %s', stats.auto_scroll and 'Enabled' or 'Disabled'),
      '',
      'Virtualization & Compression:',
      string.format(
        '  Virtualization: %s',
        stats.virtualization_enabled and 'Enabled' or 'Disabled'
      ),
      string.format('  Total Messages Received: %d', stats.total_messages_received),
      string.format('  Cached Messages: %d', stats.cached_messages),
      string.format('  Memory Usage: %.2f MB', stats.memory_usage_mb),
      string.format('  Compression Ratio: %.2f%%', stats.compression_ratio * 100),
      '',
      'Deduplication:',
      string.format('  Duplicates Detected: %d', stats.duplicate_count),
      string.format('  Deduplication Rate: %.2f%%', stats.deduplication_rate * 100),
      string.format('  Hash Map Size: %d entries', stats.hash_map_size),
    }

    M.show_info_buffer('Buffer Statistics - ' .. channel, info_lines)
  end
end

---Notification configuration command
---@param opts table Command options
function M.cmd_twitch_notify(opts)
  local args = vim.split(opts.args, ' ', { plain = true, trimempty = true })
  local logger = require('twitch-chat.modules.logger')

  if #args == 0 then
    -- Show current notification config
    local config = logger.get_notification_config()
    local info_lines = {
      'TwitchChat Notification Configuration',
      '═══════════════════════════════════════',
      '',
      'Enabled: ' .. (config.enabled and 'Yes' or 'No'),
      '',
      'Levels:',
      '  DEBUG: ' .. (config.levels.DEBUG and 'Yes' or 'No'),
      '  INFO: ' .. (config.levels.INFO and 'Yes' or 'No'),
      '  WARN: ' .. (config.levels.WARN and 'Yes' or 'No'),
      '  ERROR: ' .. (config.levels.ERROR and 'Yes' or 'No'),
      '',
      'Categories:',
      '  user_action: ' .. (config.categories.user_action and 'Yes' or 'No'),
      '  system_status: ' .. (config.categories.system_status and 'Yes' or 'No'),
      '  background_operation: ' .. (config.categories.background_operation and 'Yes' or 'No'),
      '  debug_info: ' .. (config.categories.debug_info and 'Yes' or 'No'),
      '  performance: ' .. (config.categories.performance and 'Yes' or 'No'),
      '',
      'Rate Limiting:',
      '  Enabled: ' .. (config.rate_limit.enabled and 'Yes' or 'No'),
      '  Max per second: ' .. config.rate_limit.max_per_second,
      '  Burst allowance: ' .. config.rate_limit.burst_allowance,
    }
    M.show_info_buffer('TwitchChat Notifications', info_lines)
  elseif #args == 2 then
    -- Enable/disable notifications
    local category = args[1]
    local value = args[2]:lower()

    if category == 'enabled' then
      if value == 'true' or value == 'yes' or value == 'on' then
        logger.configure_notifications({ enabled = true })
        logger.info('Notifications enabled', {}, { notify = true, category = 'user_action' })
      elseif value == 'false' or value == 'no' or value == 'off' then
        logger.configure_notifications({ enabled = false })
        logger.info('Notifications disabled', {}, { notify = false, category = 'user_action' })
      else
        logger.error(
          'Invalid value for enabled. Use: true/false, yes/no, on/off',
          {},
          { notify = true, category = 'user_action' }
        )
      end
    elseif vim.tbl_contains({ 'DEBUG', 'INFO', 'WARN', 'ERROR' }, category) then
      -- Configure level
      local enabled = value == 'true' or value == 'yes' or value == 'on'
      local levels = {}
      levels[category] = enabled
      logger.configure_notifications({ levels = levels })
      logger.info(
        'Notification level updated',
        { level = category, enabled = enabled },
        { notify = true, category = 'user_action' }
      )
    elseif
      vim.tbl_contains(
        { 'user_action', 'system_status', 'background_operation', 'debug_info', 'performance' },
        category
      )
    then
      -- Configure category
      local enabled = value == 'true' or value == 'yes' or value == 'on'
      local categories = {}
      categories[category] = enabled
      logger.configure_notifications({ categories = categories })
      logger.info(
        'Notification category updated',
        { category = category, enabled = enabled },
        { notify = true, category = 'user_action' }
      )
    else
      logger.error(
        'Invalid notification setting. Use: enabled, level (DEBUG/INFO/WARN/ERROR), or category',
        {},
        { notify = true, category = 'user_action' }
      )
    end
  else
    logger.error(
      'Usage: TwitchNotify [category] [true/false]',
      {},
      { notify = true, category = 'user_action' }
    )
  end
end

---Complete notification configuration options
---@param arg_lead string Current argument being completed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] completions
function M.complete_notify_config(arg_lead, cmd_line, cursor_pos)
  local args = vim.split(cmd_line, ' ', { plain = true, trimempty = true })

  if #args <= 2 then
    -- Complete first argument (setting type)
    local options = {
      'enabled',
      'DEBUG',
      'INFO',
      'WARN',
      'ERROR',
      'user_action',
      'system_status',
      'background_operation',
      'debug_info',
      'performance',
    }

    if arg_lead == '' then
      return options
    end

    local matches = {}
    for _, option in ipairs(options) do
      if option:lower():find(arg_lead:lower(), 1, true) then
        table.insert(matches, option)
      end
    end

    return matches
  elseif #args == 3 then
    -- Complete second argument (true/false)
    local values = { 'true', 'false', 'yes', 'no', 'on', 'off' }

    if arg_lead == '' then
      return values
    end

    local matches = {}
    for _, value in ipairs(values) do
      if value:find(arg_lead:lower(), 1, true) then
        table.insert(matches, value)
      end
    end

    return matches
  end

  return {}
end

return M
