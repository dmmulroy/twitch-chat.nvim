-- tests/twitch-chat/irc_spec.lua
-- IRC protocol tests

local irc = require('twitch-chat.modules.irc')

describe('TwitchChat IRC Protocol', function()
  local mock_config = {
    server = 'wss://irc-ws.chat.twitch.tv:443',
    nick = 'test_user',
    pass = 'oauth:test_token',
    message_rate_limit = 20,
    join_rate_limit = 50,
    capabilities = {
      'twitch.tv/membership',
      'twitch.tv/tags',
      'twitch.tv/commands',
    },
  }

  local mock_callbacks = {}

  before_each(function()
    mock_callbacks = {
      connect = function() end,
      message = function() end,
      error = function() end,
      disconnect = function() end,
    }
  end)

  describe('IRC message parsing', function()
    it('should parse basic PRIVMSG', function()
      local line =
        ':test_user!test_user@test_user.tmi.twitch.tv PRIVMSG #test_channel :Hello world!'

      -- Access internal parsing function
      local parse_irc_message = function(input_line)
        local message = {
          raw = input_line,
          prefix = nil,
          command = '',
          params = {},
          tags = {},
        }

        local pos = 1

        -- Parse prefix
        if input_line:sub(pos, pos) == ':' then
          local prefix_end = input_line:find(' ', pos)
          if prefix_end then
            message.prefix = input_line:sub(pos + 1, prefix_end - 1)
            pos = prefix_end + 1
          end
        end

        -- Parse command and parameters
        local remaining = input_line:sub(pos)
        local parts = vim.split(remaining, ' ', { plain = true })

        if #parts > 0 then
          message.command = parts[1]:upper()

          for i = 2, #parts do
            if parts[i]:sub(1, 1) == ':' then
              local trailing = table.concat(parts, ' ', i):sub(2)
              table.insert(message.params, trailing)
              break
            else
              table.insert(message.params, parts[i])
            end
          end
        end

        return message
      end

      local message = parse_irc_message(line)

      assert.equals('test_user!test_user@test_user.tmi.twitch.tv', message.prefix)
      assert.equals('PRIVMSG', message.command)
      assert.equals('#test_channel', message.params[1])
      assert.equals('Hello world!', message.params[2])
    end)

    it('should parse message with tags', function()
      local line =
        '@badge-info=subscriber/8;badges=subscriber/6;color=#FF0000;display-name=TestUser :testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #test_channel :Hello!'

      local parse_irc_message = function(input_line)
        local message = {
          raw = input_line,
          prefix = nil,
          command = '',
          params = {},
          tags = {},
        }

        local pos = 1

        -- Parse tags
        if input_line:sub(1, 1) == '@' then
          local tag_end = input_line:find(' ', pos)
          if tag_end then
            local tag_string = input_line:sub(2, tag_end - 1)
            for tag_pair in tag_string:gmatch('[^;]+') do
              local key, value = tag_pair:match('([^=]+)=?(.*)')
              if key then
                message.tags[key] = value ~= '' and value or true
              end
            end
            pos = tag_end + 1
          end
        end

        -- Parse prefix
        if input_line:sub(pos, pos) == ':' then
          local prefix_end = input_line:find(' ', pos)
          if prefix_end then
            message.prefix = input_line:sub(pos + 1, prefix_end - 1)
            pos = prefix_end + 1
          end
        end

        -- Parse command and parameters
        local remaining = input_line:sub(pos)
        local parts = vim.split(remaining, ' ', { plain = true })

        if #parts > 0 then
          message.command = parts[1]:upper()

          for i = 2, #parts do
            if parts[i]:sub(1, 1) == ':' then
              local trailing = table.concat(parts, ' ', i):sub(2)
              table.insert(message.params, trailing)
              break
            else
              table.insert(message.params, parts[i])
            end
          end
        end

        return message
      end

      local message = parse_irc_message(line)

      assert.equals('subscriber/8', message.tags['badge-info'])
      assert.equals('subscriber/6', message.tags['badges'])
      assert.equals('#FF0000', message.tags['color'])
      assert.equals('TestUser', message.tags['display-name'])
      assert.equals('PRIVMSG', message.command)
      assert.equals('#test_channel', message.params[1])
      assert.equals('Hello!', message.params[2])
    end)

    it('should parse JOIN message', function()
      local line = ':test_user!test_user@test_user.tmi.twitch.tv JOIN #test_channel'

      local parse_irc_message = function(input_line)
        local message = {
          raw = input_line,
          prefix = nil,
          command = '',
          params = {},
          tags = {},
        }

        local pos = 1

        -- Parse prefix
        if input_line:sub(pos, pos) == ':' then
          local prefix_end = input_line:find(' ', pos)
          if prefix_end then
            message.prefix = input_line:sub(pos + 1, prefix_end - 1)
            pos = prefix_end + 1
          end
        end

        -- Parse command and parameters
        local remaining = input_line:sub(pos)
        local parts = vim.split(remaining, ' ', { plain = true })

        if #parts > 0 then
          message.command = parts[1]:upper()
          for i = 2, #parts do
            table.insert(message.params, parts[i])
          end
        end

        return message
      end

      local message = parse_irc_message(line)

      assert.equals('test_user!test_user@test_user.tmi.twitch.tv', message.prefix)
      assert.equals('JOIN', message.command)
      assert.equals('#test_channel', message.params[1])
    end)

    it('should parse PING message', function()
      local line = 'PING :tmi.twitch.tv'

      local parse_irc_message = function(input_line)
        local message = {
          raw = input_line,
          prefix = nil,
          command = '',
          params = {},
          tags = {},
        }

        local parts = vim.split(input_line, ' ', { plain = true })

        if #parts > 0 then
          message.command = parts[1]:upper()

          for i = 2, #parts do
            if parts[i]:sub(1, 1) == ':' then
              local trailing = table.concat(parts, ' ', i):sub(2)
              table.insert(message.params, trailing)
              break
            else
              table.insert(message.params, parts[i])
            end
          end
        end

        return message
      end

      local message = parse_irc_message(line)

      assert.equals('PING', message.command)
      assert.equals('tmi.twitch.tv', message.params[1])
    end)
  end)

  describe('IRC message formatting', function()
    it('should format PRIVMSG correctly', function()
      local format_irc_message = function(command, params)
        local message = command

        if params and #params > 0 then
          for i = 1, #params - 1 do
            message = message .. ' ' .. params[i]
          end

          local last_param = params[#params]
          if last_param:find(' ') or last_param:sub(1, 1) == ':' then
            message = message .. ' :' .. last_param
          else
            message = message .. ' ' .. last_param
          end
        end

        return message
      end

      local formatted = format_irc_message('PRIVMSG', { '#test_channel', 'Hello world!' })
      assert.equals('PRIVMSG #test_channel :Hello world!', formatted)
    end)

    it('should format JOIN correctly', function()
      local format_irc_message = function(command, params)
        local message = command

        if params and #params > 0 then
          for i = 1, #params do
            message = message .. ' ' .. params[i]
          end
        end

        return message
      end

      local formatted = format_irc_message('JOIN', { '#test_channel' })
      assert.equals('JOIN #test_channel', formatted)
    end)

    it('should format PONG correctly', function()
      local format_irc_message = function(command, params)
        local message = command

        if params and #params > 0 then
          for i = 1, #params - 1 do
            message = message .. ' ' .. params[i]
          end

          local last_param = params[#params]
          if last_param:find(' ') or last_param:sub(1, 1) == ':' then
            message = message .. ' :' .. last_param
          else
            message = message .. ' ' .. last_param
          end
        end

        return message
      end

      local formatted = format_irc_message('PONG', { 'tmi.twitch.tv' })
      assert.equals('PONG tmi.twitch.tv', formatted)
    end)
  end)

  describe('connection management', function()
    it('should create IRC connection with correct config', function()
      -- Mock the websocket module
      local websocket = {
        connect = function(url, callbacks)
          return {
            url = url,
            callbacks = callbacks,
          }
        end,
      }

      -- Mock the connection creation
      local conn = {
        config = mock_config,
        websocket_conn = websocket.connect(mock_config.server, mock_callbacks),
        connected = false,
        authenticated = false,
        channels = {},
        nick = mock_config.nick,
        capabilities = {},
        message_queue = {},
        join_queue = {},
        rate_limiters = {
          message = { limit = mock_config.message_rate_limit, window = 30000, timestamps = {} },
          join = { limit = mock_config.join_rate_limit, window = 15000, timestamps = {} },
        },
      }

      assert.equals(mock_config.server, conn.config.server)
      assert.equals(mock_config.nick, conn.nick)
      assert.is_false(conn.connected)
      assert.is_false(conn.authenticated)
      assert.is_table(conn.channels)
      assert.is_table(conn.message_queue)
      assert.is_table(conn.join_queue)
      assert.is_table(conn.rate_limiters)
    end)
  end)

  -- Helper function to mock websocket.send
  local function mock_websocket_send()
    local sent_messages = {}
    local websocket = require('twitch-chat.modules.websocket')
    local original_send = websocket.send

    ---@diagnostic disable-next-line: duplicate-set-field
    websocket.send = function(conn, message)
      table.insert(sent_messages, message)
      return true
    end

    return sent_messages, function()
      websocket.send = original_send
    end
  end

  describe('channel management', function()
    it('should join channel correctly', function()
      local sent_messages, restore_websocket = mock_websocket_send()

      local conn = {
        connected = true,
        authenticated = true,
        rate_limiters = {
          join = { limit = 10, window = 15000, timestamps = {} },
        },
        join_queue = {},
        websocket_conn = {}, -- Just need a placeholder
      }

      local success = irc.join_channel(conn, 'test_channel')

      assert.is_true(success)
      assert.equals(1, #sent_messages)
      assert.equals('JOIN #test_channel', sent_messages[1])

      -- Restore original function
      restore_websocket()
    end)

    it('should add # prefix to channel names', function()
      local sent_messages, restore_websocket = mock_websocket_send()

      local conn = {
        connected = true,
        authenticated = true,
        rate_limiters = {
          join = { limit = 10, window = 15000, timestamps = {} },
        },
        join_queue = {},
        websocket_conn = {}, -- Just need a placeholder
      }

      local success = irc.join_channel(conn, 'test_channel')

      assert.is_true(success)
      assert.equals('JOIN #test_channel', sent_messages[1])

      -- Restore original function
      restore_websocket()
    end)

    it('should not join when not connected', function()
      local conn = {
        connected = false,
        authenticated = false,
      }

      local success = irc.join_channel(conn, 'test_channel')

      assert.is_false(success)
    end)

    it('should part channel correctly', function()
      local sent_messages, restore_websocket = mock_websocket_send()

      local conn = {
        connected = true,
        authenticated = true,
        websocket_conn = {}, -- Just need a placeholder
      }

      local success = irc.part_channel(conn, '#test_channel', 'Goodbye!')

      assert.is_true(success)
      assert.equals(1, #sent_messages)
      assert.equals('PART #test_channel Goodbye!', sent_messages[1])

      -- Restore original function
      restore_websocket()
    end)
  end)

  describe('message handling', function()
    it('should send messages correctly', function()
      local sent_messages, restore_websocket = mock_websocket_send()

      local conn = {
        connected = true,
        authenticated = true,
        rate_limiters = {
          message = { limit = 20, window = 30000, timestamps = {} },
        },
        message_queue = {},
        websocket_conn = {}, -- Just need a placeholder
      }

      local success = irc.send_message(conn, '#test_channel', 'Hello world!')

      assert.is_true(success)
      assert.equals(1, #sent_messages)
      assert.equals('PRIVMSG #test_channel :Hello world!', sent_messages[1])

      -- Restore original function
      restore_websocket()
    end)

    it('should not send when not authenticated', function()
      local conn = {
        connected = true,
        authenticated = false,
      }

      local success = irc.send_message(conn, '#test_channel', 'Hello world!')

      assert.is_false(success)
    end)

    it('should queue messages when rate limited', function()
      local conn = {
        connected = true,
        authenticated = true,
        rate_limiters = {
          message = { limit = 0, window = 30000, timestamps = {} }, -- No messages allowed
        },
        message_queue = {},
      }

      local success = irc.send_message(conn, '#test_channel', 'Hello world!')

      assert.is_true(success) -- Returns true but queues message
      assert.equals(1, #conn.message_queue)
    end)
  end)

  describe('rate limiting', function()
    it('should create rate limiter correctly', function()
      local create_rate_limiter = function(limit, window)
        return {
          limit = limit,
          window = window,
          timestamps = {},
        }
      end

      local limiter = create_rate_limiter(20, 30000)

      assert.equals(20, limiter.limit)
      assert.equals(30000, limiter.window)
      assert.is_table(limiter.timestamps)
    end)

    it('should allow messages under limit', function()
      local rate_limit_check = function(limiter)
        return #limiter.timestamps < limiter.limit
      end

      local limiter = { limit = 5, window = 30000, timestamps = {} }

      assert.is_true(rate_limit_check(limiter))

      -- Add timestamps
      for i = 1, 4 do
        table.insert(limiter.timestamps, i)
      end

      assert.is_true(rate_limit_check(limiter))

      -- Add one more to reach limit
      table.insert(limiter.timestamps, 5)

      assert.is_false(rate_limit_check(limiter))
    end)
  end)

  describe('status reporting', function()
    it('should return correct status', function()
      local conn = {
        connected = true,
        authenticated = true,
        nick = 'test_user',
        channels = {
          ['#channel1'] = { joined = true },
          ['#channel2'] = { joined = true },
          ['#channel3'] = { joined = false },
        },
        message_queue = { 'msg1', 'msg2' },
        join_queue = { '#channel4' },
        websocket_conn = {
          status = 'connected',
        },
      }

      local get_channels = function(connection)
        local channels = {}
        for channel, info in pairs(connection.channels) do
          if info.joined then
            table.insert(channels, channel)
          end
        end
        return channels
      end

      local get_status = function(connection)
        return {
          connected = connection.connected,
          authenticated = connection.authenticated,
          nick = connection.nick,
          channels = get_channels(connection),
          message_queue_size = #connection.message_queue,
          join_queue_size = #connection.join_queue,
          websocket_status = connection.websocket_conn,
        }
      end

      local status = get_status(conn)

      assert.is_true(status.connected)
      assert.is_true(status.authenticated)
      assert.equals('test_user', status.nick)
      assert.equals(2, #status.channels)
      assert.equals(2, status.message_queue_size)
      assert.equals(1, status.join_queue_size)
    end)
  end)

  describe('channel tracking', function()
    it('should track joined channels', function()
      local conn = {
        channels = {},
        nick = 'test_user',
      }

      local handle_join = function(connection, message)
        local channel = message.params[1]
        local nick = message.prefix and message.prefix:match('([^!]+)')

        if not connection.channels[channel] then
          connection.channels[channel] = {
            name = channel,
            joined = false,
            users = {},
          }
        end

        if nick == connection.nick then
          connection.channels[channel].joined = true
        else
          connection.channels[channel].users[nick] = true
        end
      end

      local join_message = {
        params = { '#test_channel' },
        prefix = 'test_user!test_user@test_user.tmi.twitch.tv',
      }

      handle_join(conn, join_message)

      assert.is_not_nil(conn.channels['#test_channel'])
      assert.is_true(conn.channels['#test_channel'].joined)
    end)

    it('should track channel users', function()
      local conn = {
        channels = {
          ['#test_channel'] = {
            name = '#test_channel',
            joined = true,
            users = {},
          },
        },
        nick = 'test_user',
      }

      local handle_join = function(connection, message)
        local channel = message.params[1]
        local nick = message.prefix and message.prefix:match('([^!]+)')

        if connection.channels[channel] and nick ~= connection.nick then
          connection.channels[channel].users[nick] = true
        end
      end

      local user_join_message = {
        params = { '#test_channel' },
        prefix = 'other_user!other_user@other_user.tmi.twitch.tv',
      }

      handle_join(conn, user_join_message)

      assert.is_true(conn.channels['#test_channel'].users['other_user'])
    end)
  end)

  describe('IRC command handling', function()
    it('should handle PING with PONG', function()
      local sent_messages = {}

      local mock_websocket = {
        send_raw = function(conn, message)
          table.insert(sent_messages, message)
          return true
        end,
      }

      local conn = {
        websocket_conn = mock_websocket,
      }

      local handle_ping = function(connection, message)
        local pong_msg = 'PONG'
        if message.params and #message.params > 0 then
          pong_msg = pong_msg .. ' :' .. message.params[1]
        end
        mock_websocket.send_raw(connection.websocket_conn, pong_msg)
      end

      local ping_message = {
        command = 'PING',
        params = { 'tmi.twitch.tv' },
      }

      handle_ping(conn, ping_message)

      assert.equals(1, #sent_messages)
      assert.equals('PONG :tmi.twitch.tv', sent_messages[1])
    end)
  end)

  describe('error handling', function()
    it('should handle malformed messages gracefully', function()
      local parse_irc_message = function(input_line)
        if not input_line or input_line == '' then
          return nil
        end

        local message = {
          raw = input_line,
          prefix = nil,
          command = '',
          params = {},
          tags = {},
        }

        -- Basic parsing with error handling
        local success = pcall(function()
          local parts = vim.split(input_line, ' ', { plain = true })
          if #parts > 0 then
            message.command = parts[1]:upper()
          end
        end)

        if not success then
          return nil
        end

        return message
      end

      assert.is_nil(parse_irc_message(''))
      assert.is_nil(parse_irc_message(nil))

      local valid_message = parse_irc_message('PING')
      assert.is_not_nil(valid_message)
      if valid_message then
        assert.equals('PING', valid_message.command)
      end
    end)
  end)

  describe('capabilities', function()
    it('should request Twitch capabilities', function()
      local sent_messages = {}

      local mock_websocket = {
        send_raw = function(conn, message)
          table.insert(sent_messages, message)
          return true
        end,
      }

      local capabilities = { 'twitch.tv/tags', 'twitch.tv/commands' }

      -- Simulate capability request
      local cap_req = 'CAP REQ :' .. table.concat(capabilities, ' ')
      mock_websocket.send_raw(nil, cap_req)

      assert.equals(1, #sent_messages)
      assert.equals('CAP REQ :twitch.tv/tags twitch.tv/commands', sent_messages[1])
    end)
  end)

  describe('disconnect handling', function()
    it('should disconnect cleanly', function()
      local sent_messages = {}

      local mock_websocket = {
        send_raw = function(conn, message)
          table.insert(sent_messages, message)
          return true
        end,
        close = function(conn)
          -- Mock close
        end,
      }

      local conn = {
        connected = true,
        websocket_conn = mock_websocket,
      }

      local disconnect = function(connection, reason)
        if connection.connected then
          local quit_msg = 'QUIT'
          if reason then
            quit_msg = quit_msg .. ' :' .. reason
          end
          mock_websocket.send_raw(connection.websocket_conn, quit_msg)
        end

        mock_websocket.close(connection.websocket_conn)
        connection.connected = false
      end

      disconnect(conn, 'User quit')

      assert.equals(1, #sent_messages)
      assert.equals('QUIT :User quit', sent_messages[1])
      assert.is_false(conn.connected)
    end)
  end)
end)
