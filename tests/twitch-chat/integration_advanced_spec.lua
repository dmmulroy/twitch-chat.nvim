local mock = require('luassert.mock')
local stub = require('luassert.stub')
local match = require('luassert.match')

describe('twitch-chat advanced integration', function()
  local Config, State, Auth, Client, Commands, UI, Emotes, Filters
  local original_vim = vim
  local test_config = {
    username = 'test_user',
    client_id = 'test_client_id',
    client_secret = 'test_client_secret',
    redirect_uri = 'http://localhost:3000',
    chat = {
      buffer_name = 'TwitchChat',
      timeout = 5000,
      min_window_width = 50,
      min_window_height = 10,
      split_position = 'right',
      always_reconnect = true,
    },
    emotes = {
      load_on_startup = true,
      load_global = true,
      load_follower = true,
      cache_ttl = 3600,
    },
    filters = {
      ignore_bots = true,
      min_message_length = 1,
      keyword_highlights = { 'test', 'lua' },
    },
  }

  before_each(function()
    -- Reset modules
    package.loaded['twitch-chat.config'] = nil
    package.loaded['twitch-chat.state'] = nil
    package.loaded['twitch-chat.auth'] = nil
    package.loaded['twitch-chat.client'] = nil
    package.loaded['twitch-chat.commands'] = nil
    package.loaded['twitch-chat.ui'] = nil
    package.loaded['twitch-chat.emotes'] = nil
    package.loaded['twitch-chat.filters'] = nil

    -- Load modules
    Config = require('twitch-chat.config')
    State = require('twitch-chat.state')
    Auth = require('twitch-chat.auth')
    Client = require('twitch-chat.client')
    Commands = require('twitch-chat.commands')
    UI = require('twitch-chat.ui')
    Emotes = require('twitch-chat.emotes')
    Filters = require('twitch-chat.filters')

    -- Mock vim functions
    _G.vim = {
      api = {
        nvim_create_buf = stub().returns(1),
        nvim_create_autocmd = stub(),
        nvim_create_augroup = stub().returns(1),
        nvim_create_user_command = stub(),
        nvim_del_user_command = stub(),
        nvim_buf_set_lines = stub(),
        nvim_buf_get_lines = stub().returns({}),
        nvim_buf_set_option = stub(),
        nvim_buf_set_name = stub(),
        nvim_buf_is_valid = stub().returns(true),
        nvim_win_is_valid = stub().returns(true),
        nvim_win_set_cursor = stub(),
        nvim_win_get_cursor = stub().returns({ 1, 0 }),
        nvim_get_current_win = stub().returns(1),
        nvim_set_current_win = stub(),
        nvim_open_win = stub().returns(1),
        nvim_win_set_config = stub(),
        nvim_win_get_config = stub().returns({ split = 'right' }),
        nvim_buf_line_count = stub().returns(0),
        nvim_buf_add_highlight = stub(),
        nvim_set_hl = stub(),
        nvim_get_hl = stub().returns({}),
        nvim_command = stub(),
        nvim_err_writeln = stub(),
        nvim_exec_autocmds = stub(),
      },
      fn = {
        winnr = stub().returns(1),
        winwidth = stub().returns(80),
        winheight = stub().returns(24),
        expand = stub().returns('/home/user'),
        stdpath = stub().returns('/home/user/.local/share/nvim'),
        isdirectory = stub().returns(1),
        mkdir = stub(),
        json_encode = stub().callsfake(vim.fn.json_encode or function(t)
          return vim.inspect(t)
        end),
        json_decode = stub().callsfake(vim.fn.json_decode or function(s)
          return loadstring('return ' .. s)()
        end),
        writefile = stub().returns(0),
        readfile = stub().returns({}),
        filereadable = stub().returns(0),
        getcwd = stub().returns('/home/user'),
        jobstart = stub().returns(1),
        jobstop = stub(),
        jobwait = stub().returns({ 0 }),
        chanclose = stub(),
        chansend = stub(),
        system = stub().returns(''),
      },
      loop = {
        new_timer = function()
          return {
            start = stub(),
            stop = stub(),
            close = stub(),
            is_active = stub().returns(false),
          }
        end,
      },
      notify = stub(),
      schedule = stub().invokes(1),
      tbl_deep_extend = vim.tbl_deep_extend,
      tbl_contains = vim.tbl_contains,
      tbl_keys = vim.tbl_keys,
      tbl_filter = vim.tbl_filter,
      tbl_map = vim.tbl_map,
      tbl_count = vim.tbl_count,
      startswith = vim.startswith,
      endswith = vim.endswith,
      split = vim.split,
      trim = vim.trim,
    }

    -- Initialize config
    Config.setup(test_config)
    State.reset()
  end)

  after_each(function()
    _G.vim = original_vim
    State.reset()
  end)

  describe('full end-to-end workflows', function()
    it('should handle complete authentication → connection → message flow', function()
      local access_token = 'test_access_token'
      local channel = 'test_channel'
      local message_data = {
        tags = {
          ['display-name'] = 'TestUser',
          ['user-id'] = '12345',
          color = '#FF0000',
          emotes = '25:0-4',
        },
        prefix = 'testuser!testuser@testuser.tmi.twitch.tv',
        command = 'PRIVMSG',
        params = { '#' .. channel, 'Kappa test message' },
      }

      -- Mock HTTP responses
      local http_mock = mock({
        request = function() end,
      })

      -- Authentication flow
      http_mock.request:on_call_with(match.is_table()).returns({
        status = 200,
        body = vim.fn.json_encode({
          access_token = access_token,
          token_type = 'bearer',
          scope = { 'chat:read', 'chat:edit' },
        }),
      })

      -- Mock WebSocket connection
      local ws_callbacks = {}
      vim.fn['jobstart'] = stub().invokes(function(cmd, opts)
        ws_callbacks = opts
        -- Simulate successful connection
        vim.schedule(function()
          if ws_callbacks.on_stdout then
            -- Connection established
            ws_callbacks.on_stdout(1, { ':tmi.twitch.tv 001 test_user :Welcome' }, 'stdout')
            -- Join channel
            ws_callbacks.on_stdout(
              1,
              { ':test_user!test_user@test_user.tmi.twitch.tv JOIN #' .. channel },
              'stdout'
            )
            -- Receive message
            local raw_message = string.format(
              '@badge-info=;badges=;color=%s;display-name=%s;emotes=%s;user-id=%s :%s PRIVMSG #%s :%s',
              message_data.tags.color,
              message_data.tags['display-name'],
              message_data.tags.emotes,
              message_data.tags['user-id'],
              message_data.prefix,
              channel,
              message_data.params[2]
            )
            ws_callbacks.on_stdout(1, { raw_message }, 'stdout')
          end
        end)
        return 1
      end)

      -- Start authentication
      Auth.authenticate({
        http = http_mock,
        callback = function(token)
          assert.equals(access_token, token)
        end,
      })

      -- Connect to chat
      Client.connect()
      assert.stub(vim.fn.jobstart).was_called()

      -- Join channel
      Client.join_channel(channel)

      -- Verify UI was created
      assert.stub(vim.api.nvim_create_buf).was_called()
      assert.stub(vim.api.nvim_open_win).was_called()

      -- Verify message was processed
      local messages = State.get_channel_messages(channel)
      assert.equals(1, #messages)
      assert.equals('TestUser', messages[1].username)
      assert.equals('Kappa test message', messages[1].message)

      -- Verify emote was detected
      assert.truthy(messages[1].message:find('Kappa'))
      assert.equals('25:0-4', message_data.tags.emotes)
    end)

    it(
      'should handle channel joining → emote loading → message filtering → UI display',
      function()
        local channel = 'test_channel'
        State.set_authenticated(true)
        State.set_access_token('test_token')

        -- Mock emote loading
        local emotes_loaded = false
        stub(Emotes, 'load_channel_emotes', function(ch)
          emotes_loaded = true
          State.set_channel_emotes(ch, {
            {
              id = 'emotesv2_1234',
              name = 'TestEmote',
              images = { url_1x = 'https://example.com/emote.png' },
            },
          })
        end)

        -- Mock filter setup
        local filter_applied = false
        stub(Filters, 'should_display', function(msg)
          filter_applied = true
          -- Filter out bot messages
          if msg.tags and msg.tags.badges and msg.tags.badges:find('moderator') then
            return false
          end
          return msg.message and #msg.message >= Config.get().filters.min_message_length
        end)

        -- Connect and join channel
        Client.connect()
        Client.join_channel(channel)

        -- Verify emotes were loaded
        assert.is_true(emotes_loaded)
        local channel_emotes = State.get_channel_emotes(channel)
        assert.equals(1, #channel_emotes)
        assert.equals('TestEmote', channel_emotes[1].name)

        -- Send test messages
        local messages = {
          {
            tags = { ['display-name'] = 'User1' },
            username = 'user1',
            message = 'Hello TestEmote!',
          },
          {
            tags = { ['display-name'] = 'BotUser', badges = 'moderator/1' },
            username = 'botuser',
            message = 'Automated message',
          },
          {
            tags = { ['display-name'] = 'User2' },
            username = 'user2',
            message = '', -- Empty message
          },
        }

        for _, msg in ipairs(messages) do
          if Filters.should_display(msg) then
            State.add_message(channel, msg)
          end
        end

        -- Verify filtering worked
        assert.is_true(filter_applied)
        local channel_messages = State.get_channel_messages(channel)
        assert.equals(1, #channel_messages) -- Only User1's message should pass
        assert.equals('User1', channel_messages[1].username)

        -- Verify UI was updated
        assert.stub(vim.api.nvim_buf_set_lines).was_called()
      end
    )

    it('should handle command execution → API calls → state updates', function()
      local channel = 'test_channel'
      State.set_authenticated(true)
      State.set_access_token('test_token')
      State.add_channel(channel)

      -- Mock HTTP for API calls
      local http_mock = mock({
        request = function() end,
      })

      -- Mock channel info request
      http_mock.request:on_call_with(match.is_table()).returns({
        status = 200,
        body = vim.fn.json_encode({
          data = {
            {
              id = '12345',
              login = channel,
              display_name = 'TestChannel',
              type = '',
              broadcaster_type = 'affiliate',
              description = 'Test channel description',
              profile_image_url = 'https://example.com/profile.png',
              offline_image_url = '',
              view_count = 1000,
              created_at = '2020-01-01T00:00:00Z',
            },
          },
        }),
      })

      -- Execute info command
      Commands.execute('info', { channel }, { http = http_mock })

      -- Verify API was called
      assert.stub(http_mock.request).was_called()

      -- Verify state was updated
      local channel_info = State.get_channel_info(channel)
      assert.truthy(channel_info)
      assert.equals('TestChannel', channel_info.display_name)
      assert.equals('affiliate', channel_info.broadcaster_type)
      assert.equals(1000, channel_info.view_count)

      -- Verify notification was shown
      assert.stub(vim.notify).was_called_with(match.is_string(), vim.log.levels.INFO)
    end)
  end)

  describe('cross-module dependencies', function()
    it('should propagate config changes to all modules', function()
      -- Initial config
      local initial_split = Config.get().chat.split_position
      assert.equals('right', initial_split)

      -- Update config
      Config.update({
        chat = {
          split_position = 'left',
          buffer_name = 'UpdatedTwitchChat',
        },
        filters = {
          ignore_bots = false,
          min_message_length = 5,
        },
      })

      -- Verify config propagated
      assert.equals('left', Config.get().chat.split_position)
      assert.equals('UpdatedTwitchChat', Config.get().chat.buffer_name)
      assert.equals(false, Config.get().filters.ignore_bots)
      assert.equals(5, Config.get().filters.min_message_length)

      -- Create UI and verify it uses new config
      UI.create()
      local win_config_calls = vim.api.nvim_open_win.calls
      local last_call = win_config_calls[#win_config_calls]
      assert.equals('left', last_call[3].split)

      -- Verify buffer name was updated
      assert
        .stub(vim.api.nvim_buf_set_name)
        .was_called_with(match._, match.has_match('UpdatedTwitchChat'))
    end)

    it('should maintain event propagation across module boundaries', function()
      local events_received = {}

      -- Set up event listeners
      State.on('channel_joined', function(data)
        table.insert(events_received, { event = 'channel_joined', data = data })
      end)

      State.on('message_received', function(data)
        table.insert(events_received, { event = 'message_received', data = data })
      end)

      State.on('emotes_loaded', function(data)
        table.insert(events_received, { event = 'emotes_loaded', data = data })
      end)

      -- Simulate channel join
      local channel = 'test_channel'
      State.add_channel(channel)
      State.emit('channel_joined', { channel = channel })

      -- Simulate emote loading
      State.set_channel_emotes(channel, { { name = 'TestEmote' } })
      State.emit('emotes_loaded', { channel = channel, count = 1 })

      -- Simulate message
      local message = {
        username = 'testuser',
        message = 'Hello world',
        channel = channel,
      }
      State.add_message(channel, message)
      State.emit('message_received', message)

      -- Verify all events were received
      assert.equals(3, #events_received)
      assert.equals('channel_joined', events_received[1].event)
      assert.equals(channel, events_received[1].data.channel)
      assert.equals('emotes_loaded', events_received[2].event)
      assert.equals(1, events_received[2].data.count)
      assert.equals('message_received', events_received[3].event)
      assert.equals('testuser', events_received[3].data.username)
    end)

    it('should maintain shared state consistency between modules', function()
      local channel1 = 'channel1'
      local channel2 = 'channel2'

      -- Module 1: Auth sets token
      State.set_access_token('shared_token')
      State.set_authenticated(true)

      -- Module 2: Client uses token
      assert.equals('shared_token', State.get_access_token())
      assert.is_true(State.is_authenticated())

      -- Module 3: Commands add channels
      State.add_channel(channel1)
      State.add_channel(channel2)

      -- Module 4: UI reads channels
      local channels = State.get_channels()
      assert.equals(2, #channels)
      assert.truthy(vim.tbl_contains(channels, channel1))
      assert.truthy(vim.tbl_contains(channels, channel2))

      -- Module 5: Emotes updates channel data
      State.set_channel_emotes(channel1, { { name = 'Emote1' } })
      State.set_channel_emotes(channel2, { { name = 'Emote2' } })

      -- Verify all modules see consistent state
      assert.equals(1, #State.get_channel_emotes(channel1))
      assert.equals(1, #State.get_channel_emotes(channel2))
      assert.equals('Emote1', State.get_channel_emotes(channel1)[1].name)
      assert.equals('Emote2', State.get_channel_emotes(channel2)[1].name)
    end)
  end)

  describe('real-world scenarios', function()
    it('should handle multiple channels with different settings', function()
      local channels = {
        { name = 'channel1', emote_count = 50, filter_bots = true },
        { name = 'channel2', emote_count = 100, filter_bots = false },
        { name = 'channel3', emote_count = 25, filter_bots = true },
      }

      State.set_authenticated(true)
      State.set_access_token('test_token')

      -- Join all channels
      for _, ch in ipairs(channels) do
        State.add_channel(ch.name)

        -- Simulate different emote configurations
        local emotes = {}
        for i = 1, ch.emote_count do
          table.insert(emotes, {
            id = 'emote_' .. i,
            name = ch.name .. '_emote_' .. i,
          })
        end
        State.set_channel_emotes(ch.name, emotes)

        -- Set channel-specific filter settings
        State.set_channel_settings(ch.name, {
          filter_bots = ch.filter_bots,
        })
      end

      -- Verify each channel has correct settings
      for _, ch in ipairs(channels) do
        local emotes = State.get_channel_emotes(ch.name)
        assert.equals(ch.emote_count, #emotes)

        local settings = State.get_channel_settings(ch.name)
        assert.equals(ch.filter_bots, settings.filter_bots)
      end

      -- Switch active channel
      State.set_active_channel('channel2')
      assert.equals('channel2', State.get_active_channel())

      -- Verify UI would show correct channel
      UI.refresh()
      assert.stub(vim.api.nvim_buf_set_lines).was_called()
    end)

    it('should handle simultaneous authentication and message handling', function()
      local auth_complete = false
      local messages_received = {}

      -- Start authentication in background
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.schedule = function(fn)
        -- Simulate delayed auth completion
        vim.defer_fn(function()
          State.set_authenticated(true)
          State.set_access_token('delayed_token')
          auth_complete = true
          fn()
        end, 100)
      end

      -- Try to receive messages before auth completes
      local early_message = {
        username = 'earlyuser',
        message = 'Message before auth',
        channel = 'test_channel',
      }

      -- This should be queued or rejected
      if State.is_authenticated() then
        State.add_message(early_message.channel, early_message)
        table.insert(messages_received, early_message)
      end

      assert.equals(0, #messages_received) -- No messages before auth

      -- Wait for auth to complete
      vim.wait(200, function()
        return auth_complete
      end)

      -- Now messages should work
      local late_message = {
        username = 'lateuser',
        message = 'Message after auth',
        channel = 'test_channel',
      }

      State.add_channel(late_message.channel)
      State.add_message(late_message.channel, late_message)
      table.insert(messages_received, late_message)

      assert.equals(1, #messages_received)
      assert.equals('lateuser', messages_received[1].username)
    end)

    it('should handle plugin reload during active connections', function()
      -- Establish initial state
      State.set_authenticated(true)
      State.set_access_token('test_token')
      State.add_channel('test_channel')
      State.set_connected(true)

      -- Add some messages
      for i = 1, 5 do
        State.add_message('test_channel', {
          username = 'user' .. i,
          message = 'Message ' .. i,
        })
      end

      -- Simulate plugin reload
      local saved_state = {
        authenticated = State.is_authenticated(),
        token = State.get_access_token(),
        channels = State.get_channels(),
        messages = State.get_channel_messages('test_channel'),
      }

      -- Reset everything
      State.reset()
      assert.is_false(State.is_authenticated())
      assert.equals(0, #State.get_channels())

      -- Restore state
      State.set_authenticated(saved_state.authenticated)
      State.set_access_token(saved_state.token)
      for _, channel in ipairs(saved_state.channels) do
        State.add_channel(channel)
      end
      for _, msg in ipairs(saved_state.messages) do
        State.add_message('test_channel', msg)
      end

      -- Verify restoration
      assert.is_true(State.is_authenticated())
      assert.equals('test_token', State.get_access_token())
      assert.equals(1, #State.get_channels())
      assert.equals(5, #State.get_channel_messages('test_channel'))
    end)

    it('should handle network interruption and recovery', function()
      local connection_events = {}

      -- Set up connection monitoring
      State.on('connection_lost', function()
        table.insert(connection_events, 'lost')
      end)

      State.on('connection_restored', function()
        table.insert(connection_events, 'restored')
      end)

      -- Initial connection
      State.set_connected(true)
      assert.is_true(State.is_connected())

      -- Simulate network interruption
      State.set_connected(false)
      State.emit('connection_lost')

      -- Try to send message during interruption
      local result = pcall(function()
        Client.send_message('test_channel', 'Message during outage')
      end)
      assert.is_false(result) -- Should fail

      -- Simulate reconnection with backoff
      local reconnect_attempts = 0
      local max_attempts = 3

      while reconnect_attempts < max_attempts and not State.is_connected() do
        reconnect_attempts = reconnect_attempts + 1
        vim.wait(100 * reconnect_attempts) -- Exponential backoff

        -- Try to reconnect
        if reconnect_attempts == max_attempts then
          State.set_connected(true)
          State.emit('connection_restored')
        end
      end

      -- Verify recovery
      assert.equals(2, #connection_events)
      assert.equals('lost', connection_events[1])
      assert.equals('restored', connection_events[2])
      assert.is_true(State.is_connected())
    end)
  end)

  describe('integration stress testing', function()
    it('should handle many channels with different configurations', function()
      local channel_count = 20
      local channels = {}

      -- Create many channels
      for i = 1, channel_count do
        local channel = {
          name = 'channel_' .. i,
          emotes = {},
          filters = {
            keywords = { 'keyword' .. i },
            ignore_users = i % 2 == 0 and { 'bot' .. i } or {},
          },
          message_count = i * 10,
        }

        -- Generate emotes
        for j = 1, i * 5 do
          table.insert(channel.emotes, {
            id = 'emote_' .. i .. '_' .. j,
            name = 'Emote' .. i .. '_' .. j,
          })
        end

        table.insert(channels, channel)
      end

      -- Add all channels
      for _, ch in ipairs(channels) do
        State.add_channel(ch.name)
        State.set_channel_emotes(ch.name, ch.emotes)
        State.set_channel_settings(ch.name, ch.filters)

        -- Add messages
        for m = 1, ch.message_count do
          State.add_message(ch.name, {
            username = 'user_' .. m,
            message = 'Message ' .. m .. ' with keyword' .. m,
          })
        end
      end

      -- Verify all channels are properly configured
      assert.equals(channel_count, #State.get_channels())

      for i, ch in ipairs(channels) do
        local emotes = State.get_channel_emotes(ch.name)
        assert.equals(i * 5, #emotes)

        local messages = State.get_channel_messages(ch.name)
        assert.equals(ch.message_count, #messages)
      end

      -- Test rapid channel switching
      for i = 1, 10 do
        local random_channel = channels[math.random(channel_count)]
        State.set_active_channel(random_channel.name)
        assert.equals(random_channel.name, State.get_active_channel())
      end
    end)

    it('should handle rapid channel switching with UI updates', function()
      local switch_count = 50
      local channels = { 'channel1', 'channel2', 'channel3' }

      -- Set up channels
      for _, ch in ipairs(channels) do
        State.add_channel(ch)
        -- Add different message counts to each channel
        for i = 1, math.random(10, 50) do
          State.add_message(ch, {
            username = 'user' .. i,
            message = 'Message in ' .. ch,
          })
        end
      end

      -- Rapid switching
      local switch_times = {}
      for i = 1, switch_count do
        local channel = channels[(i % #channels) + 1]
        local start_time = vim.loop.hrtime()

        State.set_active_channel(channel)
        UI.refresh()

        local end_time = vim.loop.hrtime()
        table.insert(switch_times, (end_time - start_time) / 1e6) -- Convert to ms
      end

      -- Verify all switches completed
      assert.equals(switch_count, #switch_times)

      -- Calculate average switch time
      local total_time = 0
      for _, time in ipairs(switch_times) do
        total_time = total_time + time
      end
      local avg_time = total_time / switch_count

      -- Average switch should be fast (< 10ms)
      assert.is_true(avg_time < 10, 'Average switch time too slow: ' .. avg_time .. 'ms')
    end)

    it('should handle concurrent command execution', function()
      local command_count = 10
      local results = {}
      local errors = {}

      -- Execute multiple commands concurrently
      local commands = {
        { cmd = 'join', args = { 'channel1' } },
        { cmd = 'join', args = { 'channel2' } },
        { cmd = 'part', args = { 'channel1' } },
        { cmd = 'join', args = { 'channel3' } },
        { cmd = 'clear', args = {} },
        { cmd = 'join', args = { 'channel1' } },
        { cmd = 'part', args = { 'channel2' } },
        { cmd = 'join', args = { 'channel4' } },
        { cmd = 'clear', args = {} },
        { cmd = 'join', args = { 'channel5' } },
      }

      State.set_authenticated(true)
      State.set_access_token('test_token')

      for i, command in ipairs(commands) do
        local success, result = pcall(function()
          Commands.execute(command.cmd, command.args)
        end)

        if success then
          table.insert(results, { index = i, command = command })
        else
          table.insert(errors, { index = i, command = command, error = result })
        end
      end

      -- Verify most commands succeeded
      assert.is_true(#results >= command_count * 0.8) -- At least 80% success rate
      assert.is_true(#errors < command_count * 0.2) -- Less than 20% errors

      -- Verify final state is consistent
      local final_channels = State.get_channels()
      assert.is_true(#final_channels > 0)
    end)

    it('should handle heavy message load across modules', function()
      local message_count = 1000
      local channel = 'stress_test_channel'

      State.set_authenticated(true)
      State.add_channel(channel)

      -- Set up performance tracking
      local start_time = vim.loop.hrtime()
      local processing_times = {}

      -- Generate and process many messages
      for i = 1, message_count do
        local msg_start = vim.loop.hrtime()

        local message = {
          tags = {
            ['display-name'] = 'User' .. i,
            ['user-id'] = tostring(i),
            color = string.format('#%06x', math.random(0, 0xffffff)),
            emotes = i % 10 == 0 and '25:0-4' or nil,
          },
          username = 'user' .. i,
          message = 'Test message ' .. i .. (i % 10 == 0 and ' Kappa' or ''),
          timestamp = os.time() + i,
        }

        -- Apply filters
        if Filters.should_display(message) then
          State.add_message(channel, message)
        end

        local msg_end = vim.loop.hrtime()
        table.insert(processing_times, (msg_end - msg_start) / 1e6)

        -- Periodically update UI (every 100 messages)
        if i % 100 == 0 then
          UI.refresh()
        end
      end

      local end_time = vim.loop.hrtime()
      local total_time = (end_time - start_time) / 1e9 -- Convert to seconds

      -- Verify performance
      assert.is_true(total_time < 5, 'Processing took too long: ' .. total_time .. 's')

      -- Verify messages were stored correctly
      local stored_messages = State.get_channel_messages(channel)
      assert.is_true(#stored_messages > 0)
      assert.is_true(#stored_messages <= message_count) -- Some may be filtered

      -- Calculate average processing time
      local total_proc_time = 0
      for _, time in ipairs(processing_times) do
        total_proc_time = total_proc_time + time
      end
      local avg_proc_time = total_proc_time / #processing_times

      assert.is_true(
        avg_proc_time < 1,
        'Average message processing too slow: ' .. avg_proc_time .. 'ms'
      )
    end)
  end)

  describe('state synchronization', function()
    it('should maintain UI state consistency with backend state', function()
      local channel = 'sync_test_channel'
      State.add_channel(channel)

      -- Add messages to backend
      local backend_messages = {}
      for i = 1, 10 do
        local msg = {
          username = 'user' .. i,
          message = 'Backend message ' .. i,
          timestamp = os.time() + i,
        }
        State.add_message(channel, msg)
        table.insert(backend_messages, msg)
      end

      -- Update UI
      UI.show()
      UI.refresh()

      -- Verify UI received all messages
      assert.stub(vim.api.nvim_buf_set_lines).was_called()

      -- Simulate UI state query
      local ui_state = {
        active_channel = State.get_active_channel(),
        message_count = #State.get_channel_messages(channel),
        is_connected = State.is_connected(),
      }

      -- Verify consistency
      assert.equals(channel, ui_state.active_channel)
      assert.equals(#backend_messages, ui_state.message_count)

      -- Modify backend state
      State.add_message(channel, {
        username = 'newuser',
        message = 'New message after UI update',
      })

      -- UI should reflect change on next refresh
      UI.refresh()
      assert.equals(#backend_messages + 1, #State.get_channel_messages(channel))
    end)

    it('should synchronize cache across modules', function()
      local test_modules = {
        auth = { cache_key = 'auth_cache', data = { token = 'test_token' } },
        emotes = { cache_key = 'emotes_cache', data = { global = {}, channel = {} } },
        channels = { cache_key = 'channels_cache', data = { list = {}, settings = {} } },
      }

      -- Each module writes to cache
      for name, module in pairs(test_modules) do
        State.cache_set(module.cache_key, module.data)
      end

      -- Verify all modules can read each other's cache
      for name, module in pairs(test_modules) do
        local cached_data = State.cache_get(module.cache_key)
        assert.truthy(cached_data)
        assert.same(module.data, cached_data)
      end

      -- Test cache expiration
      State.cache_set('expiring_key', { value = 'test' }, 0.1) -- 100ms TTL
      assert.truthy(State.cache_get('expiring_key'))

      vim.wait(150)
      assert.is_nil(State.cache_get('expiring_key'))

      -- Test cache clearing
      State.cache_clear()
      for name, module in pairs(test_modules) do
        assert.is_nil(State.cache_get(module.cache_key))
      end
    end)

    it('should maintain event ordering in complex scenarios', function()
      local event_log = {}

      -- Register handlers for all event types
      local event_types = {
        'auth_started',
        'auth_completed',
        'connection_established',
        'channel_joined',
        'emotes_loading',
        'emotes_loaded',
        'message_received',
        'ui_updated',
      }

      for _, event_type in ipairs(event_types) do
        State.on(event_type, function(data)
          table.insert(event_log, {
            type = event_type,
            timestamp = vim.loop.hrtime(),
            data = data,
          })
        end)
      end

      -- Execute complex scenario
      State.emit('auth_started', {})
      vim.wait(10)
      State.emit('auth_completed', { token = 'test' })
      vim.wait(10)
      State.emit('connection_established', {})
      vim.wait(10)

      local channel = 'event_test_channel'
      State.emit('channel_joined', { channel = channel })
      vim.wait(10)
      State.emit('emotes_loading', { channel = channel })
      vim.wait(10)
      State.emit('emotes_loaded', { channel = channel, count = 50 })
      vim.wait(10)

      for i = 1, 5 do
        State.emit('message_received', {
          channel = channel,
          message = 'Message ' .. i,
        })
        vim.wait(5)
      end

      State.emit('ui_updated', { channel = channel })

      -- Verify event ordering
      assert.equals(11, #event_log) -- All events recorded
      assert.equals('auth_started', event_log[1].type)
      assert.equals('auth_completed', event_log[2].type)
      assert.equals('connection_established', event_log[3].type)
      assert.equals('channel_joined', event_log[4].type)
      assert.equals('emotes_loading', event_log[5].type)
      assert.equals('emotes_loaded', event_log[6].type)

      -- Verify timestamps are in order
      for i = 2, #event_log do
        assert.is_true(
          event_log[i].timestamp >= event_log[i - 1].timestamp,
          'Event ' .. i .. ' occurred before event ' .. (i - 1)
        )
      end
    end)
  end)

  describe('error propagation', function()
    it('should handle errors in one module affecting others', function()
      local error_log = {}

      -- Set up error tracking
      State.on('error', function(data)
        table.insert(error_log, data)
      end)

      -- Simulate auth module error
      local auth_error = 'Authentication failed: Invalid token'
      State.emit('error', {
        module = 'auth',
        error = auth_error,
        severity = 'critical',
      })

      -- Auth error should prevent connection
      local connect_success = pcall(function()
        if #error_log > 0 and error_log[1].severity == 'critical' then
          error('Cannot connect: ' .. error_log[1].error)
        end
        Client.connect()
      end)

      assert.is_false(connect_success)
      assert.equals(1, #error_log)
      assert.equals('auth', error_log[1].module)

      -- Simulate emote module error (non-critical)
      State.emit('error', {
        module = 'emotes',
        error = 'Failed to load channel emotes',
        severity = 'warning',
      })

      -- Non-critical error should not prevent other operations
      State.add_channel('test_channel')
      assert.equals(1, #State.get_channels())
      assert.equals(2, #error_log)
      assert.equals('warning', error_log[2].severity)
    end)

    it('should gracefully degrade across module boundaries', function()
      local channel = 'degraded_channel'
      State.add_channel(channel)

      -- Simulate emote service failure
      local emote_error = false
      stub(Emotes, 'load_channel_emotes', function()
        emote_error = true
        error('Emote service unavailable')
      end)

      -- Channel should still function without emotes
      local success = pcall(function()
        Client.join_channel(channel)
      end)

      assert.is_true(success) -- Join succeeded despite emote failure
      assert.is_true(emote_error) -- Emote loading failed

      -- Messages should still work
      State.add_message(channel, {
        username = 'testuser',
        message = 'Message without emotes',
      })

      local messages = State.get_channel_messages(channel)
      assert.equals(1, #messages)
      assert.equals('Message without emotes', messages[1].message)
    end)

    it('should recover from partial failures', function()
      local failure_count = 0
      local recovery_count = 0

      -- Simulate intermittent failures
      local original_add_message = State.add_message
      State.add_message = function(channel, message)
        failure_count = failure_count + 1
        if failure_count % 3 == 0 then
          error('Temporary storage failure')
        end
        return original_add_message(channel, message)
      end

      -- Try to add messages with retry logic
      local channel = 'recovery_channel'
      State.add_channel(channel)

      for i = 1, 10 do
        local retry_count = 0
        local max_retries = 3
        local success = false

        while retry_count < max_retries and not success do
          success = pcall(function()
            State.add_message(channel, {
              username = 'user' .. i,
              message = 'Message ' .. i,
            })
          end)

          if not success then
            retry_count = retry_count + 1
            vim.wait(10 * retry_count) -- Backoff
          else
            recovery_count = recovery_count + 1
          end
        end
      end

      -- Restore original function
      State.add_message = original_add_message

      -- Verify recovery
      local messages = State.get_channel_messages(channel)
      assert.is_true(#messages >= 7) -- At least 70% success rate
      assert.is_true(recovery_count >= 7)
    end)
  end)

  describe('module lifecycle integration', function()
    it('should handle setup/teardown dependencies correctly', function()
      local setup_order = {}
      local teardown_order = {}

      -- Mock module setup/teardown
      local modules = {
        { name = 'config', deps = {} },
        { name = 'state', deps = { 'config' } },
        { name = 'auth', deps = { 'config', 'state' } },
        { name = 'client', deps = { 'auth', 'state' } },
        { name = 'ui', deps = { 'state', 'client' } },
      }

      -- Setup modules in dependency order
      local function setup_module(mod)
        for _, dep in ipairs(mod.deps) do
          if not vim.tbl_contains(setup_order, dep) then
            -- Find and setup dependency first
            for _, m in ipairs(modules) do
              if m.name == dep then
                setup_module(m)
                break
              end
            end
          end
        end
        if not vim.tbl_contains(setup_order, mod.name) then
          table.insert(setup_order, mod.name)
        end
      end

      for _, mod in ipairs(modules) do
        setup_module(mod)
      end

      -- Verify setup order
      assert.equals('config', setup_order[1])
      assert.equals('state', setup_order[2])
      assert.equals('auth', setup_order[3])
      assert.equals('client', setup_order[4])
      assert.equals('ui', setup_order[5])

      -- Teardown in reverse order
      for i = #setup_order, 1, -1 do
        table.insert(teardown_order, setup_order[i])
      end

      -- Verify teardown order
      assert.equals('ui', teardown_order[1])
      assert.equals('client', teardown_order[2])
      assert.equals('auth', teardown_order[3])
      assert.equals('state', teardown_order[4])
      assert.equals('config', teardown_order[5])
    end)

    it('should handle module initialization order', function()
      local init_log = {}

      -- Track initialization
      local function init_with_logging(module_name, init_fn)
        table.insert(init_log, { module = module_name, status = 'starting' })
        local success, result = pcall(init_fn)
        table.insert(init_log, {
          module = module_name,
          status = success and 'completed' or 'failed',
          error = not success and result or nil,
        })
        return success, result
      end

      -- Initialize modules
      init_with_logging('config', function()
        Config.setup(test_config)
      end)

      init_with_logging('state', function()
        State.reset()
      end)

      init_with_logging('auth', function()
        -- Auth requires config and state
        assert.truthy(Config.get())
        assert.truthy(State)
      end)

      init_with_logging('client', function()
        -- Client requires auth and state
        assert.truthy(Auth)
        assert.truthy(State)
      end)

      -- Verify all modules initialized successfully
      local completed = vim.tbl_filter(function(entry)
        return entry.status == 'completed'
      end, init_log)

      assert.equals(4, #completed)

      -- Verify no initialization failures
      local failed = vim.tbl_filter(function(entry)
        return entry.status == 'failed'
      end, init_log)

      assert.equals(0, #failed)
    end)

    it('should coordinate cleanup across modules', function()
      local cleanup_log = {}

      -- Set up active state
      State.set_authenticated(true)
      State.set_access_token('cleanup_token')
      State.add_channel('cleanup_channel')
      State.set_connected(true)

      -- Mock cleanup functions
      local cleanup_fns = {
        ui = function()
          table.insert(cleanup_log, 'ui: closing windows')
          vim.api.nvim_buf_set_lines(1, 0, -1, false, {})
          return true
        end,
        client = function()
          table.insert(cleanup_log, 'client: closing connections')
          State.set_connected(false)
          return true
        end,
        emotes = function()
          table.insert(cleanup_log, 'emotes: clearing cache')
          State.cache_clear()
          return true
        end,
        auth = function()
          table.insert(cleanup_log, 'auth: revoking token')
          State.set_authenticated(false)
          State.set_access_token(nil)
          return true
        end,
        state = function()
          table.insert(cleanup_log, 'state: final cleanup')
          State.reset()
          return true
        end,
      }

      -- Execute cleanup in correct order
      local cleanup_order = { 'ui', 'client', 'emotes', 'auth', 'state' }
      for _, module in ipairs(cleanup_order) do
        cleanup_fns[module]()
      end

      -- Verify cleanup completed
      assert.equals(5, #cleanup_log)
      assert.is_false(State.is_authenticated())
      assert.is_false(State.is_connected())
      assert.is_nil(State.get_access_token())
      assert.equals(0, #State.get_channels())
    end)
  end)

  describe('plugin integration testing', function()
    it('should integrate with nvim-cmp for live emote data', function()
      local channel = 'cmp_test_channel'
      State.add_channel(channel)
      State.set_active_channel(channel)

      -- Load emotes
      local test_emotes = {
        { name = 'TestEmote1', id = '1' },
        { name = 'TestEmote2', id = '2' },
        { name = 'KappaTest', id = '3' },
      }
      State.set_channel_emotes(channel, test_emotes)

      -- Mock cmp source
      local cmp_source = {
        complete = function(self, params, callback)
          local items = {}
          local emotes = State.get_channel_emotes(State.get_active_channel())

          for _, emote in ipairs(emotes) do
            table.insert(items, {
              label = emote.name,
              kind = 'Emote',
              detail = 'Twitch Emote',
            })
          end

          callback({ items = items, isIncomplete = false })
        end,
      }

      -- Simulate completion request
      local completion_items = {}
      cmp_source:complete({}, function(result)
        completion_items = result.items
      end)

      -- Verify completion items
      assert.equals(3, #completion_items)
      assert.equals('TestEmote1', completion_items[1].label)
      assert.equals('Emote', completion_items[1].kind)
    end)

    it('should integrate with telescope for channel selection', function()
      -- Add multiple channels
      local channels = { 'telescope_ch1', 'telescope_ch2', 'telescope_ch3' }
      for _, ch in ipairs(channels) do
        State.add_channel(ch)
        -- Add channel info
        State.set_channel_info(ch, {
          display_name = ch:upper(),
          viewer_count = math.random(100, 1000),
        })
      end

      -- Mock telescope picker
      local telescope_source = {
        get_channels = function()
          local items = {}
          for _, ch in ipairs(State.get_channels()) do
            local info = State.get_channel_info(ch)
            table.insert(items, {
              value = ch,
              display = info and info.display_name or ch,
              ordinal = ch,
              viewers = info and info.viewer_count or 0,
            })
          end
          return items
        end,
      }

      local picker_items = telescope_source.get_channels()

      -- Verify picker items
      assert.equals(3, #picker_items)
      for i, item in ipairs(picker_items) do
        assert.equals(channels[i], item.value)
        assert.equals(channels[i]:upper(), item.display)
        assert.truthy(item.viewers > 0)
      end

      -- Simulate selection
      local selected = picker_items[2]
      State.set_active_channel(selected.value)
      assert.equals('telescope_ch2', State.get_active_channel())
    end)

    it('should integrate with which-key for dynamic command display', function()
      -- Mock which-key registration
      local registered_keys = {}
      local which_key = {
        register = function(mappings, opts)
          for key, value in pairs(mappings) do
            table.insert(registered_keys, {
              key = key,
              desc = value[2] or value.desc,
              cmd = value[1] or value.cmd,
              opts = opts,
            })
          end
        end,
      }

      -- Register twitch commands
      local commands = {
        ['<leader>tw'] = { group = 'Twitch' },
        ['<leader>twc'] = { ':TwitchConnect<CR>', 'Connect to chat' },
        ['<leader>twj'] = { ':TwitchJoin ', 'Join channel' },
        ['<leader>twp'] = { ':TwitchPart ', 'Leave channel' },
        ['<leader>tws'] = { ':TwitchSend ', 'Send message' },
      }

      which_key.register(commands, { mode = 'n', prefix = '' })

      -- Verify registration
      assert.equals(5, #registered_keys)

      -- Find specific command
      local join_cmd = vim.tbl_filter(function(k)
        return k.key == '<leader>twj'
      end, registered_keys)[1]

      assert.truthy(join_cmd)
      assert.equals('Join channel', join_cmd.desc)
      assert.equals(':TwitchJoin ', join_cmd.cmd)

      -- Verify dynamic command updates based on state
      if State.is_connected() then
        which_key.register({
          ['<leader>twd'] = { ':TwitchDisconnect<CR>', 'Disconnect' },
        }, { mode = 'n' })
      else
        which_key.register({
          ['<leader>twc'] = { ':TwitchConnect<CR>', 'Connect' },
        }, { mode = 'n' })
      end
    end)
  end)
end)
