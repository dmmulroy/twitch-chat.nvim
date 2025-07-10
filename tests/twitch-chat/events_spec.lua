-- tests/twitch-chat/events_spec.lua
-- Event system tests

local events = require('twitch-chat.events')

describe('TwitchChat Events', function()
  -- Reset event system before each test
  before_each(function()
    events.reset()
  end)

  -- Clean up after each test
  after_each(function()
    events.clear_all()
  end)

  describe('Event Registration', function()
    it('should register single event listener', function()
      local called = false
      local handler = function()
        called = true
      end

      events.on('test_event', handler)
      events.emit('test_event')

      assert.is_true(called)
    end)

    it('should register multiple listeners for same event', function()
      local call_count = 0
      local handler1 = function()
        call_count = call_count + 1
      end
      local handler2 = function()
        call_count = call_count + 1
      end

      events.on('test_event', handler1)
      events.on('test_event', handler2)
      events.emit('test_event')

      assert.equals(2, call_count)
    end)

    it('should handle different event names', function()
      local event1_called = false
      local event2_called = false

      events.on('event1', function()
        event1_called = true
      end)
      events.on('event2', function()
        event2_called = true
      end)

      events.emit('event1')
      assert.is_true(event1_called)
      assert.is_false(event2_called)

      events.emit('event2')
      assert.is_true(event2_called)
    end)

    it('should handle empty event names', function()
      local called = false
      events.on('', function()
        called = true
      end)
      events.emit('')
      assert.is_true(called)
    end)
  end)

  describe('Event Emission', function()
    it('should emit events with no data', function()
      local received_data = nil
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event')
      assert.is_nil(received_data)
    end)

    it('should emit events with string data', function()
      local received_data = nil
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', 'hello world')
      assert.equals('hello world', received_data)
    end)

    it('should emit events with table data', function()
      local received_data = nil
      local test_data = { message = 'hello', user = 'testuser' }
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', test_data)
      assert.same(test_data, received_data)
    end)

    it('should emit events with number data', function()
      local received_data = nil
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', 42)
      assert.equals(42, received_data)
    end)

    it('should emit events with boolean data', function()
      local received_data = nil
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', true)
      assert.is_true(received_data)
    end)

    it('should execute callback after emission', function()
      local callback_called = false
      local handler_called = false

      events.on('test_event', function()
        handler_called = true
      end)
      events.emit('test_event', nil, function()
        callback_called = true
      end)

      assert.is_true(handler_called)
      assert.is_true(callback_called)
    end)

    it('should execute callback even with no listeners', function()
      local callback_called = false
      events.emit('nonexistent_event', nil, function()
        callback_called = true
      end)
      assert.is_true(callback_called)
    end)
  end)

  describe('Event Constants', function()
    it('should have all required event constants defined', function()
      assert.equals('message_received', events.MESSAGE_RECEIVED)
      assert.equals('channel_joined', events.CHANNEL_JOINED)
      assert.equals('channel_left', events.CHANNEL_LEFT)
      assert.equals('connection_lost', events.CONNECTION_LOST)
      assert.equals('connection_established', events.CONNECTION_ESTABLISHED)
      assert.equals('send_message', events.SEND_MESSAGE)
      assert.equals('user_joined', events.USER_JOINED)
      assert.equals('user_left', events.USER_LEFT)
      assert.equals('error_occurred', events.ERROR_OCCURRED)
      assert.equals('config_changed', events.CONFIG_CHANGED)
      assert.equals('auth_success', events.AUTH_SUCCESS)
      assert.equals('auth_failed', events.AUTH_FAILED)
      assert.equals('error', events.ERROR)
      assert.equals('raw_message', events.RAW_MESSAGE)
      assert.equals('connection_opened', events.CONNECTION_OPENED)
      assert.equals('connection_error', events.CONNECTION_ERROR)
      assert.equals('connection_closed', events.CONNECTION_CLOSED)
      assert.equals('notice_received', events.NOTICE_RECEIVED)
      assert.equals('user_notice_received', events.USER_NOTICE_RECEIVED)
      assert.equals('room_state_changed', events.ROOM_STATE_CHANGED)
      assert.equals('user_state_changed', events.USER_STATE_CHANGED)
      assert.equals('chat_cleared', events.CHAT_CLEARED)
      assert.equals('message_deleted', events.MESSAGE_DELETED)
      assert.equals('authenticated', events.AUTHENTICATED)
      assert.equals('names_received', events.NAMES_RECEIVED)
    end)

    it('should have EVENTS namespace with all constants', function()
      assert.equals(events.MESSAGE_RECEIVED, events.EVENTS.MESSAGE_RECEIVED)
      assert.equals(events.CHANNEL_JOINED, events.EVENTS.CHANNEL_JOINED)
      assert.equals(events.CHANNEL_LEFT, events.EVENTS.CHANNEL_LEFT)
      assert.equals(events.CONNECTION_LOST, events.EVENTS.CONNECTION_LOST)
      assert.equals(events.CONNECTION_ESTABLISHED, events.EVENTS.CONNECTION_ESTABLISHED)
      assert.equals(events.SEND_MESSAGE, events.EVENTS.SEND_MESSAGE)
      assert.equals(events.USER_JOINED, events.EVENTS.USER_JOINED)
      assert.equals(events.USER_LEFT, events.EVENTS.USER_LEFT)
      assert.equals(events.ERROR_OCCURRED, events.EVENTS.ERROR_OCCURRED)
      assert.equals(events.CONFIG_CHANGED, events.EVENTS.CONFIG_CHANGED)
      assert.equals(events.AUTH_SUCCESS, events.EVENTS.AUTH_SUCCESS)
      assert.equals(events.AUTH_FAILED, events.EVENTS.AUTH_FAILED)
      assert.equals(events.ERROR, events.EVENTS.ERROR)
      assert.equals(events.RAW_MESSAGE, events.EVENTS.RAW_MESSAGE)
      assert.equals(events.CONNECTION_OPENED, events.EVENTS.CONNECTION_OPENED)
      assert.equals(events.CONNECTION_ERROR, events.EVENTS.CONNECTION_ERROR)
      assert.equals(events.CONNECTION_CLOSED, events.EVENTS.CONNECTION_CLOSED)
      assert.equals(events.NOTICE_RECEIVED, events.EVENTS.NOTICE_RECEIVED)
      assert.equals(events.USER_NOTICE_RECEIVED, events.EVENTS.USER_NOTICE_RECEIVED)
      assert.equals(events.ROOM_STATE_CHANGED, events.EVENTS.ROOM_STATE_CHANGED)
      assert.equals(events.USER_STATE_CHANGED, events.EVENTS.USER_STATE_CHANGED)
      assert.equals(events.CHAT_CLEARED, events.EVENTS.CHAT_CLEARED)
      assert.equals(events.MESSAGE_DELETED, events.EVENTS.MESSAGE_DELETED)
      assert.equals(events.AUTHENTICATED, events.EVENTS.AUTHENTICATED)
      assert.equals(events.NAMES_RECEIVED, events.EVENTS.NAMES_RECEIVED)
    end)
  end)

  describe('Event Listener Removal', function()
    it('should remove specific listener with off()', function()
      local handler1_called = false
      local handler2_called = false

      local handler1 = function()
        handler1_called = true
      end
      local handler2 = function()
        handler2_called = true
      end

      events.on('test_event', handler1)
      events.on('test_event', handler2)
      events.off('test_event', handler1)
      events.emit('test_event')

      assert.is_false(handler1_called)
      assert.is_true(handler2_called)
    end)

    it('should handle removing non-existent listener', function()
      local handler = function() end
      events.off('test_event', handler) -- Should not error
      assert.equals(0, events.get_handler_count('test_event'))
    end)

    it('should handle removing listener from non-existent event', function()
      local handler = function() end
      events.off('nonexistent_event', handler) -- Should not error
      assert.equals(0, events.get_handler_count('nonexistent_event'))
    end)

    it('should clear all listeners for event with clear()', function()
      local called_count = 0
      events.on('test_event', function()
        called_count = called_count + 1
      end)
      events.on('test_event', function()
        called_count = called_count + 1
      end)

      events.clear('test_event')
      events.emit('test_event')

      assert.equals(0, called_count)
    end)

    it('should clear all listeners for all events with clear_all()', function()
      local called_count = 0
      events.on('event1', function()
        called_count = called_count + 1
      end)
      events.on('event2', function()
        called_count = called_count + 1
      end)

      events.clear_all()
      events.emit('event1')
      events.emit('event2')

      assert.equals(0, called_count)
    end)
  end)

  describe('Multiple Listeners', function()
    it('should execute all listeners in order', function()
      local execution_order = {}

      events.on('test_event', function()
        table.insert(execution_order, 1)
      end)
      events.on('test_event', function()
        table.insert(execution_order, 2)
      end)
      events.on('test_event', function()
        table.insert(execution_order, 3)
      end)

      events.emit('test_event')

      assert.same({ 1, 2, 3 }, execution_order)
    end)

    it('should pass same data to all listeners', function()
      local received_data = {}
      local test_data = { message = 'test' }

      events.on('test_event', function(data)
        received_data[1] = data
      end)
      events.on('test_event', function(data)
        received_data[2] = data
      end)

      events.emit('test_event', test_data)

      assert.same(test_data, received_data[1])
      assert.same(test_data, received_data[2])
    end)
  end)

  describe('Event Namespacing', function()
    it('should create namespaced event emitter', function()
      local namespaced = events.create_namespace('test')
      local called = false

      namespaced.on('event', function()
        called = true
      end)
      namespaced.emit('event')

      assert.is_true(called)
    end)

    it('should isolate namespaced events', function()
      local ns1 = events.create_namespace('ns1')
      local ns2 = events.create_namespace('ns2')

      local ns1_called = false
      local ns2_called = false

      ns1.on('event', function()
        ns1_called = true
      end)
      ns2.on('event', function()
        ns2_called = true
      end)

      ns1.emit('event')
      assert.is_true(ns1_called)
      assert.is_false(ns2_called)

      ns2.emit('event')
      assert.is_true(ns2_called)
    end)

    it('should support namespaced listener removal', function()
      local namespaced = events.create_namespace('test')
      local called = false
      local handler = function()
        called = true
      end

      namespaced.on('event', handler)
      namespaced.off('event', handler)
      namespaced.emit('event')

      assert.is_false(called)
    end)

    it('should support namespaced event clearing', function()
      local namespaced = events.create_namespace('test')
      local called = false

      namespaced.on('event', function()
        called = true
      end)
      namespaced.clear('event')
      namespaced.emit('event')

      assert.is_false(called)
    end)
  end)

  describe('Error Handling', function()
    it('should handle listener errors gracefully', function()
      local error_handler_called = false
      local success_handler_called = false

      -- Mock vim.notify to capture error
      local original_notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level) -- luacheck: ignore
        if level == vim.log.levels.ERROR then
          error_handler_called = true
        end
      end

      events.on('test_event', function()
        error('test error')
      end)
      events.on('test_event', function()
        success_handler_called = true
      end)

      events.emit('test_event')

      assert.is_true(error_handler_called)
      assert.is_true(success_handler_called)

      -- Restore original notify
      vim.notify = original_notify -- luacheck: ignore
    end)

    it('should continue processing listeners after error', function()
      local handlers_called = 0

      -- Mock vim.notify to suppress error output
      local original_notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function() end -- luacheck: ignore

      events.on('test_event', function()
        error('error in first handler')
      end)
      events.on('test_event', function()
        handlers_called = handlers_called + 1
      end)
      events.on('test_event', function()
        handlers_called = handlers_called + 1
      end)

      events.emit('test_event')

      assert.equals(2, handlers_called)

      -- Restore original notify
      vim.notify = original_notify -- luacheck: ignore
    end)
  end)

  describe('Event Data Validation', function()
    it('should handle nil data correctly', function()
      local received_data = 'not_nil'
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', nil)
      assert.is_nil(received_data)
    end)

    it('should handle complex nested data structures', function()
      local complex_data = {
        user = {
          name = 'testuser',
          badges = { 'moderator', 'subscriber' },
          settings = {
            color = '#FF0000',
            display_name = 'TestUser',
          },
        },
        message = {
          text = 'Hello world!',
          timestamp = os.time(),
          emotes = {
            { name = 'Kappa', id = '25', positions = { { 0, 4 } } },
          },
        },
      }

      local received_data = nil
      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', complex_data)

      assert.same(complex_data, received_data)
    end)

    it('should handle function data', function()
      local test_function = function()
        return 'test'
      end
      local received_data = nil

      events.on('test_event', function(data)
        received_data = data
      end)
      events.emit('test_event', test_function)

      assert.equals('function', type(received_data))
      if received_data then
        assert.equals('test', received_data())
      end
    end)
  end)

  describe('Async Event Handling', function()
    it('should handle synchronous callback execution', function()
      local handler_called = false
      local callback_called = false
      local execution_order = {}

      events.on('test_event', function()
        handler_called = true
        table.insert(execution_order, 'handler')
      end)

      events.emit('test_event', nil, function()
        callback_called = true
        table.insert(execution_order, 'callback')
      end)

      assert.is_true(handler_called)
      assert.is_true(callback_called)
      assert.same({ 'handler', 'callback' }, execution_order)
    end)
  end)

  describe('Performance Tests', function()
    it('should handle many listeners efficiently', function()
      local handler_count = 1000
      local execution_count = 0

      -- Register many listeners
      for i = 1, handler_count do
        events.on('performance_test', function()
          execution_count = execution_count + 1
        end)
      end

      -- Emit event and measure time
      local start_time = os.clock()
      events.emit('performance_test')
      local end_time = os.clock()

      assert.equals(handler_count, execution_count)
      assert.is_true(end_time - start_time < 0.1) -- Should complete within 100ms
    end)

    it('should handle many events efficiently', function()
      local event_count = 1000
      local total_executions = 0

      -- Register handler for each event
      for i = 1, event_count do
        events.on('event_' .. i, function()
          total_executions = total_executions + 1
        end)
      end

      -- Emit all events
      local start_time = os.clock()
      for i = 1, event_count do
        events.emit('event_' .. i)
      end
      local end_time = os.clock()

      assert.equals(event_count, total_executions)
      assert.is_true(end_time - start_time < 0.1) -- Should complete within 100ms
    end)
  end)

  describe('Memory Management', function()
    it('should properly clean up listeners', function()
      local handler = function() end

      events.on('test_event', handler)
      assert.equals(1, events.get_handler_count('test_event'))

      events.off('test_event', handler)
      assert.equals(0, events.get_handler_count('test_event'))
    end)

    it('should handle listener cleanup after clear_all', function()
      events.on('event1', function() end)
      events.on('event2', function() end)

      assert.equals(1, events.get_handler_count('event1'))
      assert.equals(1, events.get_handler_count('event2'))

      events.clear_all()

      assert.equals(0, events.get_handler_count('event1'))
      assert.equals(0, events.get_handler_count('event2'))
    end)
  end)

  describe('Integration Tests', function()
    it('should handle MESSAGE_RECEIVED event', function()
      local message_data = {
        user = 'testuser',
        message = 'Hello world!',
        channel = '#testchannel',
        timestamp = os.time(),
      }

      local received_message = nil
      events.on(events.MESSAGE_RECEIVED, function(data)
        received_message = data
      end)
      events.emit(events.MESSAGE_RECEIVED, message_data)

      assert.same(message_data, received_message)
    end)

    it('should handle CHANNEL_JOINED event', function()
      local channel_data = { channel = '#testchannel' }
      local received_data = nil

      events.on(events.CHANNEL_JOINED, function(data)
        received_data = data
      end)
      events.emit(events.CHANNEL_JOINED, channel_data)

      assert.same(channel_data, received_data)
    end)

    it('should handle CONNECTION_ESTABLISHED event', function()
      local connection_called = false
      events.on(events.CONNECTION_ESTABLISHED, function()
        connection_called = true
      end)
      events.emit(events.CONNECTION_ESTABLISHED)
      assert.is_true(connection_called)
    end)

    it('should handle ERROR_OCCURRED event', function()
      local error_data = { error = 'Connection failed', code = 500 }
      local received_error = nil

      events.on(events.ERROR_OCCURRED, function(data)
        received_error = data
      end)
      events.emit(events.ERROR_OCCURRED, error_data)

      assert.same(error_data, received_error)
    end)

    it('should handle AUTH_SUCCESS event', function()
      local auth_data = { username = 'testuser', token = 'oauth:token' }
      local received_auth = nil

      events.on(events.AUTH_SUCCESS, function(data)
        received_auth = data
      end)
      events.emit(events.AUTH_SUCCESS, auth_data)

      assert.same(auth_data, received_auth)
    end)
  end)

  describe('Edge Cases', function()
    it('should handle invalid event names', function()
      -- Test with various invalid event names
      ---@diagnostic disable-next-line: param-type-mismatch
      events.on(nil, function()
        -- Handler for nil event
      end)
      ---@diagnostic disable-next-line: param-type-mismatch
      events.emit(nil)
      -- Should not crash, but won't execute handler

      ---@diagnostic disable-next-line: param-type-mismatch
      events.on(123, function()
        -- Handler for numeric event
      end)
      ---@diagnostic disable-next-line: param-type-mismatch
      events.emit(123)
      -- Should not crash
    end)

    it('should handle malformed listeners', function()
      -- Test with nil handler
      ---@diagnostic disable-next-line: param-type-mismatch
      events.on('test_event', nil)
      events.emit('test_event') -- Should not crash

      -- Test with non-function handler
      ---@diagnostic disable-next-line: param-type-mismatch
      events.on('test_event', 'not_a_function')
      events.emit('test_event') -- Should not crash
    end)

    it('should handle rapid event emission', function()
      local call_count = 0
      events.on('rapid_test', function()
        call_count = call_count + 1
      end)

      -- Emit many events rapidly
      for i = 1, 100 do
        events.emit('rapid_test')
      end

      assert.equals(100, call_count)
    end)

    it('should handle event emission during handler execution', function()
      local outer_called = false
      local inner_called = false

      events.on('outer_event', function()
        outer_called = true
        events.emit('inner_event')
      end)

      events.on('inner_event', function()
        inner_called = true
      end)

      events.emit('outer_event')

      assert.is_true(outer_called)
      assert.is_true(inner_called)
    end)
  end)

  describe('Utility Functions', function()
    it('should get registered events with get_events()', function()
      events.on('event1', function() end)
      events.on('event2', function() end)

      local registered_events = events.get_events()
      table.sort(registered_events)

      assert.same({ 'event1', 'event2' }, registered_events)
    end)

    it('should get handler count with get_handler_count()', function()
      assert.equals(0, events.get_handler_count('test_event'))

      events.on('test_event', function() end)
      assert.equals(1, events.get_handler_count('test_event'))

      events.on('test_event', function() end)
      assert.equals(2, events.get_handler_count('test_event'))
    end)

    it('should handle setup() function', function()
      events.setup() -- Should not error
      -- Setup should initialize the event system
      assert.equals(0, #events.get_events())
    end)

    it('should handle reset() function', function()
      events.on('test_event', function() end)
      assert.equals(1, events.get_handler_count('test_event'))

      events.reset()
      assert.equals(0, events.get_handler_count('test_event'))
    end)
  end)
end)
