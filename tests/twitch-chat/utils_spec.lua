-- tests/twitch-chat/utils_spec.lua
-- Comprehensive tests for utility functions

local utils = require('twitch-chat.utils')

describe('TwitchChat Utils', function()
  describe('deep_merge()', function()
    it('should merge two simple tables', function()
      local target = { a = 1, b = 2 }
      local source = { c = 3, d = 4 }
      local result = utils.deep_merge(target, source)

      assert.equals(1, result.a)
      assert.equals(2, result.b)
      assert.equals(3, result.c)
      assert.equals(4, result.d)
    end)

    it('should merge nested tables', function()
      local target = {
        ui = { width = 80, height = 20 },
        auth = { client_id = 'test' },
      }
      local source = {
        ui = { border = 'rounded' },
        chat = { channel = 'test' },
      }
      local result = utils.deep_merge(target, source)

      assert.equals(80, result.ui.width)
      assert.equals(20, result.ui.height)
      assert.equals('rounded', result.ui.border)
      assert.equals('test', result.auth.client_id)
      assert.equals('test', result.chat.channel)
    end)

    it('should override values with source values', function()
      local target = { a = 1, b = { x = 10, y = 20 } }
      local source = { a = 2, b = { y = 30, z = 40 } }
      local result = utils.deep_merge(target, source)

      assert.equals(2, result.a)
      assert.equals(10, result.b.x)
      assert.equals(30, result.b.y)
      assert.equals(40, result.b.z)
    end)

    it('should not modify original tables', function()
      local target = { a = 1, b = { x = 10 } }
      local source = { a = 2, b = { y = 20 } }

      utils.deep_merge(target, source)

      assert.equals(1, target.a)
      assert.is_nil(target.b.y)
      assert.equals(2, source.a)
      assert.is_nil(source.b.x)
    end)

    it('should handle empty tables', function()
      local target = {}
      local source = { a = 1 }
      local result = utils.deep_merge(target, source)

      assert.equals(1, result.a)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.deep_merge('not_table', {})
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.deep_merge({}, 'not_table')
      end)
    end)
  end)

  describe('safe_call()', function()
    it('should call function successfully', function()
      local function test_func(a, b)
        return a + b
      end

      local success, result = utils.safe_call(test_func, 5, 3)

      assert.is_true(success)
      assert.equals(8, result)
    end)

    it('should handle function errors gracefully', function()
      local function error_func()
        error('test error')
      end

      local success, result = utils.safe_call(error_func)

      assert.is_false(success)
      assert.is_string(result)
    end)

    it('should pass arguments correctly', function()
      local function multi_arg_func(a, b, c)
        return a .. b .. c
      end

      local success, result = utils.safe_call(multi_arg_func, 'hello', ' ', 'world')

      assert.is_true(success)
      assert.equals('hello world', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.safe_call('not_function')
      end)
    end)
  end)

  describe('format_timestamp()', function()
    it('should format timestamp with default format', function()
      local timestamp = 1609459200 -- 2021-01-01 00:00:00 UTC
      local result = utils.format_timestamp(timestamp)

      assert.is_string(result)
      assert.matches('%d%d:%d%d:%d%d', result)
    end)

    it('should format timestamp with custom format', function()
      local timestamp = 1609459200
      local result = utils.format_timestamp(timestamp, '%Y-%m-%d')

      assert.is_string(result)
      assert.matches('%d%d%d%d%-%d%d%-%d%d', result)
    end)

    it('should handle current time', function()
      local now = os.time()
      local result = utils.format_timestamp(now)

      assert.is_string(result)
      assert.matches('%d%d:%d%d:%d%d', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.format_timestamp('not_number')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.format_timestamp(123456789, 123)
      end)
    end)
  end)

  describe('escape_text()', function()
    it('should escape control characters', function()
      local text = 'hello\nworld\t!'
      local result = utils.escape_text(text)

      assert.is_string(result)
      assert.matches('hello\\010world\\009!', result)
    end)

    it('should handle normal text', function()
      local text = 'hello world'
      local result = utils.escape_text(text)

      assert.equals('hello world', result)
    end)

    it('should escape high-ASCII characters', function()
      local text = 'café' -- Contains non-ASCII character
      local result = utils.escape_text(text)

      assert.is_string(result)
      -- Should contain escaped sequences for non-ASCII chars
    end)

    it('should handle empty string', function()
      local result = utils.escape_text('')
      assert.equals('', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.escape_text(123)
      end)
    end)
  end)

  describe('strip_ansi()', function()
    it('should remove ANSI color codes', function()
      local text = '\027[31mred text\027[0m'
      local result = utils.strip_ansi(text)

      assert.equals('red text', result)
    end)

    it('should remove multiple ANSI codes', function()
      local text = '\027[1m\027[31mbold red\027[0m\027[32mgreen\027[0m'
      local result = utils.strip_ansi(text)

      assert.equals('bold redgreen', result)
    end)

    it('should handle text without ANSI codes', function()
      local text = 'plain text'
      local result = utils.strip_ansi(text)

      assert.equals('plain text', result)
    end)

    it('should handle empty string', function()
      local result = utils.strip_ansi('')
      assert.equals('', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.strip_ansi(123)
      end)
    end)
  end)

  describe('truncate()', function()
    it('should truncate long text', function()
      local text = 'this is a very long string that should be truncated'
      local result = utils.truncate(text, 20)

      assert.equals(20, #result)
      assert.matches('%.%.%.$', result)
    end)

    it('should not truncate short text', function()
      local text = 'short'
      local result = utils.truncate(text, 20)

      assert.equals('short', result)
    end)

    it('should use custom suffix', function()
      local text = 'long text here'
      local result = utils.truncate(text, 8, '...')

      assert.equals(8, #result)
      assert.matches('%.%.%.$', result)
    end)

    it('should handle edge cases', function()
      -- Text exactly at limit
      local text = 'exactly'
      local result = utils.truncate(text, 7)
      assert.equals('exactly', result)

      -- Suffix longer than limit
      local result2 = utils.truncate('hello', 3, '...')
      assert.equals('...', result2)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.truncate(123, 10)
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.truncate('text', 'not_number')
      end)
    end)
  end)

  describe('split()', function()
    it('should split string by delimiter', function()
      local text = 'a,b,c,d'
      local result = utils.split(text, ',')

      assert.equals(4, #result)
      assert.equals('a', result[1])
      assert.equals('b', result[2])
      assert.equals('c', result[3])
      assert.equals('d', result[4])
    end)

    it('should handle different delimiters', function()
      local text = 'hello world test'
      local result = utils.split(text, ' ')

      assert.equals(3, #result)
      assert.equals('hello', result[1])
      assert.equals('world', result[2])
      assert.equals('test', result[3])
    end)

    it('should handle empty parts', function()
      local text = 'a,,b'
      local result = utils.split(text, ',')

      assert.equals(2, #result)
      assert.equals('a', result[1])
      assert.equals('b', result[2])
    end)

    it('should handle single character', function()
      local text = 'a'
      local result = utils.split(text, ',')

      assert.equals(1, #result)
      assert.equals('a', result[1])
    end)

    it('should handle empty string', function()
      local result = utils.split('', ',')
      assert.equals(0, #result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.split(123, ',')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.split('text', 123)
      end)
    end)
  end)

  describe('join()', function()
    it('should join array with delimiter', function()
      local tbl = { 'a', 'b', 'c' }
      local result = utils.join(tbl, ',')

      assert.equals('a,b,c', result)
    end)

    it('should handle different delimiters', function()
      local tbl = { 'hello', 'world' }
      local result = utils.join(tbl, ' ')

      assert.equals('hello world', result)
    end)

    it('should handle single element', function()
      local tbl = { 'single' }
      local result = utils.join(tbl, ',')

      assert.equals('single', result)
    end)

    it('should handle empty table', function()
      local tbl = {}
      local result = utils.join(tbl, ',')

      assert.equals('', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.join('not_table', ',')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.join({}, 123)
      end)
    end)
  end)

  describe('is_empty()', function()
    it('should return true for empty table', function()
      assert.is_true(utils.is_empty({}))
    end)

    it('should return false for non-empty table', function()
      assert.is_false(utils.is_empty({ a = 1 }))
      assert.is_false(utils.is_empty({ 'a' }))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.is_empty('not_table')
      end)
    end)
  end)

  describe('table_length()', function()
    it('should count array elements', function()
      local tbl = { 'a', 'b', 'c' }
      assert.equals(3, utils.table_length(tbl))
    end)

    it('should count map elements', function()
      local tbl = { a = 1, b = 2, c = 3 }
      assert.equals(3, utils.table_length(tbl))
    end)

    it('should count mixed table', function()
      local tbl = { 'a', 'b', x = 1, y = 2 }
      assert.equals(4, utils.table_length(tbl))
    end)

    it('should return 0 for empty table', function()
      assert.equals(0, utils.table_length({}))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.table_length('not_table')
      end)
    end)
  end)

  describe('table_contains()', function()
    it('should find existing value', function()
      local tbl = { 'a', 'b', 'c' }
      assert.is_true(utils.table_contains(tbl, 'b'))
    end)

    it('should not find non-existing value', function()
      local tbl = { 'a', 'b', 'c' }
      assert.is_false(utils.table_contains(tbl, 'd'))
    end)

    it('should work with map values', function()
      local tbl = { x = 1, y = 2, z = 3 }
      assert.is_true(utils.table_contains(tbl, 2))
      assert.is_false(utils.table_contains(tbl, 4))
    end)

    it('should handle different types', function()
      local tbl = { 1, 'two', true, nil }
      assert.is_true(utils.table_contains(tbl, 1))
      assert.is_true(utils.table_contains(tbl, 'two'))
      assert.is_true(utils.table_contains(tbl, true))
      assert.is_false(utils.table_contains(tbl, false))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.table_contains('not_table', 'value')
      end)
    end)
  end)

  describe('table_keys()', function()
    it('should get keys from array', function()
      local tbl = { 'a', 'b', 'c' }
      local keys = utils.table_keys(tbl)

      assert.equals(3, #keys)
      assert.is_true(utils.table_contains(keys, 1))
      assert.is_true(utils.table_contains(keys, 2))
      assert.is_true(utils.table_contains(keys, 3))
    end)

    it('should get keys from map', function()
      local tbl = { x = 1, y = 2, z = 3 }
      local keys = utils.table_keys(tbl)

      assert.equals(3, #keys)
      assert.is_true(utils.table_contains(keys, 'x'))
      assert.is_true(utils.table_contains(keys, 'y'))
      assert.is_true(utils.table_contains(keys, 'z'))
    end)

    it('should return empty array for empty table', function()
      local keys = utils.table_keys({})
      assert.equals(0, #keys)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.table_keys('not_table')
      end)
    end)
  end)

  describe('table_values()', function()
    it('should get values from array', function()
      local tbl = { 'a', 'b', 'c' }
      local values = utils.table_values(tbl)

      assert.equals(3, #values)
      assert.is_true(utils.table_contains(values, 'a'))
      assert.is_true(utils.table_contains(values, 'b'))
      assert.is_true(utils.table_contains(values, 'c'))
    end)

    it('should get values from map', function()
      local tbl = { x = 1, y = 2, z = 3 }
      local values = utils.table_values(tbl)

      assert.equals(3, #values)
      assert.is_true(utils.table_contains(values, 1))
      assert.is_true(utils.table_contains(values, 2))
      assert.is_true(utils.table_contains(values, 3))
    end)

    it('should return empty array for empty table', function()
      local values = utils.table_values({})
      assert.equals(0, #values)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.table_values('not_table')
      end)
    end)
  end)

  describe('is_valid_url()', function()
    it('should validate HTTP URLs', function()
      assert.is_true(utils.is_valid_url('http://example.com'))
      assert.is_true(utils.is_valid_url('http://example.com/path'))
      assert.is_true(utils.is_valid_url('http://example.com:8080'))
      assert.is_true(utils.is_valid_url('http://example.com/path?query=value'))
    end)

    it('should validate HTTPS URLs', function()
      assert.is_true(utils.is_valid_url('https://example.com'))
      assert.is_true(utils.is_valid_url('https://sub.example.com'))
      assert.is_true(utils.is_valid_url('https://example.com/path/to/resource'))
    end)

    it('should reject invalid URLs', function()
      assert.is_false(utils.is_valid_url('not_a_url'))
      assert.is_false(utils.is_valid_url('ftp://example.com'))
      assert.is_false(utils.is_valid_url('http://'))
      assert.is_false(utils.is_valid_url('https://'))
      assert.is_false(utils.is_valid_url(''))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.is_valid_url(123)
      end)
    end)
  end)

  describe('is_valid_channel()', function()
    it('should validate correct channel names', function()
      assert.is_true(utils.is_valid_channel('testchannel'))
      assert.is_true(utils.is_valid_channel('test_channel'))
      assert.is_true(utils.is_valid_channel('channel123'))
      assert.is_true(utils.is_valid_channel('user_name_123'))
    end)

    it('should handle channel names with # prefix', function()
      assert.is_true(utils.is_valid_channel('#testchannel'))
      assert.is_true(utils.is_valid_channel('#test_channel'))
    end)

    it('should reject invalid channel names', function()
      -- Too short
      assert.is_false(utils.is_valid_channel('abc'))
      assert.is_false(utils.is_valid_channel('#ab'))

      -- Too long
      assert.is_false(utils.is_valid_channel('a' .. string.rep('b', 25)))

      -- Invalid characters
      assert.is_false(utils.is_valid_channel('test-channel'))
      assert.is_false(utils.is_valid_channel('test.channel'))
      assert.is_false(utils.is_valid_channel('test channel'))
      assert.is_false(utils.is_valid_channel('test@channel'))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.is_valid_channel(123)
      end)
    end)
  end)

  describe('random_string()', function()
    it('should generate string of correct length', function()
      local result = utils.random_string(10)
      assert.equals(10, #result)
    end)

    it('should generate different strings', function()
      local str1 = utils.random_string(20)
      local str2 = utils.random_string(20)

      assert.is_not_equal(str1, str2)
    end)

    it('should use custom charset', function()
      local result = utils.random_string(10, '01')

      -- Should only contain 0 and 1
      assert.matches('^[01]+$', result)
    end)

    it('should handle single character charset', function()
      local result = utils.random_string(5, 'a')
      assert.equals('aaaaa', result)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.random_string('not_number')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.random_string(10, 123)
      end)
    end)
  end)

  describe('debounce()', function()
    it('should debounce function calls', function()
      local call_count = 0
      local function test_func()
        call_count = call_count + 1
      end

      local debounced = utils.debounce(test_func, 100)

      -- Call multiple times quickly
      debounced()
      debounced()
      debounced()

      -- Should not have called yet
      assert.equals(0, call_count)

      -- Wait for debounce delay
      vim.wait(150, function()
        return call_count > 0
      end)

      -- Should have called once
      assert.equals(1, call_count)
    end)

    it('should pass arguments correctly', function()
      local received_args = {}
      local function test_func(...)
        received_args = { ... }
      end

      local debounced = utils.debounce(test_func, 50)
      debounced('arg1', 'arg2', 123)

      vim.wait(100, function()
        return #received_args > 0
      end)

      assert.equals(3, #received_args)
      assert.equals('arg1', received_args[1])
      assert.equals('arg2', received_args[2])
      assert.equals(123, received_args[3])
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.debounce('not_function', 100)
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.debounce(function() end, 'not_number')
      end)
    end)
  end)

  describe('throttle()', function()
    it('should throttle function calls', function()
      local call_count = 0
      local function test_func()
        call_count = call_count + 1
      end

      local throttled = utils.throttle(test_func, 100)

      -- First call should execute immediately
      throttled()
      assert.equals(1, call_count)

      -- Subsequent calls should be throttled
      throttled()
      throttled()
      assert.equals(1, call_count)

      -- Wait for throttle delay
      vim.wait(150)

      -- Now another call should execute
      throttled()
      assert.equals(2, call_count)
    end)

    it('should pass arguments correctly', function()
      local received_args = {}
      local function test_func(...)
        received_args = { ... }
      end

      local throttled = utils.throttle(test_func, 50)
      throttled('arg1', 'arg2', 123)

      assert.equals(3, #received_args)
      assert.equals('arg1', received_args[1])
      assert.equals('arg2', received_args[2])
      assert.equals(123, received_args[3])
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.throttle('not_function', 100)
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.throttle(function() end, 'not_number')
      end)
    end)
  end)

  describe('create_cache()', function()
    it('should create cache with basic operations', function()
      local cache = utils.create_cache()

      -- Test set and get
      cache.set('key1', 'value1')
      assert.equals('value1', cache.get('key1'))

      -- Test non-existent key
      assert.is_nil(cache.get('nonexistent'))

      -- Test size
      assert.equals(1, cache.size())
    end)

    it('should respect max size', function()
      local cache = utils.create_cache(2)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      assert.equals(2, cache.size())

      -- Adding third item should evict first
      cache.set('key3', 'value3')
      assert.equals(2, cache.size())
      assert.is_nil(cache.get('key1'))
      assert.equals('value2', cache.get('key2'))
      assert.equals('value3', cache.get('key3'))
    end)

    it('should clear cache', function()
      local cache = utils.create_cache()

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      assert.equals(2, cache.size())

      cache.clear()
      assert.equals(0, cache.size())
      assert.is_nil(cache.get('key1'))
      assert.is_nil(cache.get('key2'))
    end)

    it('should update existing keys without growing', function()
      local cache = utils.create_cache(2)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      assert.equals(2, cache.size())

      -- Update existing key
      cache.set('key1', 'new_value1')
      assert.equals(2, cache.size())
      assert.equals('new_value1', cache.get('key1'))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.create_cache('not_number')
      end)
    end)
  end)

  describe('get_file_extension()', function()
    it('should extract file extension', function()
      assert.equals('txt', utils.get_file_extension('file.txt'))
      assert.equals('lua', utils.get_file_extension('script.lua'))
      assert.equals('json', utils.get_file_extension('data.json'))
    end)

    it('should handle files with multiple dots', function()
      assert.equals('gz', utils.get_file_extension('archive.tar.gz'))
      assert.equals('lua', utils.get_file_extension('my.config.lua'))
    end)

    it('should handle files without extension', function()
      assert.equals('', utils.get_file_extension('README'))
      assert.equals('', utils.get_file_extension('makefile'))
    end)

    it('should handle paths', function()
      assert.equals('txt', utils.get_file_extension('/path/to/file.txt'))
      assert.equals('lua', utils.get_file_extension('./relative/path.lua'))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.get_file_extension(123)
      end)
    end)
  end)

  describe('file_exists()', function()
    local test_file = '/tmp/test_twitch_utils.txt'

    before_each(function()
      -- Create test file
      local file = io.open(test_file, 'w')
      if file then
        file:write('test content')
        file:close()
      end
    end)

    after_each(function()
      -- Clean up
      os.remove(test_file)
    end)

    it('should return true for existing file', function()
      assert.is_true(utils.file_exists(test_file))
    end)

    it('should return false for non-existent file', function()
      assert.is_false(utils.file_exists('/tmp/nonexistent_file.txt'))
    end)

    it('should return false for directory', function()
      assert.is_false(utils.file_exists('/tmp'))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.file_exists(123)
      end)
    end)
  end)

  describe('dir_exists()', function()
    local test_dir = '/tmp/test_twitch_utils_dir'

    before_each(function()
      -- Create test directory
      vim.fn.mkdir(test_dir, 'p')
    end)

    after_each(function()
      -- Clean up
      vim.fn.delete(test_dir, 'rf')
    end)

    it('should return true for existing directory', function()
      assert.is_true(utils.dir_exists(test_dir))
    end)

    it('should return false for non-existent directory', function()
      assert.is_false(utils.dir_exists('/tmp/nonexistent_directory'))
    end)

    it('should return false for file', function()
      -- Create a file
      local file_path = test_dir .. '/test.txt'
      local file = io.open(file_path, 'w')
      if file then
        file:write('test')
        file:close()
      end

      assert.is_false(utils.dir_exists(file_path))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.dir_exists(123)
      end)
    end)
  end)

  describe('ensure_dir()', function()
    local test_dir = '/tmp/test_twitch_utils_ensure'

    after_each(function()
      -- Clean up
      vim.fn.delete(test_dir, 'rf')
    end)

    it('should create directory if it does not exist', function()
      assert.is_false(utils.dir_exists(test_dir))

      local success = utils.ensure_dir(test_dir)

      assert.is_true(success)
      assert.is_true(utils.dir_exists(test_dir))
    end)

    it('should return true for existing directory', function()
      vim.fn.mkdir(test_dir, 'p')

      local success = utils.ensure_dir(test_dir)

      assert.is_true(success)
      assert.is_true(utils.dir_exists(test_dir))
    end)

    it('should create nested directories', function()
      local nested_dir = test_dir .. '/nested/deep'

      local success = utils.ensure_dir(nested_dir)

      assert.is_true(success)
      assert.is_true(utils.dir_exists(nested_dir))
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.ensure_dir(123)
      end)
    end)
  end)

  describe('read_file()', function()
    local test_file = '/tmp/test_twitch_utils_read.txt'
    local test_content = 'Hello, World!\nSecond line\nThird line'

    before_each(function()
      -- Create test file
      local file = io.open(test_file, 'w')
      if file then
        file:write(test_content)
        file:close()
      end
    end)

    after_each(function()
      -- Clean up
      os.remove(test_file)
    end)

    it('should read file content', function()
      local content = utils.read_file(test_file)
      assert.equals(test_content, content)
    end)

    it('should return nil for non-existent file', function()
      local content = utils.read_file('/tmp/nonexistent_file.txt')
      assert.is_nil(content)
    end)

    it('should handle empty file', function()
      local empty_file = '/tmp/empty_file.txt'
      local file = io.open(empty_file, 'w')
      if file then
        file:close()
      end

      local content = utils.read_file(empty_file)
      assert.equals('', content)

      os.remove(empty_file)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.read_file(123)
      end)
    end)
  end)

  describe('write_file()', function()
    local test_file = '/tmp/test_twitch_utils_write.txt'
    local test_content = 'Test content\nWith multiple lines'

    after_each(function()
      -- Clean up
      os.remove(test_file)
    end)

    it('should write file content', function()
      local success = utils.write_file(test_file, test_content)

      assert.is_true(success)
      assert.is_true(utils.file_exists(test_file))

      -- Verify content
      local file = io.open(test_file, 'r')
      local content = ''
      if file then
        content = file:read('*a')
        file:close()
      end

      assert.equals(test_content, content)
    end)

    it('should create directories if needed', function()
      local nested_file = '/tmp/nested/deep/test.txt'

      local success = utils.write_file(nested_file, test_content)

      assert.is_true(success)
      assert.is_true(utils.file_exists(nested_file))

      -- Clean up
      vim.fn.delete('/tmp/nested', 'rf')
    end)

    it('should overwrite existing file', function()
      -- Create initial file
      utils.write_file(test_file, 'initial content')

      -- Overwrite
      local success = utils.write_file(test_file, test_content)

      assert.is_true(success)

      -- Verify new content
      local content = utils.read_file(test_file)
      assert.equals(test_content, content)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.write_file(123, 'content')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.write_file('/tmp/test.txt', 123)
      end)
    end)
  end)

  describe('log()', function()
    it('should log messages with timestamp', function()
      -- This test mainly checks that the function doesn't error
      -- Since vim.notify is used, we can't easily capture the output
      assert.has_no.errors(function()
        utils.log(vim.log.levels.INFO, 'Test message')
      end)
    end)

    it('should log messages with context', function()
      local context = { key = 'value', number = 42 }

      assert.has_no.errors(function()
        utils.log(vim.log.levels.DEBUG, 'Test message with context', context)
      end)
    end)

    it('should handle different log levels', function()
      assert.has_no.errors(function()
        utils.log(vim.log.levels.ERROR, 'Error message')
        utils.log(vim.log.levels.WARN, 'Warning message')
        utils.log(vim.log.levels.INFO, 'Info message')
        utils.log(vim.log.levels.DEBUG, 'Debug message')
      end)
    end)

    it('should validate input types', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.log('not_number', 'message')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.log(vim.log.levels.INFO, 123)
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.log(vim.log.levels.INFO, 'message', 'not_table')
      end)
    end)
  end)

  describe('edge cases and error handling', function()
    it('should handle nil inputs gracefully', function()
      -- Functions that should handle nil appropriately
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.deep_merge(nil, {})
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.split(nil, ',')
      end)

      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        utils.table_length(nil)
      end)
    end)

    it('should handle empty strings appropriately', function()
      assert.equals('', utils.escape_text(''))
      assert.equals('', utils.strip_ansi(''))
      assert.equals('', utils.truncate('', 10))
      assert.equals(0, #utils.split('', ','))
    end)

    it('should handle extreme numeric values', function()
      assert.equals('', utils.random_string(0))
      assert.equals('', utils.truncate('text', 0))

      -- Large numbers should work
      local large_string = utils.random_string(1000)
      assert.equals(1000, #large_string)
    end)

    it('should maintain immutability where expected', function()
      local original = { a = 1, b = { x = 10 } }
      local merged = utils.deep_merge(original, { c = 3 })

      -- Original should not be modified
      assert.equals(1, original.a)
      assert.is_nil(original.c)
      assert.equals(10, original.b.x)

      -- Merged should have new values
      assert.equals(1, merged.a)
      assert.equals(3, merged.c)
    end)
  end)
end)
