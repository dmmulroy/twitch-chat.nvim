-- tests/twitch-chat/filter_spec.lua
-- Filter tests

local filter = require('twitch-chat.modules.filter')

describe('TwitchChat Filter', function()
  local mock_config
  local mock_events
  local mock_utils
  local original_modules
  local test_time
  local original_os_time
  local original_vim_loop_hrtime
  local original_vim_fn_stdpath
  local original_vim_fn_json_encode
  local original_vim_fn_json_decode

  before_each(function()
    -- Save original modules
    original_modules = {
      config = package.loaded['twitch-chat.config'],
      events = package.loaded['twitch-chat.events'],
      utils = package.loaded['twitch-chat.utils'],
    }

    -- Mock test time
    test_time = 1234567890

    -- Mock config module
    mock_config = {
      get = function(key)
        return nil
      end,
      is_debug = function()
        return false
      end,
    }
    package.loaded['twitch-chat.config'] = mock_config

    -- Mock events module
    mock_events = {
      MESSAGE_RECEIVED = 'message_received',
      listeners = {},
      on = function(event, callback)
        if not mock_events.listeners[event] then
          mock_events.listeners[event] = {}
        end
        table.insert(mock_events.listeners[event], callback)
      end,
      emit = function(event, data)
        if mock_events.listeners[event] then
          for _, callback in ipairs(mock_events.listeners[event]) do
            callback(data)
          end
        end
      end,
    }
    package.loaded['twitch-chat.events'] = mock_events

    -- Mock utils module
    mock_utils = {
      deep_merge = function(target, source)
        local result = vim.deepcopy(target)
        for k, v in pairs(source) do
          result[k] = v
        end
        return result
      end,
      random_string = function(length)
        return string.rep('a', length)
      end,
      table_contains = function(tbl, value)
        for _, v in pairs(tbl) do
          if v == value then
            return true
          end
        end
        return false
      end,
      create_cache = function(max_size)
        local cache = {}
        return {
          get = function(key)
            return cache[key]
          end,
          set = function(key, value)
            cache[key] = value
          end,
          clear = function()
            cache = {}
          end,
          size = function()
            local count = 0
            for _ in pairs(cache) do
              count = count + 1
            end
            return count
          end,
        }
      end,
      write_file = function(path, content)
        return true
      end,
      read_file = function(path)
        return nil
      end,
      file_exists = function(path)
        return false
      end,
      format_timestamp = function(timestamp)
        return os.date('%Y-%m-%d %H:%M:%S', timestamp)
      end,
      log = function(level, message, context)
        -- Mock logging
      end,
    }
    package.loaded['twitch-chat.utils'] = mock_utils

    -- Save original functions
    original_os_time = os.time
    original_vim_loop_hrtime = vim.loop.hrtime
    original_vim_fn_stdpath = vim.fn.stdpath
    original_vim_fn_json_encode = vim.fn.json_encode
    original_vim_fn_json_decode = vim.fn.json_decode

    -- Mock time functions
    ---@diagnostic disable-next-line: duplicate-set-field
    os.time = function()
      return test_time
    end

    -- Mock vim.loop.hrtime
    vim.loop.hrtime = function()
      return test_time * 1000000
    end

    -- Mock vim.fn.stdpath
    vim.fn.stdpath = function(what)
      return '/tmp/test'
    end

    -- Mock vim.fn.json_encode and json_decode
    vim.fn.json_encode = function(data)
      return vim.json.encode(data)
    end
    vim.fn.json_decode = function(data)
      return vim.json.decode(data)
    end

    -- Clear module cache
    package.loaded['twitch-chat.modules.filter'] = nil
    filter = require('twitch-chat.modules.filter')
  end)

  after_each(function()
    -- Restore original modules
    for name, module in pairs(original_modules) do
      package.loaded['twitch-chat.' .. name] = module
    end

    -- Restore original functions
    os.time = original_os_time
    vim.loop.hrtime = original_vim_loop_hrtime
    vim.fn.stdpath = original_vim_fn_stdpath
    vim.fn.json_encode = original_vim_fn_json_encode
    vim.fn.json_decode = original_vim_fn_json_decode

    -- Clean up filter module
    filter.cleanup()
  end)

  describe('setup and configuration', function()
    it('should setup successfully when enabled', function()
      local success = filter.setup()
      assert.is_true(success)
      assert.is_true(filter.is_enabled())
    end)

    it('should return false when disabled', function()
      local success = filter.setup({ enabled = false })
      assert.is_false(success)
      assert.is_false(filter.is_enabled())
    end)

    it('should accept user configuration', function()
      local config = {
        enabled = true,
        default_mode = 'block',
        rules = {
          patterns = {
            max_patterns = 200,
            case_sensitive = true,
          },
          users = {
            max_users = 1000,
            moderator_bypass = false,
          },
        },
      }

      local success = filter.setup(config)
      assert.is_true(success)
    end)

    it('should setup event listeners on setup', function()
      filter.setup()
      assert.is_true(#mock_events.listeners[mock_events.MESSAGE_RECEIVED] > 0)
    end)

    it('should not setup when disabled', function()
      filter.setup({ enabled = false })
      assert.is_false(filter.is_enabled())
    end)
  end)

  describe('message filtering', function()
    before_each(function()
      filter.setup()
    end)

    it('should allow messages by default', function()
      local message = {
        username = 'testuser',
        content = 'Hello world',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed)
      assert.equals(0, #result.matches)
      assert.is_number(result.processing_time)
    end)

    it('should return allowed when disabled', function()
      filter.setup({ enabled = false })

      local message = {
        username = 'testuser',
        content = 'Hello world',
        channel = 'testchannel',
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed)
      assert.equals(0, #result.matches)
    end)

    it('should block messages in block mode', function()
      filter.setup({ default_mode = 'block' })

      local message = {
        username = 'testuser',
        content = 'Hello world',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
    end)

    it('should validate message parameter', function()
      assert.has_error(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        filter.filter_message(nil)
      end)

      assert.has_error(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        filter.filter_message('invalid')
      end)
    end)

    it('should measure processing time', function()
      local message = {
        username = 'testuser',
        content = 'Hello world',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_number(result.processing_time)
      assert.is_true(result.processing_time >= 0)
    end)
  end)

  describe('rule management', function()
    before_each(function()
      filter.setup()
    end)

    describe('add_rule', function()
      it('should add a valid pattern rule', function()
        local rule_data = {
          name = 'Block spam',
          type = 'pattern',
          action = 'block',
          pattern = 'spam',
          priority = 10,
        }

        local rule_id = filter.add_rule(rule_data)
        assert.is_string(rule_id)
        assert.is_not_nil(filter.get_rule(rule_id))
      end)

      it('should add a valid user rule', function()
        local rule_data = {
          name = 'Block troll',
          type = 'user',
          action = 'block',
          user = 'trolluser',
          priority = 100,
        }

        local rule_id = filter.add_rule(rule_data)
        assert.is_string(rule_id)

        local rule = filter.get_rule(rule_id)
        assert.is_not_nil(rule)
        if rule then
          assert.equals('Block troll', rule.name)
          assert.equals('user', rule.type)
          assert.equals('block', rule.action)
          assert.equals('trolluser', rule.user)
        end
      end)

      it('should generate ID if not provided', function()
        local rule_data = {
          name = 'Test rule',
          type = 'pattern',
          action = 'block',
          pattern = 'test',
        }

        local rule_id = filter.add_rule(rule_data)
        assert.is_string(rule_id)
        assert.is_true(#rule_id > 0)
      end)

      it('should set defaults for optional fields', function()
        local rule_data = {
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        }

        local rule_id = filter.add_rule(rule_data)
        local rule = filter.get_rule(rule_id)
        assert.is_not_nil(rule)

        if rule then
          assert.equals('block', rule.action)
          assert.equals(0, rule.priority)
          assert.is_true(rule.enabled)
          assert.equals(test_time, rule.created_at)
          assert.equals(0, rule.last_used)
          assert.equals(0, rule.use_count)
        end
      end)

      it('should validate rule data', function()
        assert.has_error(function()
          filter.add_rule({})
        end)

        assert.has_error(function()
          filter.add_rule({ name = 'Test', type = 'invalid' })
        end)

        assert.has_error(function()
          filter.add_rule({ name = 'Test', type = 'pattern', pattern = '' })
        end)

        assert.has_error(function()
          filter.add_rule({ name = 'Test', type = 'user', user = '' })
        end)
      end)

      it('should validate pattern syntax', function()
        assert.has_error(function()
          filter.add_rule({
            name = 'Invalid pattern',
            type = 'pattern',
            pattern = '[invalid',
          })
        end)
      end)
    end)

    describe('remove_rule', function()
      it('should remove existing rule', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        })

        local success = filter.remove_rule(rule_id)
        assert.is_true(success)
        assert.is_nil(filter.get_rule(rule_id))
      end)

      it('should return false for non-existent rule', function()
        local success = filter.remove_rule('nonexistent')
        assert.is_false(success)
      end)

      it('should validate rule_id parameter', function()
        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.remove_rule(nil)
        end)

        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.remove_rule(123)
        end)
      end)
    end)

    describe('update_rule', function()
      it('should update existing rule', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
          priority = 0,
        })

        local success = filter.update_rule(rule_id, {
          name = 'Updated rule',
          priority = 50,
        })

        assert.is_true(success)

        local rule = filter.get_rule(rule_id)
        assert.is_not_nil(rule)
        if rule then
          assert.equals('Updated rule', rule.name)
          assert.equals(50, rule.priority)
          assert.equals('test', rule.pattern) -- unchanged
        end
      end)

      it('should return false for non-existent rule', function()
        local success = filter.update_rule('nonexistent', { name = 'Test' })
        assert.is_false(success)
      end)

      it('should not allow updating protected fields', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        })

        local original_rule = filter.get_rule(rule_id)
        assert.is_not_nil(original_rule)
        local original_id, original_created_at
        if original_rule then
          original_id = original_rule.id
          original_created_at = original_rule.created_at
        end

        filter.update_rule(rule_id, {
          id = 'hacked',
          created_at = 999,
        })

        local updated_rule = filter.get_rule(rule_id)
        assert.is_not_nil(updated_rule)
        if updated_rule then
          assert.equals(original_id, updated_rule.id)
          assert.equals(original_created_at, updated_rule.created_at)
        end
      end)

      it('should validate updated rule', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        })

        assert.has_error(function()
          filter.update_rule(rule_id, { name = '' })
        end)

        assert.has_error(function()
          filter.update_rule(rule_id, { type = 'invalid' })
        end)
      end)
    end)

    describe('toggle_rule', function()
      it('should enable/disable rule', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        })

        -- Disable rule
        local success = filter.toggle_rule(rule_id, false)
        assert.is_true(success)

        local rule = filter.get_rule(rule_id)
        assert.is_not_nil(rule)
        if rule then
          assert.is_false(rule.enabled)
        end

        -- Enable rule
        success = filter.toggle_rule(rule_id, true)
        assert.is_true(success)

        rule = filter.get_rule(rule_id)
        assert.is_not_nil(rule)
        if rule then
          assert.is_true(rule.enabled)
        end
      end)

      it('should return false for non-existent rule', function()
        local success = filter.toggle_rule('nonexistent', true)
        assert.is_false(success)
      end)
    end)

    describe('get_rules', function()
      it('should return all rules', function()
        filter.add_rule({
          name = 'Rule 1',
          type = 'pattern',
          pattern = 'test1',
        })

        filter.add_rule({
          name = 'Rule 2',
          type = 'pattern',
          pattern = 'test2',
        })

        local rules = filter.get_rules()
        assert.equals(2, vim.tbl_count(rules))
      end)

      it('should return deep copy', function()
        local rule_id = filter.add_rule({
          name = 'Test rule',
          type = 'pattern',
          pattern = 'test',
        })

        local rules = filter.get_rules()
        assert.is_not_nil(rules[rule_id])
        if rules[rule_id] then
          rules[rule_id].name = 'Modified'
        end

        local original_rule = filter.get_rule(rule_id)
        assert.is_not_nil(original_rule)
        if original_rule then
          assert.equals('Test rule', original_rule.name)
        end
      end)
    end)

    describe('clear_rules', function()
      it('should clear all rules', function()
        filter.add_rule({
          name = 'Rule 1',
          type = 'pattern',
          pattern = 'test1',
        })

        filter.add_rule({
          name = 'Rule 2',
          type = 'pattern',
          pattern = 'test2',
        })

        filter.clear_rules()

        local rules = filter.get_rules()
        assert.equals(0, vim.tbl_count(rules))
      end)
    end)
  end)

  describe('user management', function()
    before_each(function()
      filter.setup()
    end)

    describe('block_user', function()
      it('should create block rule for user', function()
        local success = filter.block_user('baduser')
        assert.is_true(success)

        local rules = filter.get_rules()
        local block_rule = nil
        for _, rule in pairs(rules) do
          if rule.type == 'user' and rule.user == 'baduser' then
            block_rule = rule
            break
          end
        end

        assert.is_not_nil(block_rule)
        if block_rule then
          assert.equals('block', block_rule.action)
          assert.equals(100, block_rule.priority)
        end
      end)

      it('should validate username parameter', function()
        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.block_user(nil)
        end)

        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.block_user(123)
        end)
      end)
    end)

    describe('allow_user', function()
      it('should create allow rule for user', function()
        local success = filter.allow_user('gooduser')
        assert.is_true(success)

        local rules = filter.get_rules()
        local allow_rule = nil
        for _, rule in pairs(rules) do
          if rule.type == 'user' and rule.user == 'gooduser' then
            allow_rule = rule
            break
          end
        end

        assert.is_not_nil(allow_rule)
        if allow_rule then
          assert.equals('allow', allow_rule.action)
          assert.equals(200, allow_rule.priority)
        end
      end)
    end)

    describe('timeout_user', function()
      it('should timeout user with default duration', function()
        local success = filter.timeout_user('timeoutuser')
        assert.is_true(success)

        local message = {
          username = 'timeoutuser',
          content = 'test',
          channel = 'testchannel',
          timestamp = test_time,
          badges = {},
          emotes = {},
        }

        local result = filter.filter_message(message)
        assert.is_false(result.allowed)
        assert.equals('User is timed out', result.reason)
      end)

      it('should timeout user with custom duration', function()
        local success = filter.timeout_user('timeoutuser', 600)
        assert.is_true(success)

        local message = {
          username = 'timeoutuser',
          content = 'test',
          channel = 'testchannel',
          timestamp = test_time,
          badges = {},
          emotes = {},
        }

        local result = filter.filter_message(message)
        assert.is_false(result.allowed)
      end)

      it('should validate parameters', function()
        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.timeout_user(nil)
        end)

        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.timeout_user('user', 'invalid')
        end)
      end)
    end)

    describe('untimeout_user', function()
      it('should remove user timeout', function()
        filter.timeout_user('timeoutuser')

        local success = filter.untimeout_user('timeoutuser')
        assert.is_true(success)

        local message = {
          username = 'timeoutuser',
          content = 'test',
          channel = 'testchannel',
          timestamp = test_time,
          badges = {},
          emotes = {},
        }

        local result = filter.filter_message(message)
        assert.is_true(result.allowed)
      end)

      it('should return false for non-timed out user', function()
        local success = filter.untimeout_user('normaluser')
        assert.is_false(success)
      end)
    end)
  end)

  describe('pattern management', function()
    before_each(function()
      filter.setup()
    end)

    describe('block_pattern', function()
      it('should create block rule for pattern', function()
        local success = filter.block_pattern('spam')
        assert.is_true(success)

        local rules = filter.get_rules()
        local block_rule = nil
        for _, rule in pairs(rules) do
          if rule.type == 'pattern' and rule.pattern == 'spam' then
            block_rule = rule
            break
          end
        end

        assert.is_not_nil(block_rule)
        if block_rule then
          assert.equals('block', block_rule.action)
          assert.equals(50, block_rule.priority)
        end
      end)

      it('should accept custom name', function()
        local success = filter.block_pattern('spam', 'Custom spam rule')
        assert.is_true(success)

        local rules = filter.get_rules()
        local block_rule = nil
        for _, rule in pairs(rules) do
          if rule.type == 'pattern' and rule.pattern == 'spam' then
            block_rule = rule
            break
          end
        end

        assert.is_not_nil(block_rule)
        if block_rule then
          assert.equals('Custom spam rule', block_rule.name)
        end
      end)

      it('should validate pattern parameter', function()
        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.block_pattern(nil)
        end)

        assert.has_error(function()
          ---@diagnostic disable-next-line: param-type-mismatch
          filter.block_pattern(123)
        end)
      end)
    end)

    describe('allow_pattern', function()
      it('should create allow rule for pattern', function()
        local success = filter.allow_pattern('goodword')
        assert.is_true(success)

        local rules = filter.get_rules()
        local allow_rule = nil
        for _, rule in pairs(rules) do
          if rule.type == 'pattern' and rule.pattern == 'goodword' then
            allow_rule = rule
            break
          end
        end

        assert.is_not_nil(allow_rule)
        if allow_rule then
          assert.equals('allow', allow_rule.action)
          assert.equals(150, allow_rule.priority)
        end
      end)
    end)
  end)

  describe('content filtering', function()
    before_each(function()
      filter.setup({
        rules = {
          content = {
            enabled = true,
            filter_links = true,
            filter_caps = true,
            filter_emote_spam = true,
            caps_threshold = 0.7,
            emote_spam_threshold = 5,
          },
        },
      })
    end)

    it('should filter messages with links', function()
      local message = {
        username = 'testuser',
        content = 'Check this out https://example.com',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.is_true(#result.matches > 0)
    end)

    it('should filter messages with excessive caps', function()
      local message = {
        username = 'testuser',
        content = 'THIS IS SHOUTING TOO MUCH',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.is_true(#result.matches > 0)
    end)

    it('should filter messages with emote spam', function()
      local message = {
        username = 'testuser',
        content = 'Test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = { 'e1', 'e2', 'e3', 'e4', 'e5', 'e6' }, -- 6 emotes > threshold of 5
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.is_true(#result.matches > 0)
    end)

    it('should allow messages below thresholds', function()
      local message = {
        username = 'testuser',
        content = 'Normal message with Some caps',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = { 'e1', 'e2' }, -- 2 emotes < threshold
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed)
    end)
  end)

  describe('command filtering', function()
    before_each(function()
      filter.setup({
        rules = {
          commands = {
            enabled = true,
            filter_bot_commands = true,
            filter_user_commands = true,
            blocked_commands = { 'ban', 'kick' },
            allowed_commands = { 'help', 'info' },
          },
        },
      })
    end)

    it('should filter blocked commands', function()
      local message = {
        username = 'testuser',
        content = '/ban someone',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.is_true(#result.matches > 0)
    end)

    it('should allow commands in allow list', function()
      local message = {
        username = 'testuser',
        content = '/help',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed)
    end)

    it('should filter commands not in allow list when allow list exists', function()
      local message = {
        username = 'testuser',
        content = '/random',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.is_true(#result.matches > 0)
    end)

    it('should ignore non-command messages', function()
      local message = {
        username = 'testuser',
        content = 'regular message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed)
    end)
  end)

  describe('statistics', function()
    before_each(function()
      filter.setup()
    end)

    it('should track message statistics', function()
      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      assert.equals(1, stats.total_messages)
      assert.equals(1, stats.allowed_messages)
      assert.equals(0, stats.blocked_messages)
    end)

    it('should track blocked message statistics', function()
      filter.setup({ default_mode = 'block' })

      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      assert.is_not_nil(stats)
      assert.equals(1, stats.total_messages)
      assert.is_not_nil(stats)
      assert.equals(0, stats.allowed_messages)
      assert.is_not_nil(stats)
      assert.equals(1, stats.blocked_messages)
    end)

    it('should track rule usage', function()
      local rule_id = filter.add_rule({
        name = 'Test rule',
        type = 'pattern',
        pattern = 'test',
        action = 'block',
      })

      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      assert.is_not_nil(stats)
      if stats then
        assert.equals(1, stats.rules_triggered[rule_id])
      end

      local rule = filter.get_rule(rule_id)
      assert.is_not_nil(rule)
      if rule then
        assert.equals(1, rule.use_count)
        assert.equals(test_time, rule.last_used)
      end
    end)

    it('should track user violations', function()
      filter.setup({ default_mode = 'block' })

      local message = {
        username = 'baduser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      assert.equals(1, stats.user_violations['baduser'])
    end)

    it('should reset statistics', function()
      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      assert.equals(1, stats.total_messages)

      filter.reset_stats()

      stats = filter.get_stats()
      assert.equals(0, stats.total_messages)
      assert.equals(0, stats.allowed_messages)
      assert.equals(0, stats.blocked_messages)
    end)

    it('should return deep copy of stats', function()
      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      filter.filter_message(message)

      local stats = filter.get_stats()
      stats.total_messages = 999

      local fresh_stats = filter.get_stats()
      assert.equals(1, fresh_stats.total_messages)
    end)
  end)

  describe('persistence', function()
    before_each(function()
      filter.setup({
        persistence = {
          enabled = true,
          save_rules = true,
          save_stats = true,
        },
      })
    end)

    it('should save rules on add', function()
      local write_called = false
      mock_utils.write_file = function(path, content)
        write_called = true
        return true
      end

      filter.add_rule({
        name = 'Test rule',
        type = 'pattern',
        pattern = 'test',
      })

      assert.is_true(write_called)
    end)

    it('should save rules on remove', function()
      local rule_id = filter.add_rule({
        name = 'Test rule',
        type = 'pattern',
        pattern = 'test',
      })

      local write_called = false
      mock_utils.write_file = function(path, content)
        write_called = true
        return true
      end

      filter.remove_rule(rule_id)
      assert.is_true(write_called)
    end)

    it('should save stats on reset', function()
      local write_called = false
      mock_utils.write_file = function(path, content)
        write_called = true
        return true
      end

      filter.reset_stats()
      assert.is_true(write_called)
    end)

    it('should not save when persistence disabled', function()
      filter.setup({
        persistence = {
          enabled = false,
        },
      })

      local write_called = false
      mock_utils.write_file = function(path, content)
        write_called = true
        return true
      end

      filter.add_rule({
        name = 'Test rule',
        type = 'pattern',
        pattern = 'test',
      })

      assert.is_false(write_called)
    end)
  end)

  describe('event integration', function()
    before_each(function()
      filter.setup()
    end)

    it('should filter messages on MESSAGE_RECEIVED event', function()
      local filtered_event_fired = false
      local original_emit = mock_events.emit
      mock_events.emit = function(event, data)
        if event == 'message_filtered' then
          filtered_event_fired = true
          assert.is_table(data.message)
          assert.is_table(data.result)
        end
        -- Call original emit to trigger event listeners
        original_emit(event, data)
      end

      -- Emit MESSAGE_RECEIVED event
      mock_events.emit(mock_events.MESSAGE_RECEIVED, {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      })

      assert.is_true(filtered_event_fired)
    end)

    it('should emit message_blocked event for blocked messages', function()
      filter.setup({ default_mode = 'block' })

      local blocked_event_fired = false
      local original_emit = mock_events.emit
      mock_events.emit = function(event, data)
        if event == 'message_blocked' then
          blocked_event_fired = true
          assert.is_table(data.message)
          assert.is_table(data.result)
          assert.is_false(data.result.allowed)
        end
        -- Call original emit to trigger event listeners
        original_emit(event, data)
      end

      -- Emit MESSAGE_RECEIVED event
      mock_events.emit(mock_events.MESSAGE_RECEIVED, {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      })

      assert.is_true(blocked_event_fired)
    end)

    it('should handle missing message fields gracefully', function()
      assert.has_no.errors(function()
        mock_events.emit(mock_events.MESSAGE_RECEIVED, {
          username = 'testuser',
          -- missing content, channel, etc.
        })
      end)
    end)
  end)

  describe('performance', function()
    before_each(function()
      filter.setup()
    end)

    it('should handle large numbers of rules', function()
      -- Add many rules
      for i = 1, 100 do
        filter.add_rule({
          name = 'Rule ' .. i,
          type = 'pattern',
          pattern = 'test' .. i,
          priority = i,
        })
      end

      local message = {
        username = 'testuser',
        content = 'test50 message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_table(result)
      assert.is_number(result.processing_time)
    end)

    it('should process messages quickly', function()
      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_number(result.processing_time)
      -- Processing time should be reasonable (this is a basic check)
      assert.is_true(result.processing_time >= 0)
    end)

    it('should handle pattern caching', function()
      filter.add_rule({
        name = 'Cached rule',
        type = 'pattern',
        pattern = 'cached',
      })

      local message = {
        username = 'testuser',
        content = 'cached message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      -- First call compiles pattern
      filter.filter_message(message)

      -- Second call should use cached pattern
      local result = filter.filter_message(message)
      assert.is_table(result)
    end)
  end)

  describe('edge cases', function()
    before_each(function()
      filter.setup()
    end)

    it('should handle empty message content', function()
      local message = {
        username = 'testuser',
        content = '',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_table(result)
      assert.is_boolean(result.allowed)
    end)

    it('should handle nil badges and emotes', function()
      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = nil,
        emotes = nil,
      }

      assert.has_no.errors(function()
        filter.filter_message(message)
      end)
    end)

    it('should handle malformed patterns gracefully', function()
      assert.has_error(function()
        filter.add_rule({
          name = 'Bad pattern',
          type = 'pattern',
          pattern = '[unclosed',
        })
      end)
    end)

    it('should handle rule priority conflicts', function()
      -- Add rules with same priority
      filter.add_rule({
        name = 'Rule 1',
        type = 'pattern',
        pattern = 'test',
        priority = 100,
        action = 'block',
      })

      filter.add_rule({
        name = 'Rule 2',
        type = 'pattern',
        pattern = 'test',
        priority = 100,
        action = 'allow',
      })

      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      -- Should not crash
      assert.has_no.errors(function()
        filter.filter_message(message)
      end)
    end)

    it('should handle disabled rules', function()
      filter.add_rule({
        name = 'Disabled rule',
        type = 'pattern',
        pattern = 'test',
        action = 'block',
        enabled = false,
      })

      local message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_true(result.allowed) -- Should be allowed because rule is disabled
    end)

    it('should handle very long messages', function()
      local long_content = string.rep('test ', 1000)
      local message = {
        username = 'testuser',
        content = long_content,
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      assert.has_no.errors(function()
        filter.filter_message(message)
      end)
    end)

    it('should handle special characters in patterns', function()
      filter.add_rule({
        name = 'Special chars',
        type = 'pattern',
        pattern = '%.%*%+%?%^%$%(%)%[%]%{%}%|%\\',
      })

      local message = {
        username = 'testuser',
        content = '.*+?^$()[]{}|\\',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      assert.has_no.errors(function()
        filter.filter_message(message)
      end)
    end)

    it('should handle user bypass conditions', function()
      filter.setup({
        rules = {
          users = {
            moderator_bypass = true,
            vip_bypass = true,
            subscriber_bypass = true,
          },
        },
      })

      filter.add_rule({
        name = 'Block user',
        type = 'user',
        user = 'testuser',
        action = 'block',
      })

      -- Test moderator bypass
      local mod_message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = { 'moderator' },
        emotes = {},
      }

      local result = filter.filter_message(mod_message)
      assert.is_true(result.allowed)

      -- Test VIP bypass
      local vip_message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = { 'vip' },
        emotes = {},
      }

      result = filter.filter_message(vip_message)
      assert.is_true(result.allowed)

      -- Test subscriber bypass
      local sub_message = {
        username = 'testuser',
        content = 'test message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = { 'subscriber/12' },
        emotes = {},
      }

      result = filter.filter_message(sub_message)
      assert.is_true(result.allowed)
    end)

    it('should handle timeout expiration', function()
      -- Mock time progression
      local current_time = test_time
      ---@diagnostic disable-next-line: duplicate-set-field
      os.time = function()
        return current_time
      end

      -- Timeout user
      filter.timeout_user('timeoutuser', 300) -- 5 minutes

      -- User should be timed out
      local message = {
        username = 'timeoutuser',
        content = 'test',
        channel = 'testchannel',
        timestamp = current_time,
        badges = {},
        emotes = {},
      }

      local result = filter.filter_message(message)
      assert.is_false(result.allowed)

      -- Advance time past timeout
      current_time = test_time + 400 -- 400 seconds later

      -- User should no longer be timed out
      result = filter.filter_message(message)
      assert.is_true(result.allowed)
    end)

    it('should handle spam detection', function()
      filter.setup({
        rules = {
          content = {
            filter_spam = true,
            spam_threshold = 3,
          },
        },
      })

      local message = {
        username = 'spamuser',
        content = 'spam message',
        channel = 'testchannel',
        timestamp = test_time,
        badges = {},
        emotes = {},
      }

      -- Send same message multiple times
      for i = 1, 5 do
        filter.filter_message(message)
      end

      -- Should be detected as spam
      local result = filter.filter_message(message)
      assert.is_false(result.allowed)
      assert.equals('Message identified as spam', result.reason)
    end)
  end)

  describe('cleanup', function()
    it('should cleanup resources', function()
      filter.setup({
        persistence = {
          enabled = true,
          save_rules = true,
          save_stats = true,
        },
      })

      local cleanup_called = false
      mock_utils.write_file = function(path, content)
        cleanup_called = true
        return true
      end

      filter.cleanup()
      assert.is_true(cleanup_called)
    end)

    it('should not error when cleanup called multiple times', function()
      filter.setup()

      assert.has_no.errors(function()
        filter.cleanup()
        filter.cleanup()
      end)
    end)
  end)
end)
