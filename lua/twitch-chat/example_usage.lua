---Example usage of the buffer and UI modules
---This file demonstrates how to use the twitch-chat modules

local M = {}
local uv = vim.uv or vim.loop

-- Load the modules
local buffer = require('twitch-chat.modules.buffer')
local ui = require('twitch-chat.modules.ui')
local events = require('twitch-chat.events')

-- Example configuration
local config = {
  ui = {
    layout = {
      type = 'float',
      position = 'center',
      size = 80,
      relative_to = 'editor',
    },
    float = {
      width = 0.8,
      height = 0.6,
      row = 0.2,
      col = 0.1,
      border = 'rounded',
      title = 'Twitch Chat',
      title_pos = 'center',
      style = 'minimal',
      focusable = true,
      zindex = 50,
    },
    highlights = {
      username = 'Identifier',
      timestamp = 'Comment',
      message = 'Normal',
      mention = 'WarningMsg',
      command = 'Function',
      emote = 'Special',
    },
    max_messages = 1000,
    auto_scroll = true,
    virtual_text_enabled = true,
  },
  keymaps = {
    send = '<CR>',
    close = 'q',
    scroll_up = '<C-u>',
    scroll_down = '<C-d>',
    switch_channel = '<C-t>',
    toggle_auto_scroll = '<C-a>',
    clear_buffer = '<C-l>',
    toggle_input = '<C-i>',
    cycle_layout = '<C-L>',
    focus_chat = '<C-c>',
    close_all = '<C-q>',
  },
}

---Initialize the example
function M.setup()
  -- Setup modules
  buffer.setup(config)
  ui.setup(config)

  -- Setup event handlers for demonstration
  events.on(events.SEND_MESSAGE, function(data)
    print('Send message event received:', vim.inspect(data))
    -- In a real implementation, this would send the message via websocket
    -- For now, we'll just echo it back as a received message
    local echo_message = {
      id = tostring(math.random(1000000)),
      username = 'you',
      content = data.content,
      timestamp = os.time(),
      badges = {},
      emotes = {},
      channel = data.channel,
      color = '#00FF00',
      is_mention = false,
      is_command = false,
    }

    -- Simulate delay and echo back
    vim.defer_fn(function()
      events.emit(events.MESSAGE_RECEIVED, {
        channel = data.channel,
        message = echo_message,
      })
    end, 100)
  end)

  print('Twitch Chat example initialized. Use M.demo() to start demo.')
end

---Run a demo of the chat system
function M.demo()
  local channel = 'example_channel'

  -- Create a buffer for the channel
  local _ = buffer.create_chat_buffer(channel) -- Buffer creation for example

  -- Show the buffer in UI
  ui.show_buffer(channel, 'float')

  -- Emit channel joined event
  events.emit(events.CHANNEL_JOINED, { channel = channel })

  -- Add some demo messages
  M.add_demo_messages(channel)

  print('Demo started for channel: ' .. channel)
  print('Press i to input a message, q to close')
end

---Add demo messages to showcase functionality
---@param channel string
function M.add_demo_messages(channel)
  local demo_messages = {
    {
      id = '1',
      username = 'viewer1',
      content = 'Hello everyone! PogChamp',
      timestamp = os.time() - 300,
      badges = { 'subscriber' },
      emotes = { { name = 'PogChamp', id = '88' } },
      channel = channel,
      color = '#FF69B4',
      is_mention = false,
      is_command = false,
    },
    {
      id = '2',
      username = 'moderator',
      content = 'Welcome to the stream!',
      timestamp = os.time() - 250,
      badges = { 'moderator', 'subscriber' },
      emotes = {},
      channel = channel,
      color = '#00FF00',
      is_mention = false,
      is_command = false,
    },
    {
      id = '3',
      username = 'viewer2',
      content = '@you nice to see you here!',
      timestamp = os.time() - 200,
      badges = {},
      emotes = {},
      channel = channel,
      color = '#1E90FF',
      is_mention = true,
      is_command = false,
    },
    {
      id = '4',
      username = 'bot',
      content = '!commands Type !help for available commands',
      timestamp = os.time() - 150,
      badges = { 'bot' },
      emotes = {},
      channel = channel,
      color = '#FFD700',
      is_mention = false,
      is_command = true,
    },
    {
      id = '5',
      username = 'viewer3',
      content = 'Great stream! Thanks for the content Kreygasm',
      timestamp = os.time() - 100,
      badges = { 'subscriber' },
      emotes = { { name = 'Kreygasm', id = '41' } },
      channel = channel,
      color = '#9370DB',
      is_mention = false,
      is_command = false,
    },
  }

  -- Add messages with delay to simulate real-time chat
  for i, message in ipairs(demo_messages) do
    vim.defer_fn(function()
      events.emit(events.MESSAGE_RECEIVED, {
        channel = channel,
        message = message,
      })
    end, i * 500) -- 500ms delay between messages
  end
end

---Demonstrate different layouts
function M.demo_layouts()
  local channel = 'layout_demo'

  -- Create buffer
  local _ = buffer.create_chat_buffer(channel) -- Buffer creation for example

  -- Show different layouts with delay
  local layouts = { 'float', 'vsplit', 'split', 'tab' }

  for i, layout in ipairs(layouts) do
    vim.defer_fn(function()
      ui.show_buffer(channel, layout)
      print('Layout changed to: ' .. layout)

      -- Add a message for this layout
      local message = {
        id = tostring(i),
        username = 'system',
        content = 'Now showing ' .. layout .. ' layout',
        timestamp = os.time(),
        badges = { 'system' },
        emotes = {},
        channel = channel,
        color = '#FF0000',
        is_mention = false,
        is_command = false,
      }

      events.emit(events.MESSAGE_RECEIVED, {
        channel = channel,
        message = message,
      })
    end, i * 2000) -- 2 second delay between layouts
  end
end

---Demonstrate performance with many messages
function M.demo_performance()
  local channel = 'performance_test'

  -- Create buffer
  local _ = buffer.create_chat_buffer(channel) -- Buffer creation for example
  ui.show_buffer(channel, 'float')

  local start_time = uv.hrtime()
  local message_count = 1000

  print('Starting performance test with ' .. message_count .. ' messages...')

  -- Add many messages rapidly
  for i = 1, message_count do
    local message = {
      id = tostring(i),
      username = 'user' .. (i % 10),
      content = 'Message number ' .. i .. ' with some content to test performance',
      timestamp = os.time() + i,
      badges = {},
      emotes = {},
      channel = channel,
      color = '#' .. string.format('%06x', math.random(0, 0xFFFFFF)),
      is_mention = i % 50 == 0, -- Every 50th message is a mention
      is_command = i % 100 == 0, -- Every 100th message is a command
    }

    events.emit(events.MESSAGE_RECEIVED, {
      channel = channel,
      message = message,
    })
  end

  -- Check performance after all messages are processed
  vim.defer_fn(function()
    local end_time = uv.hrtime()
    local duration = (end_time - start_time) / 1000000 -- Convert to milliseconds

    local stats = buffer.get_buffer_stats(channel)
    print('Performance test completed:')
    print('  Duration: ' .. string.format('%.2f', duration) .. 'ms')
    print('  Messages processed: ' .. (stats and stats.message_count or 0))
    print(
      '  Average update time: '
        .. string.format('%.2f', stats and stats.last_update_time or 0)
        .. 'ms'
    )

    local perf_stats = buffer.get_performance_stats()
    print(
      '  Overall performance: '
        .. string.format('%.2f', perf_stats.average_update_time)
        .. 'ms avg update time'
    )
  end, 2000)
end

---Clean up demo
function M.cleanup()
  ui.close_all_windows()
  events.clear_all()
  print('Demo cleanup completed')
end

-- Global commands for easy testing
vim.api.nvim_create_user_command('TwitchChatDemo', function()
  M.demo()
end, { desc = 'Start Twitch Chat demo' })

vim.api.nvim_create_user_command('TwitchChatDemoLayouts', function()
  M.demo_layouts()
end, { desc = 'Demo different layouts' })

vim.api.nvim_create_user_command('TwitchChatDemoPerformance', function()
  M.demo_performance()
end, { desc = 'Demo performance with many messages' })

vim.api.nvim_create_user_command('TwitchChatCleanup', function()
  M.cleanup()
end, { desc = 'Clean up demo' })

return M
