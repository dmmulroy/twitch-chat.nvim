-- tests/twitch-chat/commands_spec.lua
-- Command system tests

local commands = require('twitch-chat.commands')
local utils = require('twitch-chat.utils')
local config = require('twitch-chat.config')
local health = require('twitch-chat.health')

describe('TwitchChat Commands', function()
  local created_commands = {}
  local notify_calls = {}

  before_each(function()
    -- Reset state
    created_commands = {}
    notify_calls = {}

    -- Mock vim functions only what we need
    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.ui = _G.vim.ui or {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.loop = _G.vim.loop or {}
    _G.vim.log = _G.vim.log or {}

    -- Mock essential vim.api functions
    _G.vim.api.nvim_create_user_command = function(name, func, opts)
      created_commands[name] = { func = func, opts = opts }
    end
    _G.vim.api.nvim_del_user_command = function(name)
      created_commands[name] = nil
    end
    _G.vim.api.nvim_create_buf = function()
      return 1
    end
    _G.vim.api.nvim_buf_set_lines = function() end
    _G.vim.api.nvim_buf_set_option = function() end
    _G.vim.api.nvim_buf_set_name = function() end
    _G.vim.api.nvim_win_set_buf = function() end
    _G.vim.api.nvim_buf_set_keymap = function() end

    -- Mock vim.notify
    _G.vim.notify = function(message, level, opts)
      table.insert(notify_calls, { message = message, level = level, opts = opts })
    end

    -- Mock vim.ui.input
    _G.vim.ui.input = function(opts, callback)
      callback('test_channel')
    end

    -- Mock other vim functions
    _G.vim.cmd = function() end
    _G.vim.fn.json_decode = function(str)
      return tonumber(str) or str
    end
    _G.vim.loop.fs_stat = function()
      return { type = 'file' }
    end
    _G.vim.loop.new_timer = function()
      return { start = function() end, stop = function() end }
    end
    _G.vim.loop.now = function()
      return os.time() * 1000
    end
    _G.vim.schedule = function(fn)
      fn()
    end
    _G.vim.inspect = function(obj)
      return tostring(obj)
    end
    _G.vim.deepcopy = function(obj)
      return obj
    end
    _G.vim.validate = function() end
    _G.vim.log.levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }

    -- Mock required modules
    package.loaded['twitch-chat.api'] = {
      connect = function() end,
      disconnect = function() end,
      get_current_channel = function()
        return 'test_channel'
      end,
      get_status = function()
        return {
          enabled = true,
          authenticated = true,
          debug = false,
          channels = { { name = 'test_channel', status = 'connected' } },
        }
      end,
      get_channels = function()
        return { { name = 'test_channel', status = 'connected', message_count = 42 } }
      end,
      send_message = function() end,
      reload = function() end,
      insert_emote = function() end,
    }

    package.loaded['twitch-chat.modules.auth'] = {
      login = function() end,
      logout = function() end,
      refresh_token = function() end,
      check_status = function() end,
    }

    package.loaded['twitch-chat.modules.filter'] = {
      add_filter = function() end,
      remove_filter = function() end,
      list_filters = function() end,
      clear_filters = function() end,
    }

    package.loaded['telescope'] = {}

    -- Initialize config
    config.setup()
  end)

  after_each(function()
    -- Clean up commands
    commands.cleanup()
  end)

  describe('setup()', function()
    it('should register all commands', function()
      commands.setup()

      -- Check that all 14 commands were registered
      local expected_commands = {
        'TwitchChat',
        'TwitchConnect',
        'TwitchDisconnect',
        'TwitchSend',
        'TwitchAuth',
        'TwitchStatus',
        'TwitchChannels',
        'TwitchHealth',
        'TwitchConfig',
        'TwitchReload',
        'TwitchHelp',
        'TwitchEmote',
        'TwitchFilter',
        'TwitchLog',
      }

      for _, cmd_name in ipairs(expected_commands) do
        assert.is_not_nil(
          created_commands[cmd_name],
          'Command ' .. cmd_name .. ' should be registered'
        )
      end

      assert.equals(#expected_commands, utils.table_length(created_commands))
    end)

    it('should register commands with correct options', function()
      commands.setup()

      -- Test specific command options
      assert.equals('Open Twitch chat interface', created_commands['TwitchChat'].opts.desc)
      assert.equals('?', created_commands['TwitchChat'].opts.nargs)
      assert.is_function(created_commands['TwitchChat'].opts.complete)

      assert.equals('Connect to a Twitch channel', created_commands['TwitchConnect'].opts.desc)
      assert.equals(1, created_commands['TwitchConnect'].opts.nargs)
      assert.is_function(created_commands['TwitchConnect'].opts.complete)

      assert.equals('Send a message to current channel', created_commands['TwitchSend'].opts.desc)
      assert.equals('+', created_commands['TwitchSend'].opts.nargs)
      assert.is_nil(created_commands['TwitchSend'].opts.complete)
    end)

    it('should allow multiple setup calls', function()
      commands.setup()
      local first_count = utils.table_length(created_commands)

      commands.setup()
      local second_count = utils.table_length(created_commands)

      assert.equals(first_count, second_count)
    end)
  end)

  describe('register_command()', function()
    it('should register a command with valid parameters', function()
      local test_func = function() end
      local test_opts = { desc = 'Test command', nargs = 0 }

      commands.register_command('TestCommand', test_func, test_opts)

      assert.is_not_nil(created_commands['TestCommand'])
      assert.equals(test_func, created_commands['TestCommand'].func)
      assert.equals(test_opts, created_commands['TestCommand'].opts)
    end)

    it('should validate parameters', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        commands.register_command(123, function() end, {})
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        commands.register_command('TestCommand', 'not_a_function', {})
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        commands.register_command('TestCommand', function() end, 'not_a_table')
      end)
    end)

    it('should handle empty options', function()
      local test_func = function() end

      commands.register_command('TestCommand', test_func, {})

      assert.is_not_nil(created_commands['TestCommand'])
      assert.equals('', created_commands['TestCommand'].opts.desc)
    end)

    it('should wrap command function with error handling', function()
      local error_func = function()
        error('Test error')
      end

      commands.register_command('ErrorCommand', error_func, {})

      -- Execute the wrapped function
      local success, _ = pcall(created_commands['ErrorCommand'].func, {})
      assert.is_true(success) -- Should not propagate error

      -- Check that error was notified
      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('Error in command ErrorCommand'))
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchChat command', function()
    before_each(function()
      commands.setup()
    end)

    it('should use provided channel argument', function()
      local api = require('twitch-chat.api')
      local connect_called = false
      local connect_channel = nil

      api.connect = function(channel)
        connect_called = true
        connect_channel = channel
      end

      created_commands['TwitchChat'].func({ args = 'test_channel' })

      assert.is_true(connect_called)
      assert.equals('test_channel', connect_channel)
    end)

    it('should use default channel when no argument provided', function()
      config.set('chat.default_channel', 'default_channel')
      local api = require('twitch-chat.api')
      local connect_called = false
      local connect_channel = nil

      ---@diagnostic disable-next-line: duplicate-set-field
      api.connect = function(channel)
        connect_called = true
        connect_channel = channel
      end

      created_commands['TwitchChat'].func({ args = '' })

      assert.is_true(connect_called)
      assert.equals('default_channel', connect_channel)
    end)

    it('should show channel picker when no channel specified', function()
      config.set('chat.default_channel', '')
      local ui_input_called = false

      _G.vim.ui.input = function(opts, callback)
        ui_input_called = true
        callback('picked_channel')
      end

      local api = require('twitch-chat.api')
      local connect_called = false
      local connect_channel = nil

      api.connect = function(channel)
        connect_called = true
        connect_channel = channel
      end

      created_commands['TwitchChat'].func({ args = '' })

      assert.is_true(ui_input_called)
      assert.is_true(connect_called)
      assert.equals('picked_channel', connect_channel)
    end)
  end)

  describe('TwitchConnect command', function()
    before_each(function()
      commands.setup()
    end)

    it('should connect to valid channel', function()
      local api = require('twitch-chat.api')
      local connect_called = false
      local connect_channel = nil

      ---@diagnostic disable-next-line: duplicate-set-field
      api.connect = function(channel)
        connect_called = true
        connect_channel = channel
      end

      created_commands['TwitchConnect'].func({ args = 'valid_channel' })

      assert.is_true(connect_called)
      assert.equals('valid_channel', connect_channel)
    end)

    it('should reject empty channel name', function()
      created_commands['TwitchConnect'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.equals('Channel name is required', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)

    it('should reject invalid channel name format', function()
      created_commands['TwitchConnect'].func({ args = 'ab' }) -- Too short

      assert.equals(1, #notify_calls)
      assert.equals('Invalid channel name format', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)

    it('should reject nil channel name', function()
      created_commands['TwitchConnect'].func({ args = nil })

      assert.equals(1, #notify_calls)
      assert.equals('Channel name is required', notify_calls[1].message)
    end)
  end)

  describe('TwitchDisconnect command', function()
    before_each(function()
      commands.setup()
    end)

    it('should disconnect from specified channel', function()
      local api = require('twitch-chat.api')
      local disconnect_called = false
      local disconnect_channel = nil

      api.disconnect = function(channel)
        disconnect_called = true
        disconnect_channel = channel
      end

      created_commands['TwitchDisconnect'].func({ args = 'test_channel' })

      assert.is_true(disconnect_called)
      assert.equals('test_channel', disconnect_channel)
    end)

    it('should disconnect from current channel when no argument', function()
      local api = require('twitch-chat.api')
      local disconnect_called = false
      local disconnect_channel = nil

      ---@diagnostic disable-next-line: duplicate-set-field
      api.disconnect = function(channel)
        disconnect_called = true
        disconnect_channel = channel
      end

      created_commands['TwitchDisconnect'].func({ args = '' })

      assert.is_true(disconnect_called)
      assert.equals('test_channel', disconnect_channel)
    end)

    it('should warn when no active channel to disconnect', function()
      local api = require('twitch-chat.api')
      api.get_current_channel = function()
        return nil
      end

      created_commands['TwitchDisconnect'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.equals('No active channel to disconnect from', notify_calls[1].message)
      assert.equals(vim.log.levels.WARN, notify_calls[1].level)
    end)
  end)

  describe('TwitchSend command', function()
    before_each(function()
      commands.setup()
    end)

    it('should send message to current channel', function()
      local api = require('twitch-chat.api')
      local send_called = false
      local send_channel = nil
      local send_message = nil

      api.send_message = function(channel, message)
        send_called = true
        send_channel = channel
        send_message = message
      end

      created_commands['TwitchSend'].func({ args = 'Hello world' })

      assert.is_true(send_called)
      assert.equals('test_channel', send_channel)
      assert.equals('Hello world', send_message)
    end)

    it('should reject empty message', function()
      created_commands['TwitchSend'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.equals('Message is required', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)

    it('should reject when no active channel', function()
      local api = require('twitch-chat.api')
      api.get_current_channel = function()
        return nil
      end

      created_commands['TwitchSend'].func({ args = 'test message' })

      assert.equals(1, #notify_calls)
      assert.equals('No active channel. Connect to a channel first', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchAuth command', function()
    before_each(function()
      commands.setup()
    end)

    it('should call login by default', function()
      local auth = require('twitch-chat.modules.auth')
      local login_called = false
      auth.login = function()
        login_called = true
      end

      created_commands['TwitchAuth'].func({ args = '' })

      assert.is_true(login_called)
    end)

    it('should call specific auth actions', function()
      local auth = require('twitch-chat.modules.auth')
      local logout_called = false
      local refresh_called = false
      local status_called = false

      auth.logout = function()
        logout_called = true
      end
      auth.refresh_token = function()
        refresh_called = true
      end
      auth.check_status = function()
        status_called = true
      end

      created_commands['TwitchAuth'].func({ args = 'logout' })
      assert.is_true(logout_called)

      created_commands['TwitchAuth'].func({ args = 'refresh' })
      assert.is_true(refresh_called)

      created_commands['TwitchAuth'].func({ args = 'status' })
      assert.is_true(status_called)
    end)

    it('should reject invalid auth actions', function()
      created_commands['TwitchAuth'].func({ args = 'invalid_action' })

      assert.equals(1, #notify_calls)
      assert.equals(
        'Invalid auth action. Use: login, logout, refresh, or status',
        notify_calls[1].message
      )
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchStatus command', function()
    before_each(function()
      commands.setup()
    end)

    it('should show status information', function()
      local buf_set_lines_called = false
      local status_lines = nil

      _G.vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, lines)
        buf_set_lines_called = true
        status_lines = lines
      end

      created_commands['TwitchStatus'].func({})

      assert.is_true(buf_set_lines_called)
      assert.is_not_nil(status_lines)
      if status_lines and status_lines[1] then
        assert.truthy(status_lines[1]:find('TwitchChat Status'))
      end
      if status_lines and status_lines[3] then
        assert.truthy(status_lines[3]:find('Plugin enabled: Yes'))
      end
      if status_lines and status_lines[4] then
        assert.truthy(status_lines[4]:find('Connected channels: 1'))
      end
      if status_lines and status_lines[5] then
        assert.truthy(status_lines[5]:find('Authentication: Yes'))
      end
    end)
  end)

  describe('TwitchChannels command', function()
    before_each(function()
      commands.setup()
    end)

    it('should list connected channels', function()
      local buf_set_lines_called = false
      local channel_lines = nil

      _G.vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, lines)
        buf_set_lines_called = true
        channel_lines = lines
      end

      created_commands['TwitchChannels'].func({})

      assert.is_true(buf_set_lines_called)
      assert.is_not_nil(channel_lines)
      if channel_lines and channel_lines[1] then
        assert.truthy(channel_lines[1]:find('Connected Channels'))
      end
      if channel_lines and channel_lines[3] then
        assert.truthy(channel_lines[3]:find('test_channel'))
      end
    end)

    it('should notify when no channels connected', function()
      local api = require('twitch-chat.api')
      api.get_channels = function()
        return {}
      end

      created_commands['TwitchChannels'].func({})

      assert.equals(1, #notify_calls)
      assert.equals('No connected channels', notify_calls[1].message)
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)
  end)

  describe('TwitchHealth command', function()
    before_each(function()
      commands.setup()
    end)

    it('should run health checks', function()
      local health_check_called = false
      health.run_health_check = function()
        health_check_called = true
      end

      created_commands['TwitchHealth'].func({})

      assert.is_true(health_check_called)
    end)
  end)

  describe('TwitchConfig command', function()
    before_each(function()
      commands.setup()
    end)

    it('should show current configuration when no arguments', function()
      local buf_set_lines_called = false

      _G.vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, lines)
        buf_set_lines_called = true
      end

      created_commands['TwitchConfig'].func({ args = '' })

      assert.is_true(buf_set_lines_called)
    end)

    it('should show specific config value', function()
      config.set('debug', true)

      created_commands['TwitchConfig'].func({ args = 'debug' })

      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('debug = true'))
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)

    it('should set config value', function()
      created_commands['TwitchConfig'].func({ args = 'debug true' })

      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('Set debug = true'))
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)

    it('should handle non-existent config key', function()
      created_commands['TwitchConfig'].func({ args = 'nonexistent' })

      assert.equals(1, #notify_calls)
      assert.equals('Configuration key not found: nonexistent', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)

    it('should reject invalid usage', function()
      created_commands['TwitchConfig'].func({ args = 'too many args here' })

      assert.equals(1, #notify_calls)
      assert.equals('Usage: TwitchConfig [key] [value]', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchReload command', function()
    before_each(function()
      commands.setup()
    end)

    it('should reload the plugin', function()
      local api = require('twitch-chat.api')
      local reload_called = false
      api.reload = function()
        reload_called = true
      end

      created_commands['TwitchReload'].func({})

      assert.is_true(reload_called)
      assert.equals(1, #notify_calls)
      assert.equals('TwitchChat plugin reloaded', notify_calls[1].message)
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)
  end)

  describe('TwitchHelp command', function()
    before_each(function()
      commands.setup()
    end)

    it('should show general help when no topic specified', function()
      local buf_set_lines_called = false
      local help_lines = nil

      _G.vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, lines)
        buf_set_lines_called = true
        help_lines = lines
      end

      created_commands['TwitchHelp'].func({ args = '' })

      assert.is_true(buf_set_lines_called)
      assert.is_not_nil(help_lines)
      if help_lines and help_lines[1] then
        assert.truthy(help_lines[1]:find('TwitchChat Help'))
      end
    end)

    it('should show specific help topic', function()
      created_commands['TwitchHelp'].func({ args = 'commands' })

      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('Commands help not implemented yet'))
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)

    it('should handle unknown help topic', function()
      created_commands['TwitchHelp'].func({ args = 'unknown_topic' })

      assert.equals(1, #notify_calls)
      assert.equals('Help topic not found: unknown_topic', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchEmote command', function()
    before_each(function()
      commands.setup()
    end)

    it('should show emote picker when no emote specified', function()
      created_commands['TwitchEmote'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('Emote picker requires telescope integration'))
      assert.equals(vim.log.levels.WARN, notify_calls[1].level)
    end)

    it('should insert specific emote', function()
      local api = require('twitch-chat.api')
      local insert_called = false
      local insert_emote = nil

      api.insert_emote = function(emote_name)
        insert_called = true
        insert_emote = emote_name
      end

      created_commands['TwitchEmote'].func({ args = 'Kappa' })

      assert.is_true(insert_called)
      assert.equals('Kappa', insert_emote)
    end)

    it('should use telescope picker when integration enabled', function()
      config.set('integrations.telescope', true)

      created_commands['TwitchEmote'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.truthy(notify_calls[1].message:find('Telescope emote picker not implemented yet'))
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)
  end)

  describe('TwitchFilter command', function()
    before_each(function()
      commands.setup()
    end)

    it('should add filter', function()
      local filter_module = require('twitch-chat.modules.filter')
      local add_called = false
      local add_type = nil
      local add_pattern = nil

      filter_module.add_filter = function(filter_type, pattern)
        add_called = true
        add_type = filter_type
        add_pattern = pattern
      end

      created_commands['TwitchFilter'].func({ args = 'add block_pattern spam' })

      assert.is_true(add_called)
      assert.equals('block_pattern', add_type)
      assert.equals('spam', add_pattern)
    end)

    it('should remove filter', function()
      local filter_module = require('twitch-chat.modules.filter')
      local remove_called = false
      local remove_type = nil
      local remove_pattern = nil

      filter_module.remove_filter = function(filter_type, pattern)
        remove_called = true
        remove_type = filter_type
        remove_pattern = pattern
      end

      created_commands['TwitchFilter'].func({ args = 'remove block_pattern spam' })

      assert.is_true(remove_called)
      assert.equals('block_pattern', remove_type)
      assert.equals('spam', remove_pattern)
    end)

    it('should list filters', function()
      local filter_module = require('twitch-chat.modules.filter')
      local list_called = false

      filter_module.list_filters = function()
        list_called = true
      end

      created_commands['TwitchFilter'].func({ args = 'list' })

      assert.is_true(list_called)
    end)

    it('should clear filters', function()
      local filter_module = require('twitch-chat.modules.filter')
      local clear_called = false

      filter_module.clear_filters = function()
        clear_called = true
      end

      created_commands['TwitchFilter'].func({ args = 'clear' })

      assert.is_true(clear_called)
    end)

    it('should reject invalid usage', function()
      created_commands['TwitchFilter'].func({ args = '' })

      assert.equals(1, #notify_calls)
      assert.equals('Usage: TwitchFilter <action> [arguments]', notify_calls[1].message)
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)

    it('should reject invalid action', function()
      created_commands['TwitchFilter'].func({ args = 'invalid_action' })

      assert.equals(1, #notify_calls)
      assert.equals(
        'Invalid filter action. Use: add, remove, list, or clear',
        notify_calls[1].message
      )
      assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    end)
  end)

  describe('TwitchLog command', function()
    before_each(function()
      commands.setup()
    end)

    it('should show not implemented message', function()
      created_commands['TwitchLog'].func({ args = 'all' })

      assert.equals(1, #notify_calls)
      assert.equals('Log viewing not implemented yet', notify_calls[1].message)
      assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    end)
  end)

  describe('completion functions', function()
    before_each(function()
      commands.setup()
    end)

    describe('complete_channel()', function()
      it('should return all channels when no arg_lead', function()
        local completions = commands.complete_channel('', 'TwitchConnect ', 0)
        assert.is_table(completions)
        assert.equals(5, #completions)
        assert.is_true(utils.table_contains(completions, 'shroud'))
        assert.is_true(utils.table_contains(completions, 'ninja'))
      end)

      it('should filter channels by arg_lead', function()
        local completions = commands.complete_channel('sh', 'TwitchConnect sh', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('shroud', completions[1])
      end)

      it('should be case insensitive', function()
        local completions = commands.complete_channel('SH', 'TwitchConnect SH', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('shroud', completions[1])
      end)
    end)

    describe('complete_connected_channel()', function()
      it('should return connected channels', function()
        local completions = commands.complete_connected_channel('', 'TwitchDisconnect ', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('test_channel', completions[1])
      end)

      it('should filter connected channels', function()
        local completions = commands.complete_connected_channel('test', 'TwitchDisconnect test', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('test_channel', completions[1])
      end)

      it('should return empty for no matches', function()
        local completions =
          commands.complete_connected_channel('nomatch', 'TwitchDisconnect nomatch', 0)
        assert.is_table(completions)
        assert.equals(0, #completions)
      end)
    end)

    describe('complete_config_path()', function()
      it('should return all config paths when no arg_lead', function()
        local completions = commands.complete_config_path('', 'TwitchConfig ', 0)
        assert.is_table(completions)
        assert.is_true(#completions > 0)
        assert.is_true(utils.table_contains(completions, 'enabled'))
        assert.is_true(utils.table_contains(completions, 'debug'))
        assert.is_true(utils.table_contains(completions, 'ui.width'))
      end)

      it('should filter config paths by arg_lead', function()
        local completions = commands.complete_config_path('ui', 'TwitchConfig ui', 0)
        assert.is_table(completions)
        assert.is_true(#completions > 0)
        -- Should contain ui.* paths
        local has_ui_path = false
        for _, completion in ipairs(completions) do
          if completion:find('^ui%.') then
            has_ui_path = true
            break
          end
        end
        assert.is_true(has_ui_path)
      end)
    end)

    describe('complete_help_topic()', function()
      it('should return all help topics when no arg_lead', function()
        local completions = commands.complete_help_topic('', 'TwitchHelp ', 0)
        assert.is_table(completions)
        assert.equals(8, #completions)
        assert.is_true(utils.table_contains(completions, 'commands'))
        assert.is_true(utils.table_contains(completions, 'configuration'))
        assert.is_true(utils.table_contains(completions, 'troubleshooting'))
      end)

      it('should filter help topics by arg_lead', function()
        local completions = commands.complete_help_topic('con', 'TwitchHelp con', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('configuration', completions[1])
      end)
    end)

    describe('complete_emote()', function()
      it('should return all emotes when no arg_lead', function()
        local completions = commands.complete_emote('', 'TwitchEmote ', 0)
        assert.is_table(completions)
        assert.equals(5, #completions)
        assert.is_true(utils.table_contains(completions, 'Kappa'))
        assert.is_true(utils.table_contains(completions, 'PogChamp'))
      end)

      it('should filter emotes by arg_lead', function()
        local completions = commands.complete_emote('K', 'TwitchEmote K', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('Kappa', completions[1])
      end)
    end)

    describe('complete_filter_action()', function()
      it('should complete filter actions', function()
        local completions = commands.complete_filter_action('', 'TwitchFilter ', 0)
        assert.is_table(completions)
        assert.equals(4, #completions)
        assert.is_true(utils.table_contains(completions, 'add'))
        assert.is_true(utils.table_contains(completions, 'remove'))
        assert.is_true(utils.table_contains(completions, 'list'))
        assert.is_true(utils.table_contains(completions, 'clear'))
      end)

      it('should complete filter types for add/remove', function()
        local completions = commands.complete_filter_action('', 'TwitchFilter add ', 0)
        assert.is_table(completions)
        assert.equals(4, #completions)
        assert.is_true(utils.table_contains(completions, 'block_pattern'))
        assert.is_true(utils.table_contains(completions, 'allow_pattern'))
        assert.is_true(utils.table_contains(completions, 'block_user'))
        assert.is_true(utils.table_contains(completions, 'allow_user'))
      end)

      it('should filter actions by arg_lead', function()
        local completions = commands.complete_filter_action('a', 'TwitchFilter a', 0)
        assert.is_table(completions)
        assert.equals(1, #completions)
        assert.equals('add', completions[1])
      end)

      it('should return empty for pattern completion', function()
        local completions =
          commands.complete_filter_action('', 'TwitchFilter add block_pattern ', 0)
        assert.is_table(completions)
        assert.equals(0, #completions)
      end)
    end)
  end)

  describe('helper functions', function()
    before_each(function()
      commands.setup()
    end)

    describe('show_channel_picker()', function()
      it('should use vim.ui.input when telescope not enabled', function()
        local input_called = false
        _G.vim.ui.input = function(opts, callback)
          input_called = true
          assert.equals('Enter channel name: ', opts.prompt)
          callback('picked_channel')
        end

        local api = require('twitch-chat.api')
        local connect_called = false
        api.connect = function(channel)
          connect_called = true
          assert.equals('picked_channel', channel)
        end

        commands.show_channel_picker()

        assert.is_true(input_called)
        assert.is_true(connect_called)
      end)

      it('should show telescope picker when enabled', function()
        config.set('integrations.telescope', true)

        commands.show_channel_picker()

        assert.equals(1, #notify_calls)
        assert.truthy(notify_calls[1].message:find('Telescope channel picker not implemented yet'))
      end)
    end)

    describe('show_emote_picker()', function()
      it('should warn when telescope not enabled', function()
        commands.show_emote_picker()

        assert.equals(1, #notify_calls)
        assert.equals('Emote picker requires telescope integration', notify_calls[1].message)
        assert.equals(vim.log.levels.WARN, notify_calls[1].level)
      end)

      it('should show telescope picker when enabled', function()
        config.set('integrations.telescope', true)

        commands.show_emote_picker()

        assert.equals(1, #notify_calls)
        assert.truthy(notify_calls[1].message:find('Telescope emote picker not implemented yet'))
      end)
    end)

    describe('show_info_buffer()', function()
      it('should create buffer with correct content', function()
        local buf_created = false
        local buf_lines = nil
        local buf_name = nil

        _G.vim.api.nvim_create_buf = function(listed, scratch)
          buf_created = true
          return 1
        end

        _G.vim.api.nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, lines)
          buf_lines = lines
        end

        _G.vim.api.nvim_buf_set_name = function(bufnr, name)
          buf_name = name
        end

        commands.show_info_buffer('Test Title', { 'Line 1', 'Line 2' })

        assert.is_true(buf_created)
        assert.equals('Test Title', buf_name)
        assert.is_table(buf_lines)
        assert.equals(2, #buf_lines)
        if buf_lines and buf_lines[1] then
          assert.equals('Line 1', buf_lines[1])
        end
        if buf_lines and buf_lines[2] then
          assert.equals('Line 2', buf_lines[2])
        end
      end)
    end)
  end)

  describe('get_commands()', function()
    it('should return copy of registered commands', function()
      commands.setup()
      local cmds = commands.get_commands()

      assert.is_table(cmds)
      assert.equals(14, #cmds)
      assert.is_not_nil(cmds[1].name)
      assert.is_not_nil(cmds[1].desc)
    end)

    it('should return deep copy to prevent modification', function()
      commands.setup()
      local cmds = commands.get_commands()

      -- Modify returned table
      cmds[1].name = 'Modified'

      -- Get commands again
      local cmds2 = commands.get_commands()
      assert.is_not.equals('Modified', cmds2[1].name)
    end)
  end)

  describe('cleanup()', function()
    it('should unregister all commands', function()
      commands.setup()
      assert.is_true(utils.table_length(created_commands) > 0)

      commands.cleanup()

      assert.equals(0, utils.table_length(created_commands))
    end)

    it('should handle cleanup when no commands registered', function()
      assert.has_no.errors(function()
        commands.cleanup()
      end)
    end)
  end)

  describe('error handling', function()
    before_each(function()
      commands.setup()
    end)

    it('should handle API module loading errors', function()
      package.loaded['twitch-chat.api'] = nil
      local original_require = require

      ---@diagnostic disable-next-line: duplicate-set-field
      _G.require = function(module)
        if module == 'twitch-chat.api' then
          error('Module loading failed')
        end
        return original_require(module)
      end

      -- Command should not crash
      assert.has_no.errors(function()
        created_commands['TwitchConnect'].func({ args = 'test_channel' })
      end)

      _G.require = original_require
    end)

    it('should handle config module errors', function()
      local original_config_get = config.get
      config.get = function(key)
        if key == 'chat.default_channel' then
          error('Config error')
        end
        return original_config_get(key)
      end

      -- Command should not crash
      assert.has_no.errors(function()
        created_commands['TwitchChat'].func({ args = '' })
      end)

      config.get = original_config_get
    end)
  end)

  describe('edge cases', function()
    before_each(function()
      commands.setup()
    end)

    it('should handle very long arguments', function()
      local long_message = string.rep('a', 1000)

      local api = require('twitch-chat.api')
      local message_received = nil
      api.send_message = function(channel, message)
        message_received = message
      end

      created_commands['TwitchSend'].func({ args = long_message })

      assert.equals(long_message, message_received)
    end)

    it('should handle special characters in arguments', function()
      local special_message = 'Hello! @#$%^&*()_+{}|:"<>?[]\\;\',./'

      local api = require('twitch-chat.api')
      local message_received = nil
      api.send_message = function(channel, message)
        message_received = message
      end

      created_commands['TwitchSend'].func({ args = special_message })

      assert.equals(special_message, message_received)
    end)

    it('should handle unicode characters', function()
      local unicode_message = 'Hello 🌍 世界 🎉'

      local api = require('twitch-chat.api')
      local message_received = nil
      api.send_message = function(channel, message)
        message_received = message
      end

      created_commands['TwitchSend'].func({ args = unicode_message })

      assert.equals(unicode_message, message_received)
    end)

    it('should handle empty table args', function()
      assert.has_no.errors(function()
        created_commands['TwitchStatus'].func({})
      end)
    end)

    it('should handle nil args table', function()
      assert.has_no.errors(function()
        created_commands['TwitchStatus'].func(nil)
      end)
    end)
  end)
end)
