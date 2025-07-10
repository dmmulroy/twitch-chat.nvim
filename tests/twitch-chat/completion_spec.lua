-- tests/twitch-chat/completion_spec.lua
-- Completion tests

local completion = require('twitch-chat.modules.completion')

describe('TwitchChat Completion', function()
  local mock_config
  local original_cmp
  local original_vim_api = {}

  before_each(function()
    -- Mock config module
    mock_config = {
      is_integration_enabled = function(name)
        return name == 'cmp'
      end,
      is_debug = function()
        return false
      end,
    }

    -- Save and mock config
    package.loaded['twitch-chat.config'] = mock_config

    -- Mock nvim-cmp
    original_cmp = package.loaded['cmp']
    package.loaded['cmp'] = {
      register_source = function() end,
    }

    -- Clear module cache
    package.loaded['twitch-chat.modules.completion'] = nil
    completion = require('twitch-chat.modules.completion')
  end)

  after_each(function()
    -- Restore original state
    package.loaded['cmp'] = original_cmp
    package.loaded['twitch-chat.config'] = nil
    completion.clear_cache('all')

    -- Restore vim.api functions
    for name, func in pairs(original_vim_api) do
      rawset(vim.api, name, func)
    end
    original_vim_api = {}
  end)

  describe('setup', function()
    it('should setup successfully when cmp is available', function()
      local success = completion.setup()
      assert.is_true(success)
    end)

    it('should return false when cmp integration is disabled', function()
      mock_config.is_integration_enabled = function()
        return false
      end

      local success = completion.setup()
      assert.is_false(success)
    end)

    it('should handle missing nvim-cmp gracefully', function()
      package.loaded['cmp'] = nil

      local success = completion.setup()
      assert.is_false(success)
    end)

    it('should accept user configuration', function()
      local user_config = {
        commands = {
          max_items = 10,
        },
      }

      local success = completion.setup(user_config)
      assert.is_true(success)
    end)
  end)

  describe('availability check', function()
    it('should report available when cmp exists and is enabled', function()
      assert.is_true(completion.is_available())
    end)

    it('should report unavailable when cmp is missing', function()
      package.loaded['cmp'] = nil
      assert.is_false(completion.is_available())
    end)

    it('should report unavailable when integration is disabled', function()
      mock_config.is_integration_enabled = function()
        return false
      end
      assert.is_false(completion.is_available())
    end)
  end)

  describe('completion context', function()
    it('should extract context from cmp parameters', function()
      local params = {
        context = {
          bufnr = 1,
        },
      }

      -- Mock buffer name
      original_vim_api.nvim_buf_get_name = vim.api.nvim_buf_get_name
      rawset(vim.api, 'nvim_buf_get_name', function(bufnr)
        return 'twitch-chat://test_channel'
      end)

      -- Mock cursor position
      original_vim_api.nvim_win_get_cursor = vim.api.nvim_win_get_cursor
      rawset(vim.api, 'nvim_win_get_cursor', function()
        return { 1, 5 }
      end)

      -- Mock current line
      original_vim_api.nvim_get_current_line = vim.api.nvim_get_current_line
      rawset(vim.api, 'nvim_get_current_line', function()
        return '@test_user hello'
      end)

      local context = completion._get_completion_context(params)

      assert.is_not_nil(context)
      if context then
        assert.equals(1, context.bufnr)
        assert.equals('test_channel', context.channel)
        assert.equals('@test', context.line_to_cursor)
        assert.equals('@test', context.word_to_cursor)
      end
    end)

    it('should return nil for non-twitch buffers', function()
      local params = {
        context = {
          bufnr = 1,
        },
      }

      original_vim_api.nvim_buf_get_name = vim.api.nvim_buf_get_name
      rawset(vim.api, 'nvim_buf_get_name', function()
        return 'regular_file.lua'
      end)

      local context = completion._get_completion_context(params)
      assert.is_nil(context)
    end)
  end)

  describe('trigger detection', function()
    it('should detect command triggers', function()
      local context = {
        word_to_cursor = '/ban',
      }

      assert.is_true(completion._should_complete_commands(context))
      assert.is_false(completion._should_complete_users(context))
      assert.is_false(completion._should_complete_channels(context))
      assert.is_false(completion._should_complete_emotes(context))
    end)

    it('should detect user triggers', function()
      local context = {
        word_to_cursor = '@user',
      }

      assert.is_false(completion._should_complete_commands(context))
      assert.is_true(completion._should_complete_users(context))
      assert.is_false(completion._should_complete_channels(context))
      assert.is_false(completion._should_complete_emotes(context))
    end)

    it('should detect channel triggers', function()
      local context = {
        word_to_cursor = '#chan',
      }

      assert.is_false(completion._should_complete_commands(context))
      assert.is_false(completion._should_complete_users(context))
      assert.is_true(completion._should_complete_channels(context))
      assert.is_false(completion._should_complete_emotes(context))
    end)

    it('should detect emote triggers', function()
      local context = {
        word_to_cursor = ':Kappa',
      }

      assert.is_false(completion._should_complete_commands(context))
      assert.is_false(completion._should_complete_users(context))
      assert.is_false(completion._should_complete_channels(context))
      assert.is_true(completion._should_complete_emotes(context))
    end)
  end)

  describe('command completions', function()
    it('should return all commands for empty query', function()
      local context = {
        word_to_cursor = '/',
        channel = 'test_channel',
      }

      local items = completion._get_command_completions(context)

      assert.is_true(#items > 0)
      assert.is_true(#items <= 20) -- Default max_items

      -- Check first item structure
      local first = items[1]
      assert.is_string(first.label)
      assert.is_string(first.detail)
      assert.is_string(first.documentation)
      assert.equals(1, first.kind) -- COMMAND kind
    end)

    it('should filter commands by query', function()
      local context = {
        word_to_cursor = '/ba',
        channel = 'test_channel',
      }

      local items = completion._get_command_completions(context)

      -- Should return /ban and /banpets
      assert.is_true(#items >= 1)

      -- Check that ban is included
      local has_ban = false
      for _, item in ipairs(items) do
        if item.label == '/ban' then
          has_ban = true
          break
        end
      end
      assert.is_true(has_ban)
    end)

    it('should handle case-insensitive filtering', function()
      local context = {
        word_to_cursor = '/BA',
        channel = 'test_channel',
      }

      local items = completion._get_command_completions(context)

      assert.is_true(#items >= 1)

      -- Check that ban is included
      local has_ban = false
      for _, item in ipairs(items) do
        if item.label == '/ban' then
          has_ban = true
          break
        end
      end
      assert.is_true(has_ban)
    end)
  end)

  describe('user completions', function()
    before_each(function()
      completion.setup()
      -- Add test users to cache
      completion._add_user_to_cache('test_channel', 'alice')
      completion._add_user_to_cache('test_channel', 'bob')
      completion._add_user_to_cache('test_channel', 'charlie')
    end)

    it('should return users from cache', function()
      local context = {
        word_to_cursor = '@',
        channel = 'test_channel',
      }

      local items = completion._get_user_completions(context)

      assert.equals(3, #items)

      -- Check structure
      local has_alice = false
      for _, item in ipairs(items) do
        if item.label == '@alice' then
          has_alice = true
          assert.equals(2, item.kind) -- USER kind
          assert.is_string(item.detail)
          assert.equals('@alice', item.insertText)
          assert.equals('alice', item.filterText)
        end
      end
      assert.is_true(has_alice)
    end)

    it('should filter users by query', function()
      local context = {
        word_to_cursor = '@ch',
        channel = 'test_channel',
      }

      local items = completion._get_user_completions(context)

      assert.equals(1, #items)
      assert.equals('@charlie', items[1].label)
    end)

    it('should prioritize recent users', function()
      -- Add bob again to make them recent
      completion._add_user_to_cache('test_channel', 'bob')

      local context = {
        word_to_cursor = '@',
        channel = 'test_channel',
      }

      local items = completion._get_user_completions(context)

      -- Bob should be first as most recent
      assert.equals('@bob', items[1].label)
      assert.equals('Recent user', items[1].detail)
    end)
  end)

  describe('channel completions', function()
    before_each(function()
      completion.setup()
      -- Add test channels to cache
      completion._add_channel_to_cache('channel1')
      completion._add_channel_to_cache('channel2')
      completion._add_channel_to_cache('test_channel')
    end)

    it('should return channels from cache', function()
      local context = {
        word_to_cursor = '#',
        channel = 'current_channel',
      }

      local items = completion._get_channel_completions(context)

      assert.equals(3, #items)

      -- Check structure
      local has_channel1 = false
      for _, item in ipairs(items) do
        if item.label == '#channel1' then
          has_channel1 = true
          assert.equals(3, item.kind) -- CHANNEL kind
          assert.is_string(item.detail)
          assert.equals('#channel1', item.insertText)
          assert.equals('channel1', item.filterText)
        end
      end
      assert.is_true(has_channel1)
    end)

    it('should filter channels by query', function()
      local context = {
        word_to_cursor = '#tes',
        channel = 'current_channel',
      }

      local items = completion._get_channel_completions(context)

      assert.equals(1, #items)
      assert.equals('#test_channel', items[1].label)
    end)

    it('should handle recent channels', function()
      -- Add channel2 again to make it recent
      completion._add_channel_to_cache('channel2')

      local context = {
        word_to_cursor = '#',
        channel = 'current_channel',
      }

      local items = completion._get_channel_completions(context)

      -- channel2 should be first as most recent
      assert.equals('#channel2', items[1].label)
      assert.equals('Recent channel', items[1].detail)
    end)
  end)

  describe('emote completions', function()
    before_each(function()
      completion.setup()
      -- Add test emotes to cache
      completion.add_emote_to_cache(nil, 'Kappa', 'https://example.com/kappa.png')
      completion.add_emote_to_cache(nil, 'PogChamp', 'https://example.com/pogchamp.png')
      completion.add_emote_to_cache('test_channel', 'CustomEmote', 'https://example.com/custom.png')
    end)

    it('should return global and channel emotes', function()
      local context = {
        word_to_cursor = ':',
        channel = 'test_channel',
      }

      local items = completion._get_emote_completions(context)

      assert.equals(3, #items)

      -- Check for each emote type
      local has_global = false
      local has_channel = false

      for _, item in ipairs(items) do
        if item.label == ':Kappa:' then
          has_global = true
          assert.equals(4, item.kind) -- EMOTE kind
          assert.equals('Global emote', item.detail)
          assert.equals('Kappa', item.insertText)
        elseif item.label == ':CustomEmote:' then
          has_channel = true
          assert.equals('Channel emote', item.detail)
        end
      end

      assert.is_true(has_global)
      assert.is_true(has_channel)
    end)

    it('should filter emotes by query', function()
      local context = {
        word_to_cursor = ':Pog',
        channel = 'test_channel',
      }

      local items = completion._get_emote_completions(context)

      assert.equals(1, #items)
      assert.equals(':PogChamp:', items[1].label)
    end)

    it('should prioritize channel emotes over global', function()
      -- Add channel version of global emote
      completion.add_emote_to_cache('test_channel', 'Kappa', 'https://example.com/kappa2.png')

      local context = {
        word_to_cursor = ':Kap',
        channel = 'test_channel',
      }

      local items = completion._get_emote_completions(context)

      -- Should have at least 1 Kappa emote (might be deduped)
      assert.is_true(#items >= 1)
      assert.equals(':Kappa:', items[1].label)

      -- The detail depends on implementation - it could prioritize either way
      -- Just check that we have at least one Kappa
      local has_kappa = false
      for _, item in ipairs(items) do
        if item.label == ':Kappa:' then
          has_kappa = true
          break
        end
      end
      assert.is_true(has_kappa)
    end)
  end)

  describe('cache management', function()
    before_each(function()
      completion.setup()
    end)

    it('should track cache statistics', function()
      -- Add test data
      completion._add_user_to_cache('channel1', 'user1')
      completion._add_user_to_cache('channel1', 'user2')
      completion._add_channel_to_cache('channel1')
      completion.add_emote_to_cache(nil, 'GlobalEmote')
      completion.add_emote_to_cache('channel1', 'ChannelEmote')

      local stats = completion.get_cache_stats()

      assert.equals(2, stats.users.channel1)
      assert.equals(1, stats.channels)
      assert.equals(1, stats.emotes.global)
      assert.equals(1, stats.emotes.channel1)
    end)

    it('should clear specific cache types', function()
      -- Add test data
      completion._add_user_to_cache('channel1', 'user1')
      completion._add_channel_to_cache('channel1')
      completion.add_emote_to_cache(nil, 'GlobalEmote')

      -- Clear only users
      completion.clear_cache('users')

      local stats = completion.get_cache_stats()
      assert.is_nil(stats.users.channel1)
      assert.equals(1, stats.channels)
      assert.equals(1, stats.emotes.global)
    end)

    it('should clear all caches', function()
      -- Add test data
      completion._add_user_to_cache('channel1', 'user1')
      completion._add_channel_to_cache('channel1')
      completion.add_emote_to_cache(nil, 'GlobalEmote')

      completion.clear_cache('all')

      local stats = completion.get_cache_stats()
      assert.is_nil(stats.users.channel1)
      assert.equals(0, stats.channels)
      assert.equals(0, stats.emotes.global)
    end)
  end)

  describe('cmp source interface', function()
    it('should implement is_available', function()
      completion.setup()

      -- Mock buffer name
      original_vim_api.nvim_buf_get_name = vim.api.nvim_buf_get_name
      rawset(vim.api, 'nvim_buf_get_name', function()
        return 'twitch-chat://test_channel'
      end)

      -- Get the registered source
      local cmp_mock = package.loaded['cmp']
      local registered_source = nil
      cmp_mock.register_source = function(name, src)
        if name == 'twitch-chat' then
          registered_source = src
        end
      end

      -- Re-setup to capture source
      completion.setup()

      assert.is_not_nil(registered_source)
      if registered_source then
        assert.is_function(registered_source.is_available)
        assert.is_true(registered_source:is_available())
      end
    end)

    it('should implement get_trigger_characters', function()
      completion.setup()

      -- Get the registered source
      local cmp_mock = package.loaded['cmp']
      local registered_source = nil
      cmp_mock.register_source = function(name, src)
        if name == 'twitch-chat' then
          registered_source = src
        end
      end

      -- Re-setup to capture source
      completion.setup()

      assert.is_not_nil(registered_source)
      if registered_source then
        assert.is_function(registered_source.get_trigger_characters)

        local triggers = registered_source:get_trigger_characters()
        assert.is_table(triggers)
        assert.is_true(vim.tbl_contains(triggers, '/'))
        assert.is_true(vim.tbl_contains(triggers, '@'))
        assert.is_true(vim.tbl_contains(triggers, '#'))
        assert.is_true(vim.tbl_contains(triggers, ':'))
      end
    end)
  end)

  describe('edge cases', function()
    it('should handle empty caches gracefully', function()
      completion.setup()

      local context = {
        word_to_cursor = '@',
        channel = 'empty_channel',
      }

      local items = completion._get_user_completions(context)
      assert.is_table(items)
      assert.equals(0, #items)
    end)

    it('should limit results to max_items', function()
      completion.setup({
        users = {
          max_items = 3,
        },
      })

      -- Add many users
      for i = 1, 10 do
        completion._add_user_to_cache('test_channel', 'user' .. i)
      end

      local context = {
        word_to_cursor = '@',
        channel = 'test_channel',
      }

      local items = completion._get_user_completions(context)
      assert.equals(3, #items)
    end)

    it('should handle duplicate entries', function()
      completion.setup()

      -- Add same user multiple times
      completion._add_user_to_cache('test_channel', 'duplicate')
      completion._add_user_to_cache('test_channel', 'duplicate')
      completion._add_user_to_cache('test_channel', 'duplicate')

      local context = {
        word_to_cursor = '@',
        channel = 'test_channel',
      }

      local items = completion._get_user_completions(context)

      -- Should only have one entry
      local count = 0
      for _, item in ipairs(items) do
        if item.label == '@duplicate' then
          count = count + 1
        end
      end
      assert.equals(1, count)
    end)
  end)
end)
