-- tests/twitch-chat/integration_spec.lua
-- Full integration tests

local twitch_chat = require('twitch-chat')

describe('TwitchChat Integration Tests', function()
  local test_config = {
    enabled = true,
    debug = true,
    auth = {
      client_id = 'test_client_id',
      redirect_uri = 'http://localhost:3000/callback',
      scopes = { 'chat:read', 'chat:edit' },
      token_file = '/tmp/test_twitch_token.json',
      auto_refresh = false,
    },
    ui = {
      width = 80,
      height = 20,
      position = 'center',
      border = 'rounded',
      max_messages = 100,
      auto_scroll = true,
    },
    chat = {
      default_channel = 'test_channel',
      reconnect_delay = 1000,
      max_reconnect_attempts = 3,
      message_rate_limit = 20,
    },
    integrations = {
      telescope = false,
      cmp = false,
      which_key = false,
      notify = false,
      lualine = false,
    },
  }

  before_each(function()
    -- Clean up any existing state
    if twitch_chat.is_initialized() then
      twitch_chat.reload()
    end

    -- Clean up test files
    os.remove('/tmp/test_twitch_token.json')
  end)

  after_each(function()
    -- Clean up
    os.remove('/tmp/test_twitch_token.json')
  end)

  describe('plugin initialization', function()
    it('should initialize plugin successfully', function()
      assert.has_no.errors(function()
        twitch_chat.setup(test_config)
      end)

      assert.is_true(twitch_chat.is_initialized())
    end)

    it('should handle multiple setup calls gracefully', function()
      twitch_chat.setup(test_config)

      -- Second setup should warn but not error
      assert.has_no.errors(function()
        twitch_chat.setup(test_config)
      end)
    end)

    it('should initialize with minimal config', function()
      local minimal_config = {
        auth = {
          client_id = 'test_client_id',
        },
      }

      assert.has_no.errors(function()
        twitch_chat.setup(minimal_config)
      end)

      assert.is_true(twitch_chat.is_initialized())
    end)
  end)

  describe('plugin information', function()
    it('should provide correct plugin information', function()
      twitch_chat.setup(test_config)

      local info = twitch_chat.get_info()

      assert.is_table(info)
      assert.equals('twitch-chat.nvim', info.name)
      assert.is_string(info.version)
      assert.is_string(info.author)
      assert.is_string(info.license)
      assert.is_string(info.repository)
      assert.is_true(info.initialized)
      assert.is_true(info.setup_called)
      assert.is_number(info.uptime)
    end)

    it('should report correct version', function()
      local version = twitch_chat.get_version()
      assert.is_string(version)
      assert.matches('%d+%.%d+%.%d+', version) -- Semantic version pattern
    end)

    it('should track uptime', function()
      local uptime1 = twitch_chat.get_uptime()

      -- Wait a bit
      vim.wait(100)

      local uptime2 = twitch_chat.get_uptime()

      assert.is_number(uptime1)
      assert.is_number(uptime2)
      assert.is_true(uptime2 >= uptime1)
    end)
  end)

  describe('health checks', function()
    it('should run health checks', function()
      twitch_chat.setup(test_config)

      local health_results = twitch_chat.health_check()

      assert.is_table(health_results)
      assert.is_true(#health_results > 0)

      -- Check structure of health results
      for _, result in ipairs(health_results) do
        assert.is_string(result.name)
        assert.is_string(result.status) -- 'ok', 'warning', 'error'
        assert.is_string(result.message)
      end
    end)

    it('should report health status', function()
      twitch_chat.setup(test_config)

      local is_healthy = twitch_chat.is_healthy()
      assert.is_boolean(is_healthy)
    end)
  end)

  describe('configuration integration', function()
    it('should access configuration through plugin API', function()
      twitch_chat.setup(test_config)

      local status = twitch_chat.get_status()

      assert.is_table(status)
      assert.is_boolean(status.enabled)
      assert.is_boolean(status.debug)
      assert.is_table(status.channels)
    end)

    it('should handle debug mode toggle', function()
      twitch_chat.setup(test_config)

      assert.has_no.errors(function()
        twitch_chat.toggle_debug()
      end)
    end)
  end)

  describe('event system integration', function()
    it('should allow event registration and emission', function()
      twitch_chat.setup(test_config)

      local event_received = false
      local event_data = nil

      twitch_chat.on('test_event', function(data)
        event_received = true
        event_data = data
      end)

      twitch_chat.emit('test_event', { message = 'test' })

      assert.is_true(event_received)
      assert.is_table(event_data)
      if event_data then
        assert.equals('test', event_data.message)
      end
    end)

    it('should handle multiple event listeners', function()
      twitch_chat.setup(test_config)

      local listener1_called = false
      local listener2_called = false

      twitch_chat.on('multi_event', function()
        listener1_called = true
      end)

      twitch_chat.on('multi_event', function()
        listener2_called = true
      end)

      twitch_chat.emit('multi_event')

      assert.is_true(listener1_called)
      assert.is_true(listener2_called)
    end)
  end)

  describe('connection workflow', function()
    it('should handle connection attempt', function()
      twitch_chat.setup(test_config)

      -- Mock authentication
      local auth = require('twitch-chat.modules.auth')
      auth.current_token = {
        access_token = 'mock_token',
        expires_at = os.time() + 3600,
      }

      local success = twitch_chat.connect('test_channel')

      -- Should initiate connection (may not succeed without real network)
      assert.is_boolean(success)
    end)

    it('should report connection status', function()
      twitch_chat.setup(test_config)

      local is_connected = twitch_chat.is_connected('test_channel')
      assert.is_boolean(is_connected)

      local current_channel = twitch_chat.get_current_channel()
      assert.is_true(current_channel == nil or type(current_channel) == 'string')
    end)

    it('should handle disconnection', function()
      twitch_chat.setup(test_config)

      local success = twitch_chat.disconnect('test_channel')
      assert.is_boolean(success)
    end)
  end)

  describe('channel management integration', function()
    it('should get channels list', function()
      twitch_chat.setup(test_config)

      local channels = twitch_chat.get_channels()
      assert.is_table(channels)
    end)

    it('should handle channel switching', function()
      twitch_chat.setup(test_config)

      local success = twitch_chat.switch_channel('test_channel')
      assert.is_boolean(success)
    end)
  end)

  describe('message handling integration', function()
    it('should handle message sending', function()
      twitch_chat.setup(test_config)

      -- Mock authentication and connection
      local auth = require('twitch-chat.modules.auth')
      auth.current_token = {
        access_token = 'mock_token',
        expires_at = os.time() + 3600,
      }

      local api = require('twitch-chat.api')
      ---@diagnostic disable-next-line: invisible
      api._current_channel = 'test_channel'

      local success = twitch_chat.send_message('Hello, world!')
      assert.is_boolean(success)
    end)

    it('should handle message sending without active channel', function()
      twitch_chat.setup(test_config)

      local success = twitch_chat.send_message('Hello, world!')
      assert.is_false(success) -- Should fail without active channel
    end)
  end)

  describe('emote integration', function()
    it('should handle emote operations', function()
      twitch_chat.setup(test_config)

      local emotes = twitch_chat.get_emotes()
      assert.is_table(emotes)

      local success = twitch_chat.insert_emote('Kappa')
      assert.is_boolean(success)
    end)
  end)

  describe('plugin lifecycle', function()
    it('should handle plugin reload', function()
      twitch_chat.setup(test_config)

      assert.is_true(twitch_chat.is_initialized())

      assert.has_no.errors(function()
        twitch_chat.reload()
      end)

      assert.is_true(twitch_chat.is_initialized())
    end)

    it('should handle reload without initial setup', function()
      assert.has_no.errors(function()
        twitch_chat.reload()
      end)
    end)
  end)

  describe('error handling and recovery', function()
    it('should handle API calls before initialization', function()
      -- Ensure plugin is not initialized
      if twitch_chat.is_initialized() then
        twitch_chat.cleanup()
      end

      -- These should return false/empty but not error
      assert.is_false(twitch_chat.connect('test_channel'))
      assert.is_false(twitch_chat.disconnect('test_channel'))
      assert.is_false(twitch_chat.send_message('test'))
      assert.equals(0, #twitch_chat.get_channels())
      assert.is_nil(twitch_chat.get_current_channel())
      assert.is_false(twitch_chat.switch_channel('test'))
      assert.is_false(twitch_chat.is_connected('test'))
    end)

    it('should handle invalid configuration gracefully', function()
      local invalid_config = {
        auth = {
          client_id = '', -- Invalid empty client_id
        },
        ui = {
          position = 'invalid_position',
          width = 'not_a_number',
        },
      }

      assert.has_no.errors(function()
        twitch_chat.setup(invalid_config)
      end)

      -- Should still be able to call functions
      local status = twitch_chat.get_status()
      assert.is_table(status)
    end)
  end)

  describe('buffer integration', function()
    it('should create and manage chat buffers', function()
      twitch_chat.setup(test_config)

      local buffer_module = require('twitch-chat.modules.buffer')

      -- Create a test buffer
      local chat_buffer = buffer_module.create_chat_buffer('test_channel')

      assert.is_not_nil(chat_buffer)
      assert.equals('test_channel', chat_buffer.channel)
      assert.is_number(chat_buffer.bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(chat_buffer.bufnr))

      -- Add a test message
      local test_message = {
        id = 'test_msg_1',
        username = 'test_user',
        content = 'Hello from integration test!',
        timestamp = os.time(),
        badges = {},
        emotes = {},
        channel = 'test_channel',
      }

      buffer_module.add_message('test_channel', test_message)

      -- Wait for message processing
      vim.wait(100, function()
        return #chat_buffer.messages > 0
      end)

      assert.equals(1, #chat_buffer.messages)
      assert.equals(test_message, chat_buffer.messages[1])

      -- Clean up
      buffer_module.cleanup_buffer('test_channel')
    end)
  end)

  describe('stress testing', function()
    it('should handle rapid configuration changes', function()
      for i = 1, 10 do
        local config = vim.tbl_extend('force', test_config, {
          debug = i % 2 == 0,
          ui = { width = 80 + i },
        })

        assert.has_no.errors(function()
          twitch_chat.setup(config)
        end)
      end

      assert.is_true(twitch_chat.is_initialized())
    end)

    it('should handle multiple event emissions', function()
      twitch_chat.setup(test_config)

      local event_count = 0

      twitch_chat.on('stress_test_event', function()
        event_count = event_count + 1
      end)

      -- Emit many events rapidly
      for i = 1, 100 do
        twitch_chat.emit('stress_test_event', { iteration = i })
      end

      assert.equals(100, event_count)
    end)
  end)

  describe('memory management', function()
    it('should not leak memory with repeated setup/reload', function()
      local initial_memory = collectgarbage('count')

      for i = 1, 10 do
        twitch_chat.setup(test_config)
        twitch_chat.reload()

        -- Force garbage collection
        collectgarbage('collect')
      end

      local final_memory = collectgarbage('count')

      -- Memory should not grow significantly (allowing for some variance)
      local memory_growth = final_memory - initial_memory
      assert.is_true(memory_growth < 1000) -- Less than 1MB growth
    end)
  end)

  describe('concurrency handling', function()
    it('should handle concurrent operations safely', function()
      twitch_chat.setup(test_config)

      local results = {}
      local completed = 0

      -- Start multiple async operations
      for i = 1, 5 do
        vim.defer_fn(function()
          local status = twitch_chat.get_status()
          table.insert(results, status)
          completed = completed + 1
        end, i * 10)
      end

      -- Wait for all operations to complete
      vim.wait(200, function()
        return completed == 5
      end)

      assert.equals(5, #results)

      -- All results should be valid
      for _, result in ipairs(results) do
        assert.is_table(result)
        assert.is_boolean(result.enabled)
      end
    end)
  end)

  describe('edge cases', function()
    it('should handle empty string inputs', function()
      twitch_chat.setup(test_config)

      assert.is_false(twitch_chat.connect(''))
      assert.is_false(twitch_chat.disconnect(''))
      assert.is_false(twitch_chat.send_message(''))
      assert.is_false(twitch_chat.switch_channel(''))
      assert.is_false(twitch_chat.is_connected(''))
    end)

    it('should handle nil inputs gracefully', function()
      twitch_chat.setup(test_config)

      assert.has_no.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        twitch_chat.connect(nil)
        twitch_chat.disconnect(nil)
        ---@diagnostic disable-next-line: param-type-mismatch
        twitch_chat.send_message(nil)
        ---@diagnostic disable-next-line: param-type-mismatch
        twitch_chat.switch_channel(nil)
        ---@diagnostic disable-next-line: param-type-mismatch
        twitch_chat.is_connected(nil)
      end)
    end)

    it('should handle very long strings', function()
      twitch_chat.setup(test_config)

      local long_string = string.rep('a', 10000)

      assert.has_no.errors(function()
        twitch_chat.connect(long_string)
        twitch_chat.send_message(long_string)
        twitch_chat.switch_channel(long_string)
      end)
    end)
  end)

  describe('plugin state consistency', function()
    it('should maintain consistent state across operations', function()
      twitch_chat.setup(test_config)

      -- Check initial state
      assert.is_true(twitch_chat.is_initialized())

      local initial_status = twitch_chat.get_status()
      assert.is_table(initial_status)

      -- Perform various operations
      twitch_chat.toggle_debug()
      twitch_chat.get_channels()
      twitch_chat.get_current_channel()

      -- State should still be consistent
      assert.is_true(twitch_chat.is_initialized())

      local final_status = twitch_chat.get_status()
      assert.is_table(final_status)

      -- Core properties should remain stable
      assert.equals(initial_status.enabled, final_status.enabled)
    end)
  end)
end)
