---@class TwitchChat
---@field private _initialized boolean
---@field private _setup_called boolean
---@field private _version string
---@field private _start_time number
---@field config TwitchChatConfigModule
---@field api TwitchChatAPI
---@field events TwitchChatEvents
---@field utils TwitchChatUtils
---@field health TwitchChatHealth
---@field commands TwitchChatCommands
---@field formatter TwitchChatFormatter
---@field display TwitchChatDisplay
---@field logger TwitchChatLogger
local M = {}
local uv = vim.uv or vim.loop

-- Plugin information
M._version = '1.0.0'
M._initialized = false
M._setup_called = false
M._start_time = uv.now()

-- Module imports
---@type TwitchChatConfigModule
local config = require('twitch-chat.config')
---@type TwitchChatAPI
local api = require('twitch-chat.api')
---@type TwitchChatEvents
local events = require('twitch-chat.events')
---@type TwitchChatUtils
local utils = require('twitch-chat.utils')
---@type TwitchChatHealth
local health = require('twitch-chat.health')
---@type TwitchChatCommands
local commands = require('twitch-chat.commands')
---@type TwitchChatFormatter
local formatter = require('twitch-chat.modules.formatter')
---@type TwitchChatDisplay
local display = require('twitch-chat.modules.display')
---@type TwitchChatLogger
local logger = require('twitch-chat.modules.logger')

-- Export submodules for easy access
M.config = config
M.api = api
M.events = events
M.utils = utils
M.health = health
M.commands = commands
M.formatter = formatter
M.display = display
M.logger = logger

---Setup the TwitchChat plugin
---@param opts TwitchChatConfig? User configuration options
---@return nil
function M.setup(opts)
  if M._setup_called then
    vim.notify('TwitchChat.setup() called multiple times', vim.log.levels.WARN)
    return
  end

  M._setup_called = true

  -- Initialize core modules
  local success, err = pcall(function()
    -- Setup configuration first
    config.setup(opts)

    -- Initialize logger early for debugging throughout setup
    logger.setup(config.get('logger'))

    -- Check if plugin should be enabled
    if not config.is_enabled() then
      logger.info(
        'Plugin disabled in configuration',
        {},
        { notify = true, category = 'system_status' }
      )
      vim.notify('TwitchChat is disabled in configuration', vim.log.levels.INFO)
      return
    end

    logger.info(
      'Starting plugin initialization',
      { version = M._version },
      { notify = false, category = 'system_status' }
    )

    -- Initialize event system
    events.setup()

    -- Initialize health check system
    health.setup()

    -- Initialize formatter and display modules
    formatter.setup(config.get('formatter'))
    display.setup(config.get('display'))

    -- Initialize API
    api.init()

    -- Setup commands
    commands.setup()

    -- Setup autocommands
    M._setup_autocommands()

    -- Setup keymaps if configured
    M._setup_keymaps()

    -- Setup integrations
    M._setup_integrations()

    -- Mark as initialized
    M._initialized = true

    -- Log successful initialization
    if config.is_debug() then
      utils.log(vim.log.levels.INFO, 'TwitchChat plugin initialized successfully', {
        version = M._version,
        config_valid = true,
        uptime = M.get_uptime(),
      })
    end

    -- Auto-connect to default channel if configured
    local default_channel = config.get('chat.default_channel')
    if default_channel and default_channel ~= '' then
      vim.defer_fn(function()
        M.connect(default_channel)
      end, 1000)
    end
  end)

  if not success then
    vim.notify(
      string.format('Failed to initialize TwitchChat: %s', err),
      vim.log.levels.ERROR,
      { title = 'TwitchChat Setup' }
    )
  end
end

---Connect to a Twitch channel
---@param channel string Channel name to connect to
---@return boolean success Whether connection was initiated successfully
function M.connect(channel)
  if not M._check_initialized() then
    return false
  end

  if not channel or channel == '' then
    vim.notify('Channel name is required', vim.log.levels.ERROR)
    return false
  end

  return api.connect(channel)
end

---Disconnect from a Twitch channel
---@param channel string? Channel name to disconnect from (defaults to current)
---@return boolean success Whether disconnection was successful
function M.disconnect(channel)
  if not M._check_initialized() then
    return false
  end

  if not channel or channel == '' then
    channel = api.get_current_channel()
    if not channel then
      vim.notify('No active channel to disconnect from', vim.log.levels.WARN)
      return false
    end
  end

  return api.disconnect(channel)
end

---Send a message to the current channel
---@param message string Message to send
---@return boolean success Whether message was sent successfully
function M.send_message(message)
  if not M._check_initialized() then
    return false
  end

  if not message or message == '' then
    vim.notify('Message cannot be empty', vim.log.levels.ERROR)
    return false
  end

  local current_channel = api.get_current_channel()
  if not current_channel then
    vim.notify('No active channel. Connect to a channel first', vim.log.levels.ERROR)
    return false
  end

  return api.send_message(current_channel, message)
end

---Get list of connected channels
---@return TwitchChannelInfo[] channels List of connected channels
function M.get_channels()
  if not M._check_initialized() then
    return {}
  end

  return api.get_channels()
end

---Get current active channel
---@return string? channel Current channel name or nil
function M.get_current_channel()
  if not M._check_initialized() then
    return nil
  end

  return api.get_current_channel()
end

---Switch to a different channel
---@param channel string Channel name to switch to
---@return boolean success Whether channel was switched successfully
function M.switch_channel(channel)
  if not M._check_initialized() then
    return false
  end

  if not channel or channel == '' then
    vim.notify('Channel name is required', vim.log.levels.ERROR)
    return false
  end

  return api.set_current_channel(channel)
end

---Get plugin status
---@return TwitchStatus status Plugin status information
function M.get_status()
  if not M._initialized then
    return {
      enabled = false,
      authenticated = false,
      debug = false,
      channels = {},
      current_channel = nil,
      uptime = M.get_uptime(),
    }
  end

  return api.get_status()
end

---Check if connected to a channel
---@param channel string Channel name
---@return boolean connected Whether connected to channel
function M.is_connected(channel)
  if not M._check_initialized() then
    return false
  end

  if not channel or channel == '' then
    return false
  end

  return api.is_connected(channel)
end

---Get plugin version
---@return string version Plugin version
function M.get_version()
  return M._version
end

---Get plugin uptime
---@return number uptime Uptime in seconds
function M.get_uptime()
  return math.floor((uv.now() - M._start_time) / 1000)
end

---Check if plugin is initialized
---@return boolean initialized Whether plugin is initialized
function M.is_initialized()
  return M._initialized
end

---Reload the plugin
---@return nil
function M.reload()
  if not M._setup_called then
    vim.notify('Plugin not setup yet', vim.log.levels.WARN)
    return
  end

  -- Cleanup existing state
  M._cleanup()

  -- Reload API
  api.reload()

  -- Re-setup with current config
  local current_config = config.export()
  M._setup_called = false
  M._initialized = false
  M.setup(current_config)
end

---Cleanup the plugin without re-initializing
---@return nil
function M.cleanup()
  M._cleanup()
  M._setup_called = false
  M._initialized = false
end

---Register event listener
---@param event string Event name
---@param callback fun(data: any): nil Callback function
---@return nil
function M.on(event, callback)
  events.on(event, callback)
end

---Emit event
---@param event string Event name
---@param data any? Event data
---@return nil
function M.emit(event, data)
  events.emit(event, data)
end

---Insert emote at cursor
---@param emote_name string Emote name to insert
---@return boolean success Whether emote was inserted
function M.insert_emote(emote_name)
  if not M._check_initialized() then
    return false
  end

  return api.insert_emote(emote_name)
end

---Get available emotes
---@return string[] emotes List of available emotes
function M.get_emotes()
  if not M._check_initialized() then
    return {}
  end

  return api.get_emotes()
end

---Run health check
---@return HealthCheckResult[] results Health check results
function M.health_check()
  return health.check()
end

---Check if plugin is healthy
---@return boolean healthy Whether plugin is healthy
function M.is_healthy()
  return health.is_healthy()
end

---Toggle plugin debug mode
---@return nil
function M.toggle_debug()
  local current_debug = config.get('debug')
  config.set('debug', not current_debug)

  vim.notify(
    string.format('Debug mode %s', not current_debug and 'enabled' or 'disabled'),
    vim.log.levels.INFO
  )
end

---Get plugin information
---@return table info Plugin information
function M.get_info()
  return {
    name = 'twitch-chat.nvim',
    version = M._version,
    author = 'TwitchChat Contributors',
    license = 'MIT',
    repository = 'https://github.com/user/twitch-chat.nvim',
    initialized = M._initialized,
    setup_called = M._setup_called,
    uptime = M.get_uptime(),
    config_valid = pcall(config.validate),
    health_status = health.get_health_summary(),
  }
end

-- Private implementation functions

---Check if plugin is initialized and show error if not
---@return boolean initialized Whether plugin is initialized
function M._check_initialized()
  if not M._initialized then
    vim.notify(
      'TwitchChat not initialized. Call require("twitch-chat").setup() first',
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end

---Setup autocommands
---@return nil
function M._setup_autocommands()
  local group = vim.api.nvim_create_augroup('TwitchChat', { clear = true })

  -- Cleanup on vim exit
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    desc = 'Cleanup TwitchChat on exit',
    callback = function()
      M._cleanup()
    end,
  })

  -- Handle focus events
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    desc = 'Handle focus gained',
    callback = function()
      M._handle_focus_gained()
    end,
  })

  vim.api.nvim_create_autocmd('FocusLost', {
    group = group,
    desc = 'Handle focus lost',
    callback = function()
      M._handle_focus_lost()
    end,
  })

  -- Handle colorscheme changes
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    desc = 'Update highlights on colorscheme change',
    callback = function()
      M._update_highlights()
    end,
  })
end

---Setup default keymaps
---@return nil
function M._setup_keymaps()
  local keymaps = config.get('keymaps') or {}

  -- Only set up keymaps if they're configured
  if utils.is_empty(keymaps) then
    return
  end

  -- Set up global keymaps
  vim.keymap.set('n', '<leader>tc', function()
    M.connect(config.get('chat.default_channel') or '')
  end, { desc = 'Connect to Twitch chat' })

  vim.keymap.set('n', '<leader>td', function()
    M.disconnect()
  end, { desc = 'Disconnect from Twitch chat' })

  vim.keymap.set('n', '<leader>ts', function()
    local status = M.get_status()
    commands.show_info_buffer('TwitchChat Status', { vim.inspect(status) })
  end, { desc = 'Show TwitchChat status' })

  vim.keymap.set('n', '<leader>te', function()
    M.insert_emote('Kappa')
  end, { desc = 'Insert emote' })
end

---Setup integrations
---@return nil
function M._setup_integrations()
  -- Setup telescope integration
  if config.is_integration_enabled('telescope') then
    M._setup_telescope_integration()
  end

  -- Setup nvim-cmp integration
  if config.is_integration_enabled('cmp') then
    M._setup_cmp_integration()
  end

  -- Setup which-key integration
  if config.is_integration_enabled('which_key') then
    M._setup_which_key_integration()
  end

  -- Setup lualine integration
  if config.is_integration_enabled('lualine') then
    M._setup_lualine_integration()
  end
end

---Setup telescope integration
---@return nil
function M._setup_telescope_integration()
  local success, telescope = pcall(require, 'telescope')
  if not success then
    return
  end

  -- Register telescope extensions
  telescope.load_extension('twitch_chat')
end

---Setup nvim-cmp integration
---@return nil
function M._setup_cmp_integration()
  local success, cmp = pcall(require, 'cmp')
  if not success then
    return
  end

  -- Register completion source
  cmp.register_source('twitch_chat', require('twitch-chat.modules.completion'))
end

---Setup which-key integration
---@return nil
function M._setup_which_key_integration()
  local success, which_key = pcall(require, 'which-key')
  if not success then
    return
  end

  -- Register keymaps with which-key
  which_key.register({
    ['<leader>t'] = {
      name = 'TwitchChat',
      c = { '<cmd>TwitchChat<cr>', 'Connect to chat' },
      d = { '<cmd>TwitchDisconnect<cr>', 'Disconnect from chat' },
      s = { '<cmd>TwitchStatus<cr>', 'Show status' },
      h = { '<cmd>TwitchHealth<cr>', 'Health check' },
      e = { '<cmd>TwitchEmote<cr>', 'Insert emote' },
    },
  })
end

---Setup lualine integration
---@return nil
function M._setup_lualine_integration()
  local success, _ = pcall(require, 'lualine')
  if not success then
    return
  end

  -- This would add TwitchChat status to lualine
  -- Implementation would depend on lualine's API
end

---Handle focus gained
---@return nil
function M._handle_focus_gained()
  if config.is_debug() then
    utils.log(vim.log.levels.DEBUG, 'Focus gained')
  end

  -- Resume any paused connections
  events.emit('focus_gained')
end

---Handle focus lost
---@return nil
function M._handle_focus_lost()
  if config.is_debug() then
    utils.log(vim.log.levels.DEBUG, 'Focus lost')
  end

  -- Optionally pause connections to save resources
  events.emit('focus_lost')
end

---Update highlights
---@return nil
function M._update_highlights()
  -- Update syntax highlighting for chat buffers
  events.emit('colorscheme_changed')
end

---Cleanup plugin state
---@return nil
function M._cleanup()
  if not M._initialized then
    return
  end

  logger.info('Starting comprehensive plugin cleanup', { module = 'init' })

  -- Gracefully disconnect all channels with timeout
  local channels = api.get_channels()
  for _, channel in ipairs(channels) do
    logger.debug('Disconnecting from channel', { channel = channel.name, module = 'init' })
    api.disconnect(channel.name)
  end

  -- Cleanup individual modules with error handling
  local cleanup_tasks = {
    { name = 'auth', module = require('twitch-chat.modules.auth') },
    { name = 'websocket', module = require('twitch-chat.modules.websocket') },
    { name = 'buffer', module = require('twitch-chat.modules.buffer') },
    { name = 'ui', module = require('twitch-chat.modules.ui') },
    { name = 'emotes', module = require('twitch-chat.modules.emotes') },
    { name = 'logger', module = logger },
  }

  for _, task in ipairs(cleanup_tasks) do
    if task.module and task.module.cleanup then
      local success, err = pcall(task.module.cleanup)
      if not success then
        logger.warn('Module cleanup failed', {
          module_name = task.name,
          error = tostring(err),
          module = 'init',
        })
      else
        logger.debug('Module cleanup successful', { module_name = task.name, module = 'init' })
      end
    end
  end

  -- Clear events
  events.clear_all()

  -- Cleanup commands
  if commands.cleanup then
    commands.cleanup()
  end

  -- Mark as not initialized
  M._initialized = false

  logger.info('Plugin cleanup completed', { module = 'init' })
end

---Validate plugin state
---@return boolean valid Whether plugin state is valid
function M._validate_state()
  if not M._setup_called then
    return false
  end

  if not M._initialized then
    return false
  end

  local success, err = pcall(config.validate)
  if not success then
    utils.log(vim.log.levels.ERROR, 'Configuration validation failed', { error = err })
    return false
  end

  return true
end

---Get resource usage statistics
---@return table stats
function M.get_resource_stats()
  local stats = {
    uptime_seconds = M.get_uptime(),
    memory_estimate_bytes = 0,
    active_connections = 0,
    active_timers = 0,
    event_listeners = 0,
    buffer_count = 0,
    modules_loaded = {},
  }

  -- Get module-specific stats
  local modules = {
    'auth',
    'websocket',
    'buffer',
    'ui',
    'emotes',
    'logger',
  }

  for _, module_name in ipairs(modules) do
    local success, module = pcall(require, 'twitch-chat.modules.' .. module_name)
    if success and module.get_resource_stats then
      local module_stats = module.get_resource_stats()
      stats.modules_loaded[module_name] = module_stats

      -- Aggregate stats
      if module_stats.memory_estimate_bytes then
        stats.memory_estimate_bytes = stats.memory_estimate_bytes
          + module_stats.memory_estimate_bytes
      end
      if module_stats.active_connections then
        stats.active_connections = stats.active_connections + module_stats.active_connections
      end
      if module_stats.timers_active then
        stats.active_timers = stats.active_timers + module_stats.timers_active
      end
    end
  end

  -- Get event system stats
  if events.get_stats then
    local event_stats = events.get_stats()
    stats.event_listeners = event_stats.total_listeners or 0
  end

  return stats
end

---Force cleanup all resources with timeout
---@param timeout_ms? number Timeout in milliseconds (default 5000)
function M.force_cleanup(timeout_ms)
  timeout_ms = timeout_ms or 5000

  logger.warn('Forcing cleanup of all resources', {
    timeout_ms = timeout_ms,
    module = 'init',
  })

  -- Set a timer to force shutdown after timeout
  local force_timer = vim.defer_fn(function()
    logger.error('Cleanup timeout exceeded, forcing immediate shutdown', { module = 'init' })
    M._initialized = false
  end, timeout_ms)

  -- Perform cleanup
  M._cleanup()

  -- Cancel force timer if cleanup completed
  if force_timer then
    vim.fn.timer_stop(force_timer)
  end
end

---Cleanup plugin resources (public interface)
---@return nil
function M.cleanup()
  if not M._initialized then
    return
  end

  M._cleanup()
end

-- Setup cleanup on VimLeavePre with timeout
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('TwitchChatCleanup', { clear = true }),
  callback = function()
    -- Use force cleanup with shorter timeout on exit
    M.force_cleanup(2000)
  end,
})

-- Expose common functions at top level for convenience

return M
