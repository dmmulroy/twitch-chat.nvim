-- tests/twitch-chat/buffer_spec.lua
-- Buffer management tests

local buffer = require('twitch-chat.modules.buffer')

describe('TwitchChat Buffer Management', function()
  local test_channel = 'test_channel'
  local test_message = {
    id = 'test_message_id',
    username = 'test_user',
    content = 'Hello, world!',
    timestamp = os.time(),
    badges = { 'subscriber' },
    emotes = {},
    channel = test_channel,
    color = '#FF0000',
  }

  before_each(function()
    -- Setup buffer module
    buffer.setup({
      ui = {
        max_messages = 100,
        auto_scroll = true,
        timestamp_format = '[%H:%M:%S]',
        highlights = {
          username = 'Identifier',
          timestamp = 'Comment',
          message = 'Normal',
          mention = 'WarningMsg',
          command = 'Function',
        },
      },
    })
  end)

  after_each(function()
    -- Clean up all buffers
    local all_buffers = buffer.get_all_buffers()
    for channel, _ in pairs(all_buffers) do
      buffer.cleanup_buffer(channel)
    end
  end)

  describe('create_chat_buffer()', function()
    it('should create a new buffer for a channel', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      assert.is_not_nil(chat_buffer)
      assert.equals(test_channel, chat_buffer.channel)
      assert.is_number(chat_buffer.bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(chat_buffer.bufnr))
      assert.equals('twitch-chat://' .. test_channel, vim.api.nvim_buf_get_name(chat_buffer.bufnr))
    end)

    it('should set correct buffer options', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      assert.equals('nofile', vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'buftype'))
      assert.equals('wipe', vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'bufhidden'))
      assert.is_false(vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'swapfile'))
      assert.equals('twitch-chat', vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'filetype'))
      assert.is_false(vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'modifiable'))
      assert.is_true(vim.api.nvim_buf_get_option(chat_buffer.bufnr, 'readonly'))
    end)

    it('should cleanup existing buffer when creating new one', function()
      local chat_buffer1 = buffer.create_chat_buffer(test_channel)
      local bufnr1 = chat_buffer1.bufnr

      local chat_buffer2 = buffer.create_chat_buffer(test_channel)
      local bufnr2 = chat_buffer2.bufnr

      assert.is_not.equals(bufnr1, bufnr2)
      assert.is_false(vim.api.nvim_buf_is_valid(bufnr1))
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr2))
    end)
  end)

  describe('get_chat_buffer()', function()
    it('should return existing buffer', function()
      local created_buffer = buffer.create_chat_buffer(test_channel)
      local retrieved_buffer = buffer.get_chat_buffer(test_channel)

      assert.equals(created_buffer, retrieved_buffer)
    end)

    it('should return nil for non-existent buffer', function()
      local retrieved_buffer = buffer.get_chat_buffer('non_existent_channel')
      assert.is_nil(retrieved_buffer)
    end)
  end)

  describe('get_all_buffers()', function()
    it('should return all created buffers', function()
      buffer.create_chat_buffer('channel1')
      buffer.create_chat_buffer('channel2')

      local all_buffers = buffer.get_all_buffers()

      assert.is_not_nil(all_buffers.channel1)
      assert.is_not_nil(all_buffers.channel2)
      assert.equals(2, vim.tbl_count(all_buffers))
    end)
  end)

  describe('add_message()', function()
    it('should add message to buffer', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      buffer.add_message(test_channel, test_message)

      -- Wait for batch processing
      vim.wait(50, function()
        return #chat_buffer.messages > 0
      end)

      assert.equals(1, #chat_buffer.messages)
      assert.equals(test_message, chat_buffer.messages[1])
    end)

    it('should handle non-existent channel gracefully', function()
      assert.has_no.errors(function()
        buffer.add_message('non_existent_channel', test_message)
      end)
    end)

    it('should batch messages for performance', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      -- Add multiple messages quickly
      for i = 1, 10 do
        local message = vim.tbl_extend('force', test_message, {
          id = 'test_message_' .. i,
          content = 'Message ' .. i,
        })
        buffer.add_message(test_channel, message)
      end

      -- Initially should be in pending queue
      assert.equals(10, #chat_buffer.pending_updates)

      -- Wait for batch processing
      vim.wait(100, function()
        return #chat_buffer.messages == 10
      end)

      assert.equals(10, #chat_buffer.messages)
      assert.equals(0, #chat_buffer.pending_updates)
    end)
  end)

  describe('message limiting', function()
    it('should limit messages to max_messages', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)
      chat_buffer.max_messages = 5

      -- Add more messages than the limit
      for i = 1, 10 do
        local message = vim.tbl_extend('force', test_message, {
          id = 'test_message_' .. i,
          content = 'Message ' .. i,
        })
        buffer.add_message(test_channel, message)
      end

      -- Wait for processing
      vim.wait(100, function()
        return #chat_buffer.messages == 5
      end)

      assert.equals(5, #chat_buffer.messages)
      -- Should keep the latest messages
      assert.equals('Message 6', chat_buffer.messages[1].content)
      assert.equals('Message 10', chat_buffer.messages[5].content)
    end)
  end)

  describe('format_message()', function()
    it('should format message correctly', function()
      buffer.create_chat_buffer(test_channel)

      local formatted_line, highlights = buffer.format_message(test_message, 1)

      assert.is_string(formatted_line)
      assert.matches(test_message.username, formatted_line)
      assert.matches(test_message.content, formatted_line)
      assert.matches('%[%d%d:%d%d:%d%d%]', formatted_line) -- Timestamp pattern
      assert.is_table(highlights)
      assert.is_true(#highlights > 0)
    end)

    it('should detect mentions', function()
      buffer.create_chat_buffer(test_channel)

      local mention_message = vim.tbl_extend('force', test_message, {
        content = '@' .. vim.fn.expand('%:t:r') .. ' hello!',
      })

      local _, highlights = buffer.format_message(mention_message, 1)

      assert.is_true(mention_message.is_mention)

      -- Check for mention highlight
      local has_mention_highlight = false
      for _, highlight in ipairs(highlights) do
        if highlight.hl_group == 'WarningMsg' then
          has_mention_highlight = true
          break
        end
      end
      assert.is_true(has_mention_highlight)
    end)

    it('should detect commands', function()
      buffer.create_chat_buffer(test_channel)

      local command_message = vim.tbl_extend('force', test_message, {
        content = '!followage',
      })

      local _, highlights = buffer.format_message(command_message, 1)

      assert.is_true(command_message.is_command)

      -- Check for command highlight
      local has_command_highlight = false
      for _, highlight in ipairs(highlights) do
        if highlight.hl_group == 'Function' then
          has_command_highlight = true
          break
        end
      end
      assert.is_true(has_command_highlight)
    end)

    it('should handle badges', function()
      buffer.create_chat_buffer(test_channel)

      local badge_message = vim.tbl_extend('force', test_message, {
        badges = { 'broadcaster', 'subscriber' },
      })

      local formatted_line = buffer.format_message(badge_message, 1)

      assert.matches('%[broadcaster,subscriber%]', formatted_line)
    end)
  end)

  describe('buffer operations', function()
    it('should close buffer correctly', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)
      local bufnr = chat_buffer.bufnr

      buffer.close_buffer(test_channel)

      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    end)

    it('should clear buffer messages', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      -- Add some messages
      for i = 1, 5 do
        buffer.add_message(
          test_channel,
          vim.tbl_extend('force', test_message, {
            id = 'message_' .. i,
          })
        )
      end

      -- Wait for processing
      vim.wait(100, function()
        return #chat_buffer.messages == 5
      end)

      buffer.clear_buffer(test_channel)

      assert.equals(0, #chat_buffer.messages)
      assert.equals(0, #chat_buffer.pending_updates)
    end)

    it('should toggle auto-scroll', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)
      local initial_auto_scroll = chat_buffer.auto_scroll

      buffer.toggle_auto_scroll(test_channel)

      assert.is_not.equals(initial_auto_scroll, chat_buffer.auto_scroll)
    end)
  end)

  describe('statistics', function()
    it('should provide buffer statistics', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      -- Add some messages
      for i = 1, 3 do
        buffer.add_message(
          test_channel,
          vim.tbl_extend('force', test_message, {
            id = 'message_' .. i,
          })
        )
      end

      -- Wait for processing
      vim.wait(100, function()
        return #chat_buffer.messages == 3
      end)

      local stats = buffer.get_buffer_stats(test_channel)

      assert.is_not_nil(stats)
      if stats then
        assert.equals(test_channel, stats.channel)
        assert.equals(3, stats.message_count)
        assert.equals(0, stats.pending_count)
        assert.is_boolean(stats.auto_scroll)
        assert.is_number(stats.buffer_number)
      end
    end)

    it('should provide performance statistics', function()
      -- Create multiple buffers
      for i = 1, 3 do
        buffer.create_chat_buffer('channel_' .. i)
      end

      local perf_stats = buffer.get_performance_stats()

      assert.is_not_nil(perf_stats)
      assert.equals(3, perf_stats.total_buffers)
      assert.is_number(perf_stats.total_messages)
      assert.is_number(perf_stats.total_pending)
      assert.is_number(perf_stats.average_update_time)
    end)
  end)

  describe('cleanup', function()
    it('should cleanup buffer resources', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)
      local _ = chat_buffer.bufnr

      -- Add pending updates
      buffer.add_message(test_channel, test_message)

      buffer.cleanup_buffer(test_channel)

      -- Buffer should be removed from tracking
      assert.is_nil(buffer.get_chat_buffer(test_channel))

      -- Timer should be cleaned up
      assert.is_nil(chat_buffer.update_timer)
    end)
  end)

  describe('input handling', function()
    it('should handle message input', function()
      buffer.create_chat_buffer(test_channel)

      -- Mock vim.ui.input
      local input_called = false
      local input_prompt = nil
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, callback) -- luacheck: ignore
        input_called = true
        input_prompt = opts.prompt
        callback('test message')
      end

      -- Mock events
      local _ = false
      local _ = nil
      local events = require('twitch-chat.events')
      events.on = function(event, callback)
        -- Do nothing
      end
      events.emit = function(event, data)
        -- Do nothing in test
      end

      buffer.open_input_buffer(test_channel)

      assert.is_true(input_called)
      assert.matches(test_channel, input_prompt)

      -- Restore original function
      vim.ui.input = original_input -- luacheck: ignore
    end)
  end)

  describe('channel switching', function()
    it('should provide channel selection', function()
      buffer.create_chat_buffer('channel1')
      buffer.create_chat_buffer('channel2')

      -- Mock vim.ui.select
      local select_called = false
      local select_items = nil
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(items, opts, callback) -- luacheck: ignore
        select_called = true
        select_items = items
        callback('channel1')
      end

      buffer.switch_channel_prompt()

      assert.is_true(select_called)
      assert.is_table(select_items)
      assert.equals(2, #select_items)

      -- Restore original function
      vim.ui.select = original_select -- luacheck: ignore
    end)

    it('should handle no channels gracefully', function()
      -- Mock vim.notify
      local notify_called = false
      local original_notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level) -- luacheck: ignore
        notify_called = true
      end

      buffer.switch_channel_prompt()

      assert.is_true(notify_called)

      -- Restore original function
      vim.notify = original_notify -- luacheck: ignore
    end)
  end)

  describe('highlighting', function()
    it('should apply highlights correctly', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      local highlights = {
        {
          line = 0,
          col_start = 0,
          col_end = 10,
          hl_group = 'Comment',
        },
        {
          line = 0,
          col_start = 15,
          col_end = 25,
          hl_group = 'Identifier',
        },
      }

      assert.has_no.errors(function()
        buffer.apply_highlights(chat_buffer, highlights)
      end)
    end)
  end)

  describe('virtual text', function()
    it('should handle virtual text for emotes', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)
      chat_buffer.virtual_text_enabled = true

      local emote_message = vim.tbl_extend('force', test_message, {
        emotes = {
          { name = 'Kappa', id = '25' },
          { name = 'PogChamp', id = '88' },
        },
      })

      buffer.add_message(test_channel, emote_message)

      -- Wait for processing
      vim.wait(100, function()
        return #chat_buffer.messages == 1
      end)

      assert.has_no.errors(function()
        buffer.apply_virtual_text(chat_buffer)
      end)
    end)
  end)

  describe('error handling', function()
    it('should handle invalid buffer operations gracefully', function()
      assert.has_no.errors(function()
        buffer.close_buffer('non_existent_channel')
      end)

      assert.has_no.errors(function()
        buffer.clear_buffer('non_existent_channel')
      end)

      assert.has_no.errors(function()
        buffer.toggle_auto_scroll('non_existent_channel')
      end)
    end)
  end)

  describe('performance', function()
    it('should handle large message volumes', function()
      local chat_buffer = buffer.create_chat_buffer(test_channel)

      -- Add many messages quickly
      local start_time = (vim.uv or vim.loop).hrtime()
      for i = 1, 1000 do
        buffer.add_message(
          test_channel,
          vim.tbl_extend('force', test_message, {
            id = 'perf_message_' .. i,
            content = 'Performance test message ' .. i,
          })
        )
      end
      local end_time = (vim.uv or vim.loop).hrtime()

      -- Should complete quickly (under 100ms)
      local elapsed_ms = (end_time - start_time) / 1000000
      assert.is_true(elapsed_ms < 100)

      -- Wait for all messages to be processed
      vim.wait(1000, function()
        return #chat_buffer.messages == chat_buffer.max_messages
      end)

      -- Should not exceed max_messages
      assert.is_true(#chat_buffer.messages <= chat_buffer.max_messages)
    end)
  end)
end)
