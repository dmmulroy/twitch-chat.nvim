-- tests/twitch-chat/config_spec.lua
-- Configuration system tests

local config = require('twitch-chat.config')

describe('TwitchChat Configuration', function()
  local original_config

  before_each(function()
    -- Save original config
    original_config = config.export()

    -- Reset to defaults
    config.reset()
  end)

  after_each(function()
    -- Restore original config
    config.import(original_config)
  end)

  describe('setup()', function()
    it('should initialize with default configuration', function()
      config.setup()

      assert.is_true(config.is_enabled())
      assert.is_false(config.is_debug())
      assert.equals('center', config.get('ui.position'))
      assert.equals('rounded', config.get('ui.border'))
      assert.equals(1000, config.get('ui.max_messages'))
    end)

    it('should merge user options with defaults', function()
      local user_config = {
        debug = true,
        ui = {
          width = 120,
          height = 30,
          position = 'left',
        },
        chat = {
          default_channel = 'test_channel',
        },
      }

      config.setup(user_config)

      assert.is_true(config.is_debug())
      assert.equals(120, config.get('ui.width'))
      assert.equals(30, config.get('ui.height'))
      assert.equals('left', config.get('ui.position'))
      assert.equals('test_channel', config.get('chat.default_channel'))
      -- Defaults should still be preserved
      assert.equals('rounded', config.get('ui.border'))
    end)

    it('should validate configuration on setup', function()
      local invalid_config = {
        ui = {
          width = 'invalid',
        },
      }

      -- Should not throw error but should notify
      assert.has_no.errors(function()
        config.setup(invalid_config)
      end)
    end)
  end)

  describe('validation', function()
    it('should validate valid configuration', function()
      local valid_config = {
        enabled = true,
        debug = false,
        auth = {
          client_id = 'test_client_id',
          redirect_uri = 'http://localhost:3000/callback',
          scopes = { 'chat:read', 'chat:edit' },
          token_file = '/tmp/test_token.json',
          auto_refresh = true,
        },
        ui = {
          width = 80,
          height = 20,
          position = 'center',
          border = 'rounded',
        },
        chat = {
          default_channel = 'testchannel',
          reconnect_delay = 5000,
          max_reconnect_attempts = 3,
        },
      }

      config.setup(valid_config)
      assert.has_no.errors(function()
        config.validate()
      end)
    end)

    it('should reject invalid position values', function()
      local invalid_config = {
        ui = { position = 'invalid_position' },
      }

      config.setup(invalid_config)
      assert.has.errors(function()
        config.validate()
      end)
    end)

    it('should reject invalid border values', function()
      local invalid_config = {
        ui = { border = 'invalid_border' },
      }

      config.setup(invalid_config)
      assert.has.errors(function()
        config.validate()
      end)
    end)

    it('should reject invalid numeric ranges', function()
      local invalid_configs = {
        { ui = { width = 5 } }, -- Too small
        { ui = { width = 2000 } }, -- Too large
        { ui = { height = 2 } }, -- Too small
        { ui = { height = 150 } }, -- Too large
        { ui = { max_messages = 5 } }, -- Too small
        { ui = { max_messages = 15000 } }, -- Too large
        { chat = { reconnect_delay = 500 } }, -- Too small
        { chat = { reconnect_delay = 100000 } }, -- Too large
      }

      for _, invalid_config in ipairs(invalid_configs) do
        config.reset()
        config.setup(invalid_config)
        assert.has.errors(function()
          config.validate()
        end) -- Just check that it errors, don't match specific message
      end
    end)

    it('should reject invalid OAuth scopes', function()
      local invalid_config = {
        auth = {
          scopes = { 'invalid:scope' },
        },
      }

      config.setup(invalid_config)
      assert.has.errors(function()
        config.validate()
      end)
    end)

    it('should reject invalid redirect URI', function()
      local invalid_config = {
        auth = {
          redirect_uri = 'not_a_valid_uri',
        },
      }

      config.setup(invalid_config)
      assert.has.errors(function()
        config.validate()
      end)
    end)

    it('should reject invalid regex patterns', function()
      local invalid_config = {
        filters = {
          block_patterns = { '[invalid_regex' },
        },
      }

      config.setup(invalid_config)
      assert.has.errors(function()
        config.validate()
      end)
    end)
  end)

  describe('get() and set()', function()
    it('should get nested configuration values', function()
      config.setup({
        ui = {
          width = 100,
          highlights = {
            username = 'TestHighlight',
          },
        },
      })

      assert.equals(100, config.get('ui.width'))
      assert.equals('TestHighlight', config.get('ui.highlights.username'))
    end)

    it('should return nil for non-existent paths', function()
      config.setup()

      assert.is_nil(config.get('nonexistent.path'))
      assert.is_nil(config.get('ui.nonexistent'))
    end)

    it('should set nested configuration values', function()
      config.setup()

      config.set('ui.width', 150)
      config.set('ui.highlights.username', 'NewHighlight')

      assert.equals(150, config.get('ui.width'))
      assert.equals('NewHighlight', config.get('ui.highlights.username'))
    end)

    it('should create nested paths when setting', function()
      config.setup()

      config.set('new.nested.path', 'value')
      assert.equals('value', config.get('new.nested.path'))
    end)
  end)

  describe('integrations', function()
    it('should check if integrations are enabled', function()
      config.setup({
        integrations = {
          telescope = true,
          cmp = false,
        },
      })

      assert.is_true(config.is_integration_enabled('telescope'))
      assert.is_false(config.is_integration_enabled('cmp'))
      assert.is_false(config.is_integration_enabled('nonexistent'))
    end)
  end)

  describe('file operations', function()
    local test_file = '/tmp/test_twitch_config.json'

    after_each(function()
      -- Clean up test file
      os.remove(test_file)
    end)

    it('should save configuration to file', function()
      config.setup({
        debug = true,
        ui = { width = 200 },
      })

      local success = config.save_to_file(test_file)
      assert.is_true(success)

      -- Check file exists
      local file = io.open(test_file, 'r')
      assert.is_not_nil(file)
      if file then
        file:close()
      end
    end)

    it('should load configuration from file', function()
      local test_config = {
        debug = true,
        ui = { width = 300 },
      }

      config.setup(test_config)
      config.save_to_file(test_file)

      -- Reset and load
      config.reset()
      local success = config.load_from_file(test_file)
      assert.is_true(success)
      assert.is_true(config.is_debug())
      assert.equals(300, config.get('ui.width'))
    end)

    it('should handle invalid JSON files', function()
      -- Create invalid JSON file
      local file = io.open(test_file, 'w')
      if file then
        file:write('invalid json content')
        file:close()
      end

      local success = config.load_from_file(test_file)
      assert.is_false(success)
    end)
  end)

  describe('import/export', function()
    it('should export configuration', function()
      config.setup({
        debug = true,
        ui = { width = 400 },
      })

      local exported = config.export()
      assert.is_table(exported)
      assert.is_true(exported.debug)
      assert.equals(400, exported.ui.width)
    end)

    it('should import configuration', function()
      local test_config = {
        debug = true,
        ui = { width = 500 },
        auth = {
          client_id = 'test_id',
          redirect_uri = 'http://localhost:3000/callback',
          scopes = { 'chat:read' },
          token_file = '/tmp/test.json',
          auto_refresh = true,
        },
        integrations = {
          telescope = true,
          cmp = true,
          which_key = true,
          notify = true,
          lualine = true,
        },
        chat = {
          default_channel = 'test',
          reconnect_delay = 5000,
          max_reconnect_attempts = 3,
          message_rate_limit = 20,
          ping_interval = 60000,
          ping_timeout = 10000,
        },
        filters = {
          enable_filters = false,
          block_patterns = {},
          allow_patterns = {},
          block_users = {},
          allow_users = {},
          filter_commands = false,
          filter_links = false,
        },
        keymaps = {
          send = '<CR>',
          close = 'q',
        },
      }

      config.reset()
      config.import(test_config)

      assert.is_true(config.is_debug())
      assert.equals(500, config.get('ui.width'))
      assert.equals('test_id', config.get('auth.client_id'))
    end)

    it('should validate imported configuration', function()
      local invalid_config = {
        ui = { position = 'invalid' },
      }

      config.reset()
      config.import(invalid_config)

      -- Should reset to defaults due to validation failure
      assert.equals('center', config.get('ui.position'))
    end)
  end)

  describe('defaults', function()
    it('should return default configuration', function()
      local defaults = config.get_defaults()
      assert.is_table(defaults)
      assert.is_true(defaults.enabled)
      assert.is_false(defaults.debug)
      assert.equals('center', defaults.ui.position)
    end)

    it('should not modify original defaults', function()
      local defaults = config.get_defaults()
      defaults.debug = true

      local defaults2 = config.get_defaults()
      assert.is_false(defaults2.debug)
    end)
  end)

  describe('events', function()
    it('should emit configuration changed event on setup', function()
      local events = require('twitch-chat.events')
      local event_fired = false

      events.on('config_changed', function()
        event_fired = true
      end)

      config.setup({ debug = true })

      assert.is_true(event_fired)
    end)

    it('should emit configuration changed event on set', function()
      local events = require('twitch-chat.events')
      local event_fired = false

      config.setup()

      events.on('config_changed', function()
        event_fired = true
      end)

      config.set('debug', true)

      assert.is_true(event_fired)
    end)
  end)

  describe('directory creation', function()
    it('should create required directories', function()
      local temp_dir = '/tmp/test_twitch_chat'
      local temp_file = temp_dir .. '/token.json'

      -- Clean up first
      os.execute('rm -rf ' .. temp_dir)

      config.setup({
        auth = {
          token_file = temp_file,
        },
      })

      -- Check if directory was created
      local stat = vim.loop.fs_stat(temp_dir)
      assert.is_not_nil(stat)
      assert.equals('directory', stat.type)

      -- Clean up
      os.execute('rm -rf ' .. temp_dir)
    end)
  end)

  describe('type checking', function()
    it('should validate parameter types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.get(123) -- Should be string
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.set(123, 'value') -- Should be string
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.import('not_a_table') -- Should be table
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.save_to_file(123) -- Should be string
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.load_from_file(123) -- Should be string
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        config.is_integration_enabled(123) -- Should be string
      end)
    end)
  end)
end)
