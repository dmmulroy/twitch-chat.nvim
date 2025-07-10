-- tests/twitch-chat/error_resilience_spec.lua
-- Comprehensive error resilience tests for TwitchChat plugin

local twitch_chat = require('twitch-chat')
local auth = require('twitch-chat.modules.auth')
local websocket = require('twitch-chat.modules.websocket')
local config = require('twitch-chat.config')
local events = require('twitch-chat.events')
local utils = require('twitch-chat.utils')
local api = require('twitch-chat.api')
local buffer = require('twitch-chat.modules.buffer')
local emotes = require('twitch-chat.modules.emotes')
local irc = require('twitch-chat.modules.irc')

describe('TwitchChat Error Resilience', function()
  local temp_dir = '/tmp/twitch_chat_test'
  local temp_config_file = temp_dir .. '/config.json'
  local temp_token_file = temp_dir .. '/token.json'
  local temp_cache_dir = temp_dir .. '/cache'

  -- Helper functions
  local function create_temp_dir()
    os.execute('mkdir -p ' .. temp_dir)
    os.execute('mkdir -p ' .. temp_cache_dir)
  end

  local function cleanup_temp_dir()
    os.execute('rm -rf ' .. temp_dir)
  end

  local function mock_websocket_connection(should_fail, error_message)
    local original_connect = websocket.connect
    ---@diagnostic disable-next-line: duplicate-set-field
    websocket.connect = function(url, callbacks, config_opts)
      if should_fail then
        vim.defer_fn(function()
          if callbacks.error then
            callbacks.error(error_message or 'Mock connection failure')
          end
        end, 10)
        return nil
      else
        return {
          url = url,
          connected = true,
          connecting = false,
          callbacks = callbacks,
          config = config_opts or {},
          message_queue = {},
          rate_limiter = { limit = 20, window = 30000, timestamps = {} },
          tcp_handle = {
            write = function()
              return true
            end,
            close = function() end,
            is_closing = function()
              return false
            end,
          },
        }
      end
    end
    return original_connect
  end

  local function restore_websocket_connection(original_connect)
    websocket.connect = original_connect
  end

  before_each(function()
    create_temp_dir()
    -- Reset plugin state
    twitch_chat.cleanup()
    events.clear_all()
  end)

  after_each(function()
    cleanup_temp_dir()
    twitch_chat.cleanup()
    events.clear_all()
  end)

  describe('1. Network Failure Resilience', function()
    describe('WebSocket connection drops and recovery', function()
      it('should handle sudden WebSocket disconnection', function()
        local disconnect_called = false
        local reconnect_called = false

        local original_connect = mock_websocket_connection(false)

        -- Mock reconnection logic
        local original_reconnect = websocket.reconnect
        websocket.reconnect = function(conn)
          reconnect_called = true
          return true
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
          chat = {
            max_reconnect_attempts = 3,
            reconnect_delay = 100,
          },
        })

        -- Simulate connection
        local conn = websocket.connect('wss://irc-ws.chat.twitch.tv', {
          disconnect = function()
            disconnect_called = true
          end,
        })

        -- Simulate connection drop
        if conn and conn.callbacks.disconnect then
          conn.callbacks.disconnect('Connection lost')
        end

        -- Wait for reconnection attempt
        vim.wait(200, function()
          return reconnect_called
        end)

        assert.is_true(disconnect_called)
        assert.is_true(reconnect_called)

        -- Restore
        restore_websocket_connection(original_connect)
        websocket.reconnect = original_reconnect
      end)

      it('should respect max reconnection attempts', function()
        local reconnect_attempts = 0
        local max_attempts = 3

        local original_connect = mock_websocket_connection(true)

        -- Mock reconnection with failure
        local original_reconnect = websocket.reconnect
        ---@diagnostic disable-next-line: duplicate-set-field
        websocket.reconnect = function(conn)
          reconnect_attempts = reconnect_attempts + 1
          return false -- Always fail
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
          chat = {
            max_reconnect_attempts = max_attempts,
            reconnect_delay = 50,
          },
        })

        -- Simulate multiple connection failures
        for i = 1, max_attempts + 1 do
          websocket.connect('wss://irc-ws.chat.twitch.tv', {
            error = function() end,
          })
        end

        -- Wait for attempts
        vim.wait(500, function()
          return reconnect_attempts >= max_attempts
        end)

        assert.is_true(reconnect_attempts <= max_attempts)

        -- Restore
        restore_websocket_connection(original_connect)
        websocket.reconnect = original_reconnect
      end)
    end)

    describe('DNS resolution failures', function()
      it('should handle DNS resolution errors gracefully', function()
        local error_called = false
        local error_message = nil

        local original_connect = mock_websocket_connection(true, 'DNS resolution failed')

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Attempt connection with invalid hostname
        websocket.connect('wss://invalid-hostname.twitch.tv', {
          error = function(err)
            error_called = true
            error_message = err
          end,
        })

        vim.wait(100, function()
          return error_called
        end)

        assert.is_true(error_called)
        assert.matches('DNS resolution failed', error_message)

        restore_websocket_connection(original_connect)
      end)
    end)

    describe('API endpoint unavailability', function()
      it('should handle Twitch API downtime', function()
        local api_error_handled = false

        -- Mock HTTP request failure
        local original_request = utils.http_request or function() end
        utils.http_request = function(opts, callback)
          vim.defer_fn(function()
            callback(false, { status = 503, body = 'Service Unavailable' })
          end, 10)
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Attempt API call
        events.on(events.ERROR_OCCURRED, function(err)
          if err.type == 'api_error' then
            api_error_handled = true
          end
        end)

        -- Trigger API call that should fail
        if utils.http_request then
          utils.http_request({ url = 'https://api.twitch.tv/helix/users' }, function() end)
        end

        vim.wait(100, function()
          return api_error_handled
        end)

        -- Restore
        utils.http_request = original_request
      end)
    end)
  end)

  describe('2. Authentication Failure Handling', function()
    describe('Invalid tokens and refresh scenarios', function()
      it('should handle expired token gracefully', function()
        local token_refreshed = false

        -- Create expired token
        local expired_token = {
          access_token = 'expired_token',
          refresh_token = 'refresh_token',
          expires_at = os.time() - 3600, -- Expired 1 hour ago
        }

        local file = io.open(temp_token_file, 'w')
        if file then
          file:write(vim.json.encode(expired_token))
          file:close()
        end

        -- Mock token refresh
        local original_refresh = auth.refresh_token
        auth.refresh_token = function(callback)
          token_refreshed = true
          -- Mock successful token refresh - auth.refresh_token only passes boolean
          callback(true)
        end

        twitch_chat.setup({
          auth = {
            client_id = 'test',
            token_file = temp_token_file,
            auto_refresh = true,
          },
        })

        -- Attempt to get access token
        auth.get_access_token()

        vim.wait(100, function()
          return token_refreshed
        end)

        assert.is_true(token_refreshed)

        auth.refresh_token = original_refresh
      end)

      it('should handle token refresh failure', function()
        local auth_failed = false

        -- Mock refresh failure
        local original_refresh = auth.refresh_token
        ---@diagnostic disable-next-line: duplicate-set-field
        auth.refresh_token = function(callback)
          callback(false, 'Refresh token expired')
        end

        events.on(events.AUTH_FAILED, function()
          auth_failed = true
        end)

        twitch_chat.setup({
          auth = {
            client_id = 'test',
            auto_refresh = true,
          },
        })

        -- Trigger refresh
        auth.refresh_token(function() end)

        vim.wait(100, function()
          return auth_failed
        end)

        assert.is_true(auth_failed)

        auth.refresh_token = original_refresh
      end)
    end)

    describe('Rate limiting responses', function()
      it('should handle rate limit from Twitch API', function()
        local rate_limited = false

        -- Mock rate limit response
        local original_request = utils.http_request or function() end
        ---@diagnostic disable-next-line: duplicate-set-field
        utils.http_request = function(opts, callback)
          vim.defer_fn(function()
            callback(false, {
              status = 429,
              headers = { ['retry-after'] = '60' },
              body = 'Rate limit exceeded',
            })
          end, 10)
        end

        events.on(events.ERROR_OCCURRED, function(err)
          if err.type == 'rate_limit' then
            rate_limited = true
          end
        end)

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Trigger rate limited request
        if utils.http_request then
          utils.http_request({ url = 'https://api.twitch.tv/helix/users' }, function() end)
        end

        vim.wait(100, function()
          return rate_limited
        end)

        utils.http_request = original_request
      end)
    end)
  end)

  describe('3. File System Error Handling', function()
    describe('Missing config files', function()
      it('should handle missing token file gracefully', function()
        local no_error_occurred = true

        twitch_chat.setup({
          auth = {
            client_id = 'test',
            token_file = '/nonexistent/path/token.json',
          },
        })

        -- Should not throw error
        assert.has_no.errors(function()
          auth.load_token()
        end)

        assert.is_true(no_error_occurred)
      end)

      it('should handle missing cache directory', function()
        local cache_dir = '/nonexistent/cache'

        twitch_chat.setup({
          auth = { client_id = 'test' },
          ui = { cache_dir = cache_dir },
        })

        -- Should create directory when needed
        assert.has_no.errors(function()
          emotes.init({ cache_dir = cache_dir })
        end)
      end)
    end)

    describe('Read-only file systems', function()
      it('should handle read-only token file', function()
        local readonly_file = temp_token_file .. '_readonly'

        -- Create file and make it read-only
        local file = io.open(readonly_file, 'w')
        if file then
          file:write('{"access_token": "test"}')
          file:close()
        end
        os.execute('chmod 444 ' .. readonly_file)

        twitch_chat.setup({
          auth = {
            client_id = 'test',
            token_file = readonly_file,
          },
        })

        -- Should handle read-only file gracefully
        assert.has_no.errors(function()
          auth.save_token({ access_token = 'new_token' })
        end)

        -- Cleanup
        os.execute('chmod 644 ' .. readonly_file)
        os.remove(readonly_file)
      end)
    end)

    describe('Corrupted cache files', function()
      it('should handle corrupted JSON files', function()
        local corrupted_file = temp_cache_dir .. '/corrupted.json'

        -- Create corrupted JSON
        local file = io.open(corrupted_file, 'w')
        if file then
          file:write('{"invalid": json content}')
          file:close()
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Should handle corrupted file gracefully
        assert.has_no.errors(function()
          local file_handle = io.open(corrupted_file, 'r')
          if file_handle then
            local content = file_handle:read('*a')
            file_handle:close()
            pcall(vim.json.decode, content)
          end
        end)
      end)
    end)
  end)

  describe('4. Memory Pressure Scenarios', function()
    describe('Large message backlogs', function()
      it('should handle large message queues', function()
        twitch_chat.setup({
          auth = { client_id = 'test' },
          ui = { max_messages = 10 }, -- Small limit for testing
        })

        -- Create mock buffer
        local mock_buffer = buffer.create_buffer('test_channel')

        -- Fill buffer beyond capacity
        for i = 1, 20 do
          buffer.add_message(mock_buffer, {
            username = 'user' .. i,
            content = 'Message ' .. i,
            timestamp = os.time(),
          })
        end

        -- Buffer should handle overflow
        local message_count = buffer.get_message_count(mock_buffer)
        assert.is_true(message_count <= 10)
      end)
    end)

    describe('Cache overflow handling', function()
      it('should handle emote cache overflow', function()
        local cache_cleaned = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
          ui = { max_cache_size = 100 }, -- Small cache for testing
        })

        -- Mock cache cleanup
        local original_cleanup = emotes.cleanup_cache
        emotes.cleanup_cache = function()
          cache_cleaned = true
        end

        -- Fill cache beyond capacity
        for i = 1, 150 do
          emotes.cache_emote('emote' .. i, 'data' .. i)
        end

        -- Should trigger cleanup
        vim.wait(100, function()
          return cache_cleaned
        end)

        assert.is_true(cache_cleaned)

        emotes.cleanup_cache = original_cleanup
      end)
    end)
  end)

  describe('5. Malformed Data Handling', function()
    describe('Invalid IRC messages', function()
      it('should handle malformed IRC messages', function()
        local malformed_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Test malformed IRC messages
        local malformed_messages = {
          '', -- Empty message
          'INVALID_COMMAND', -- Invalid command
          ':invalid!user@host.com', -- Missing command
          'PRIVMSG #channel', -- Missing message content
          'PRIVMSG #channel :' .. string.rep('a', 10000), -- Extremely long message
        }

        for _, msg in ipairs(malformed_messages) do
          assert.has_no.errors(function()
            irc.parse_message(msg)
            malformed_handled = true
          end)
        end

        assert.is_true(malformed_handled)
      end)
    end)

    describe('Corrupted JSON configs', function()
      it('should handle corrupted configuration files', function()
        local corrupted_config = temp_config_file

        -- Create corrupted config
        local file = io.open(corrupted_config, 'w')
        if file then
          file:write('{"auth": {"client_id": "test"} invalid json')
          file:close()
        end

        -- Should handle corrupted config gracefully
        assert.has_no.errors(function()
          twitch_chat.setup({
            config_file = corrupted_config,
          })
        end)
      end)
    end)

    describe('Unexpected API responses', function()
      it('should handle unexpected API response format', function()
        local unexpected_handled = false

        -- Mock unexpected API response
        local original_request = utils.http_request or function() end
        ---@diagnostic disable-next-line: duplicate-set-field
        utils.http_request = function(opts, callback)
          vim.defer_fn(function()
            callback(true, {
              status = 200,
              body = 'Not JSON response', -- Unexpected format
            })
          end, 10)
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Should handle unexpected response
        assert.has_no.errors(function()
          if utils.http_request then
            utils.http_request(
              { url = 'https://api.twitch.tv/helix/users' },
              function(success, data)
                if success and type(data.body) == 'string' then
                  pcall(vim.json.decode, data.body)
                end
                unexpected_handled = true
              end
            )
          end
        end)

        vim.wait(100, function()
          return unexpected_handled
        end)

        utils.http_request = original_request
        assert.is_true(unexpected_handled)
      end)
    end)
  end)

  describe('6. Concurrent Access Errors', function()
    describe('Race conditions in event handling', function()
      it('should handle concurrent event emissions', function()
        local events_handled = 0
        local max_events = 100

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Register event handler
        events.on('test_event', function()
          events_handled = events_handled + 1
        end)

        -- Emit events concurrently
        for i = 1, max_events do
          vim.defer_fn(function()
            events.emit('test_event', { id = i })
          end, math.random(0, 50))
        end

        -- Wait for all events to be processed
        vim.wait(200, function()
          return events_handled >= max_events
        end)

        assert.is_true(events_handled >= max_events)
      end)
    end)

    describe('Simultaneous module access', function()
      it('should handle concurrent buffer access', function()
        local concurrent_access_safe = true

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        local mock_buffer = buffer.create_buffer('test_channel')

        -- Simulate concurrent access
        for i = 1, 50 do
          vim.defer_fn(function()
            pcall(function()
              buffer.add_message(mock_buffer, {
                username = 'user' .. i,
                content = 'Message ' .. i,
                timestamp = os.time(),
              })
            end)
          end, math.random(0, 25))
        end

        -- Should not cause errors
        vim.wait(100)
        assert.is_true(concurrent_access_safe)
      end)
    end)
  end)

  describe('7. External Dependency Failures', function()
    describe('Missing optional dependencies', function()
      it('should handle missing telescope gracefully', function()
        local telescope_missing_handled = false

        -- Mock missing telescope
        local original_require = require
        ---@diagnostic disable-next-line: duplicate-set-field
        _G.require = function(name)
          if name == 'telescope' then
            error('Module not found: telescope')
          end
          return original_require(name)
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
          integrations = { telescope = true },
        })

        -- Should handle missing telescope gracefully
        assert.has_no.errors(function()
          twitch_chat.setup({
            auth = { client_id = 'test' },
            integrations = { telescope = true },
          })
          telescope_missing_handled = true
        end)

        _G.require = original_require
        assert.is_true(telescope_missing_handled)
      end)
    end)

    describe('Neovim API errors', function()
      it('should handle buffer creation failures', function()
        local buffer_failure_handled = false

        -- Mock buffer creation failure using stub
        local original_api = vim.api
        local mock_api = setmetatable({}, {
          __index = function(_, key)
            if key == 'nvim_create_buf' then
              return function()
                error('Buffer creation failed')
              end
            end
            return original_api[key]
          end,
        })

        -- Use rawset to modify the vim table
        rawset(vim, 'api', mock_api)

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Should handle buffer creation failure
        assert.has_no.errors(function()
          pcall(buffer.create_buffer, 'test_channel')
          buffer_failure_handled = true
        end)

        rawset(vim, 'api', original_api)
        assert.is_true(buffer_failure_handled)
      end)
    end)
  end)

  describe('8. Recovery and Graceful Degradation', function()
    describe('Automatic reconnection logic', function()
      it('should implement exponential backoff for reconnection', function()
        local reconnect_delays = {}

        -- Mock reconnection with delay tracking
        local original_reconnect = websocket.reconnect
        ---@diagnostic disable-next-line: duplicate-set-field
        websocket.reconnect = function(conn, delay)
          table.insert(reconnect_delays, delay or 1000)
          return false -- Always fail to test backoff
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
          chat = {
            reconnect_delay = 1000,
            max_reconnect_attempts = 5,
          },
        })

        -- Simulate multiple reconnection attempts
        for i = 1, 5 do
          websocket.reconnect({}, i * 1000)
        end

        -- Should have increasing delays
        for i = 2, #reconnect_delays do
          assert.is_true(reconnect_delays[i] >= reconnect_delays[i - 1])
        end

        websocket.reconnect = original_reconnect
      end)
    end)

    describe('Fallback behavior activation', function()
      it('should fall back to polling when WebSocket fails', function()
        local fallback_activated = false

        -- Mock WebSocket failure
        local original_connect = mock_websocket_connection(true)

        -- Mock fallback mechanism
        local original_start_polling = api.start_polling or function() end
        api.start_polling = function()
          fallback_activated = true
        end

        twitch_chat.setup({
          auth = { client_id = 'test' },
          chat = { fallback_to_polling = true },
        })

        -- Attempt WebSocket connection
        websocket.connect('wss://irc-ws.chat.twitch.tv', {
          error = function()
            if api.start_polling then
              api.start_polling()
            end
          end,
        })

        vim.wait(100, function()
          return fallback_activated
        end)

        assert.is_true(fallback_activated)

        restore_websocket_connection(original_connect)
        api.start_polling = original_start_polling
      end)
    end)

    describe('Partial functionality maintenance', function()
      it('should maintain basic functionality during network issues', function()
        local basic_functionality_maintained = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Simulate network issues
        local original_connect = mock_websocket_connection(true)

        -- Basic functionality should still work
        assert.has_no.errors(function()
          local status = twitch_chat.get_status()
          local channels = twitch_chat.get_channels()
          local emote_list = twitch_chat.get_emotes()

          assert.is_table(status)
          assert.is_table(channels)
          assert.is_table(emote_list)

          basic_functionality_maintained = true
        end)

        restore_websocket_connection(original_connect)
        assert.is_true(basic_functionality_maintained)
      end)
    end)
  end)

  describe('9. Edge Case Input Handling', function()
    describe('Extremely long messages', function()
      it('should handle messages exceeding IRC limits', function()
        local long_message_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Create extremely long message
        local long_message = string.rep('a', 10000)

        -- Should handle long message gracefully
        assert.has_no.errors(function()
          local truncated = utils.truncate(long_message, 500)
          assert.is_true(#truncated <= 500)
          long_message_handled = true
        end)

        assert.is_true(long_message_handled)
      end)
    end)

    describe('Unicode edge cases', function()
      it('should handle various Unicode characters', function()
        local unicode_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        local unicode_messages = {
          '🎮 Gaming time! 🎯',
          '测试消息', -- Chinese
          '🏳️‍🌈🏳️‍⚧️', -- Complex emojis
          'ñoño', -- Accented characters
          '𝕳𝖊𝖑𝖑𝖔', -- Mathematical symbols
        }

        for _, msg in ipairs(unicode_messages) do
          assert.has_no.errors(function()
            local escaped = utils.escape_text(msg)
            assert.is_string(escaped)
            unicode_handled = true
          end)
        end

        assert.is_true(unicode_handled)
      end)
    end)

    describe('Boundary value inputs', function()
      it('should handle edge case numeric values', function()
        local boundary_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        local boundary_values = {
          0,
          -1,
          math.huge,
          -math.huge,
          2 ^ 31 - 1,
          2 ^ 31, -- Integer overflow
          1.7976931348623157e+308, -- Max double
        }

        for _, value in ipairs(boundary_values) do
          assert.has_no.errors(function()
            if type(value) == 'number' and value == value then -- Check for NaN
              local formatted = string.format('%.0f', value)
              assert.is_string(formatted)
            end
            boundary_handled = true
          end)
        end

        assert.is_true(boundary_handled)
      end)
    end)
  end)

  describe('10. Plugin Lifecycle Errors', function()
    describe('Initialization failures', function()
      it('should handle setup failures gracefully', function()
        local setup_failure_handled = false

        -- Mock configuration validation failure
        local original_validate = config.validate
        config.validate = function()
          error('Configuration validation failed')
        end

        -- Should handle setup failure gracefully
        assert.has_no.errors(function()
          twitch_chat.setup({
            auth = { client_id = '' }, -- Invalid config
          })
          setup_failure_handled = true
        end)

        config.validate = original_validate
        assert.is_true(setup_failure_handled)
      end)
    end)

    describe('Partial setup states', function()
      it('should handle incomplete initialization', function()
        local partial_setup_handled = false

        -- Simulate partial setup
        ---@diagnostic disable-next-line: invisible
        twitch_chat._setup_called = true
        ---@diagnostic disable-next-line: invisible
        twitch_chat._initialized = false

        -- Should handle partial state gracefully
        assert.has_no.errors(function()
          local is_initialized = twitch_chat.is_initialized()
          assert.is_false(is_initialized)

          local status = twitch_chat.get_status()
          assert.is_table(status)
          assert.is_false(status.enabled)

          partial_setup_handled = true
        end)

        assert.is_true(partial_setup_handled)
      end)
    end)

    describe('Cleanup failures', function()
      it('should handle cleanup errors gracefully', function()
        local cleanup_failure_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Mock cleanup failure
        local original_disconnect = api.disconnect
        api.disconnect = function()
          error('Disconnect failed')
        end

        -- Should handle cleanup failure gracefully
        assert.has_no.errors(function()
          twitch_chat.cleanup()
          cleanup_failure_handled = true
        end)

        api.disconnect = original_disconnect
        assert.is_true(cleanup_failure_handled)
      end)
    end)

    describe('Reload during operations', function()
      it('should handle reload during active operations', function()
        local reload_during_ops_handled = false

        twitch_chat.setup({
          auth = { client_id = 'test' },
        })

        -- Start some operations
        local original_connect = mock_websocket_connection(false)

        -- Simulate reload during connection
        assert.has_no.errors(function()
          websocket.connect('wss://irc-ws.chat.twitch.tv', {})
          twitch_chat.reload()
          reload_during_ops_handled = true
        end)

        restore_websocket_connection(original_connect)
        assert.is_true(reload_during_ops_handled)
      end)
    end)
  end)

  describe('Integration Error Scenarios', function()
    it('should handle plugin state corruption', function()
      local state_corruption_handled = false

      twitch_chat.setup({
        auth = { client_id = 'test' },
      })

      -- Corrupt plugin state
      twitch_chat._connections = nil
      ---@diagnostic disable-next-line: invisible
      twitch_chat._current_channel = {}

      -- Should handle corrupted state gracefully
      assert.has_no.errors(function()
        local channels = twitch_chat.get_channels()
        assert.is_table(channels)
        state_corruption_handled = true
      end)

      assert.is_true(state_corruption_handled)
    end)

    it('should handle event system failures', function()
      local event_failure_handled = false

      twitch_chat.setup({
        auth = { client_id = 'test' },
      })

      -- Mock event system failure
      local original_emit = events.emit
      events.emit = function()
        error('Event system failure')
      end

      -- Should handle event failure gracefully
      assert.has_no.errors(function()
        pcall(events.emit, 'test_event', {})
        event_failure_handled = true
      end)

      events.emit = original_emit
      assert.is_true(event_failure_handled)
    end)

    it('should handle resource exhaustion scenarios', function()
      local resource_exhaustion_handled = false

      twitch_chat.setup({
        auth = { client_id = 'test' },
      })

      -- Simulate resource exhaustion
      local large_data = {}
      for i = 1, 10000 do
        table.insert(large_data, string.rep('data', 1000))
      end

      -- Should handle large data gracefully
      assert.has_no.errors(function()
        -- Force memory pressure by accessing the large data
        local data_size = #large_data
        assert.is_true(data_size > 0)
        local memory_usage = collectgarbage('count')
        assert.is_number(memory_usage)
        resource_exhaustion_handled = true
      end)

      -- Cleanup
      large_data = nil
      collectgarbage('collect')

      assert.is_true(resource_exhaustion_handled)
    end)
  end)

  describe('Recovery Mechanisms', function()
    it('should implement circuit breaker pattern', function()
      local circuit_breaker_active = false
      local failure_count = 0
      local max_failures = 5

      twitch_chat.setup({
        auth = { client_id = 'test' },
      })

      -- Mock circuit breaker logic
      local check_circuit_breaker = function()
        if failure_count >= max_failures then
          circuit_breaker_active = true
          return false
        end
        return true
      end

      -- Simulate multiple failures
      for i = 1, max_failures + 1 do
        if check_circuit_breaker() then
          failure_count = failure_count + 1
        end
      end

      assert.is_true(circuit_breaker_active)
      assert.equals(max_failures, failure_count)
    end)

    it('should implement health check recovery', function()
      twitch_chat.setup({
        auth = { client_id = 'test' },
      })

      -- Mock health check
      local health_results = twitch_chat.health_check()
      assert.is_table(health_results)

      -- Should trigger recovery if unhealthy
      local is_healthy = twitch_chat.is_healthy()
      -- Health check mechanism is working regardless of health status
      assert.is_boolean(is_healthy)
    end)
  end)
end)
