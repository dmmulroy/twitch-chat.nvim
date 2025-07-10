-- tests/twitch-chat/auth_spec.lua
-- Authentication module tests

local auth = require('twitch-chat.modules.auth')

describe('TwitchChat Authentication', function()
  local temp_token_file = '/tmp/test_twitch_token.json'

  before_each(function()
    -- Clean up any existing token file
    os.remove(temp_token_file)
  end)

  after_each(function()
    -- Clean up
    os.remove(temp_token_file)
    if auth.http_server then
      auth.http_server:close()
      auth.http_server = nil
    end
  end)

  describe('setup()', function()
    it('should initialize with valid configuration', function()
      local config = {
        client_id = 'test_client_id',
        redirect_uri = 'http://localhost:3000/callback',
        scopes = { 'chat:read', 'chat:edit' },
        token_file = temp_token_file,
      }

      assert.has_no.errors(function()
        auth.setup(config)
      end)

      assert.equals(config.client_id, auth.config.client_id)
      assert.equals(config.redirect_uri, auth.config.redirect_uri)
      assert.same(config.scopes, auth.config.scopes)
      assert.equals(config.token_file, auth.config.token_file)
    end)

    it('should error with missing client_id', function()
      local config = {
        client_id = '',
      }

      assert.has.errors(function()
        auth.setup(config)
      end)
    end)

    it('should load existing token on setup', function()
      -- Create a test token file
      local test_token = {
        access_token = 'test_access_token',
        refresh_token = 'test_refresh_token',
        token_type = 'Bearer',
        expires_in = 3600,
        scope = { 'chat:read', 'chat:edit' },
        expires_at = os.time() + 3600,
      }

      local file = io.open(temp_token_file, 'w')
      if file then
        file:write(vim.json.encode(test_token))
        file:close()
      end

      local config = {
        client_id = 'test_client_id',
        token_file = temp_token_file,
      }

      auth.setup(config)

      assert.is_not_nil(auth.current_token)
      assert.equals('test_access_token', auth.current_token.access_token)
    end)
  end)

  describe('generate_auth_url()', function()
    it('should generate valid OAuth URL', function()
      auth.setup({
        client_id = 'test_client_id',
        redirect_uri = 'http://localhost:3000/callback',
        scopes = { 'chat:read', 'chat:edit' },
      })

      local url = auth.generate_auth_url()

      assert.is_string(url)
      assert.matches('https://id.twitch.tv/oauth2/authorize', url, 1, true)
      assert.matches('client_id=test_client_id', url, 1, true)
      assert.matches('redirect_uri=http', url, 1, true)
      assert.matches('response_type=code', url, 1, true)
      assert.matches('scope=chat:read', url, 1, true)
      assert.matches('state=', url, 1, true)
    end)
  end)

  describe('generate_state()', function()
    it('should generate random state parameter', function()
      auth.setup({ client_id = 'test' })

      local state1 = auth.generate_state()
      local state2 = auth.generate_state()

      assert.is_string(state1)
      assert.is_string(state2)
      assert.equals(32, #state1)
      assert.equals(32, #state2)
      assert.is_not.equals(state1, state2)
    end)
  end)

  describe('build_query_string()', function()
    it('should build query string from parameters', function()
      auth.setup({ client_id = 'test' })

      local params = {
        client_id = 'test_id',
        redirect_uri = 'http://localhost:3000/callback',
        scope = 'chat:read chat:edit',
      }

      local query_string = auth.build_query_string(params)

      assert.is_string(query_string)
      assert.matches('client_id=test_id', query_string, 1, true)
      assert.matches('redirect_uri=http', query_string, 1, true)
      assert.matches('scope=chat', query_string, 1, true)
    end)

    it('should handle empty parameters', function()
      auth.setup({ client_id = 'test' })

      local query_string = auth.build_query_string({})
      assert.equals('', query_string)
    end)
  end)

  describe('create_token_from_response()', function()
    it('should create token from OAuth response', function()
      auth.setup({ client_id = 'test' })

      local response = {
        access_token = 'access_token_123',
        refresh_token = 'refresh_token_456',
        token_type = 'Bearer',
        expires_in = 3600,
        scope = 'chat:read chat:edit',
      }

      local token = auth.create_token_from_response(response)

      assert.equals('access_token_123', token.access_token)
      assert.equals('refresh_token_456', token.refresh_token)
      assert.equals('Bearer', token.token_type)
      assert.equals(3600, token.expires_in)
      assert.same({ 'chat:read', 'chat:edit' }, token.scope)
      assert.is_number(token.expires_at)
      assert.is_true(token.expires_at > os.time())
    end)

    it('should handle missing optional fields', function()
      auth.setup({ client_id = 'test' })

      local response = {
        access_token = 'access_token_123',
      }

      local token = auth.create_token_from_response(response)

      assert.equals('access_token_123', token.access_token)
      assert.is_nil(token.refresh_token)
      assert.equals('Bearer', token.token_type)
      assert.is_not_nil(token.expires_at)
    end)
  end)

  describe('save_token()', function()
    it('should save token to file', function()
      auth.setup({
        client_id = 'test',
        token_file = temp_token_file,
      })

      local token = {
        access_token = 'test_access_token',
        refresh_token = 'test_refresh_token',
        token_type = 'Bearer',
        expires_in = 3600,
        scope = { 'chat:read' },
        expires_at = os.time() + 3600,
      }

      assert.has_no.errors(function()
        auth.save_token(token)
      end)

      -- Check file exists
      local file = io.open(temp_token_file, 'r')
      assert.is_not_nil(file)

      if file then
        local content = file:read('*a')
        file:close()

        local decoded = vim.json.decode(content)
        assert.equals('test_access_token', decoded.access_token)
        assert.equals('test_refresh_token', decoded.refresh_token)
      end
    end)

    it('should create directory if it does not exist', function()
      local nested_token_file = '/tmp/nested/test_token.json'

      auth.setup({
        client_id = 'test',
        token_file = nested_token_file,
      })

      local token = {
        access_token = 'test_access_token',
        expires_at = os.time() + 3600,
      }

      assert.has_no.errors(function()
        auth.save_token(token)
      end)

      -- Check file exists
      local file = io.open(nested_token_file, 'r')
      assert.is_not_nil(file)
      if file then
        file:close()
      end

      -- Clean up
      os.remove(nested_token_file)
      os.remove('/tmp/nested')
    end)
  end)

  describe('load_token()', function()
    it('should load token from file', function()
      local token = {
        access_token = 'test_access_token',
        refresh_token = 'test_refresh_token',
        token_type = 'Bearer',
        expires_in = 3600,
        scope = { 'chat:read' },
        expires_at = os.time() + 3600,
      }

      local file = io.open(temp_token_file, 'w')
      if file then
        file:write(vim.json.encode(token))
        file:close()
      end

      auth.setup({
        client_id = 'test',
        token_file = temp_token_file,
      })

      local loaded_token = auth.load_token()

      assert.is_not_nil(loaded_token)
      if loaded_token then
        assert.equals('test_access_token', loaded_token.access_token)
      end
      assert.is_not_nil(loaded_token)
      if loaded_token then
        assert.equals('test_refresh_token', loaded_token.refresh_token)
      end
    end)

    it('should return nil for non-existent file', function()
      auth.setup({
        client_id = 'test',
        token_file = '/tmp/nonexistent_token.json',
      })

      local loaded_token = auth.load_token()
      assert.is_nil(loaded_token)
    end)

    it('should return nil for invalid JSON', function()
      local file = io.open(temp_token_file, 'w')
      if file then
        file:write('invalid json')
        file:close()
      end

      auth.setup({
        client_id = 'test',
        token_file = temp_token_file,
      })

      local loaded_token = auth.load_token()
      assert.is_nil(loaded_token)
    end)
  end)

  describe('get_access_token()', function()
    it('should return access token for valid token', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        expires_at = os.time() + 3600,
      }

      local access_token = auth.get_access_token()
      assert.equals('test_access_token', access_token)
    end)

    it('should return nil for expired token', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        expires_at = os.time() - 3600, -- Expired
      }

      local access_token = auth.get_access_token()
      assert.is_nil(access_token)
    end)

    it('should return nil when no token exists', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = nil

      local access_token = auth.get_access_token()
      assert.is_nil(access_token)
    end)
  end)

  describe('is_authenticated()', function()
    it('should return true for valid token', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        expires_at = os.time() + 3600,
      }

      assert.is_true(auth.is_authenticated())
    end)

    it('should return false for expired token', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        expires_at = os.time() - 3600,
      }

      assert.is_false(auth.is_authenticated())
    end)

    it('should return false when no token exists', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = nil

      assert.is_false(auth.is_authenticated())
    end)
  end)

  describe('clear_auth()', function()
    it('should clear current token', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        expires_at = os.time() + 3600,
      }

      auth.clear_auth()

      assert.is_nil(auth.current_token)
    end)

    it('should delete token file', function()
      auth.setup({
        client_id = 'test',
        token_file = temp_token_file,
      })

      -- Create token file
      local file = io.open(temp_token_file, 'w')
      if file then
        file:write('test')
        file:close()
      end

      auth.clear_auth()

      -- Check file is deleted
      local file_after = io.open(temp_token_file, 'r')
      assert.is_nil(file_after)
    end)
  end)

  describe('has_scopes()', function()
    it('should return true when token has all required scopes', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        scope = { 'chat:read', 'chat:edit', 'channel:read:subscriptions' },
        expires_at = os.time() + 3600,
      }

      assert.is_true(auth.has_scopes({ 'chat:read', 'chat:edit' }))
      assert.is_true(auth.has_scopes({ 'chat:read' }))
      assert.is_true(auth.has_scopes({ 'channel:read:subscriptions' }))
    end)

    it('should return false when token is missing required scopes', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = {
        access_token = 'test_access_token',
        scope = { 'chat:read' },
        expires_at = os.time() + 3600,
      }

      assert.is_false(auth.has_scopes({ 'chat:read', 'chat:edit' }))
      assert.is_false(auth.has_scopes({ 'channel:read:subscriptions' }))
    end)

    it('should return false when no token exists', function()
      auth.setup({ client_id = 'test' })

      auth.current_token = nil

      assert.is_false(auth.has_scopes({ 'chat:read' }))
    end)
  end)

  describe('cleanup()', function()
    it('should close HTTP server if running', function()
      auth.setup({ client_id = 'test' })

      -- Mock HTTP server
      local server_closed = false
      auth.http_server = {
        close = function()
          server_closed = true
        end,
      }

      auth.cleanup()

      assert.is_true(server_closed)
      assert.is_nil(auth.http_server)
    end)

    it('should handle no HTTP server gracefully', function()
      auth.setup({ client_id = 'test' })

      auth.http_server = nil

      assert.has_no.errors(function()
        auth.cleanup()
      end)
    end)
  end)

  describe('error handling', function()
    it('should handle file system errors gracefully', function()
      auth.setup({
        client_id = 'test',
        token_file = '/root/cannot_write_here.json', -- Should fail
      })

      local token = {
        access_token = 'test_access_token',
        expires_at = os.time() + 3600,
      }

      assert.has.errors(function()
        auth.save_token(token)
      end)
    end)
  end)

  describe('mocked OAuth flow', function()
    -- Mock the OAuth flow since we can't actually connect to Twitch in tests
    it('should handle successful OAuth callback', function()
      auth.setup({ client_id = 'test' })

      local callback_called = false
      local success_result = false

      -- Mock the exchange_code_for_token function
      local original_exchange = auth.exchange_code_for_token
      auth.exchange_code_for_token = function(code, callback)
        local mock_token = {
          access_token = 'mock_access_token',
          refresh_token = 'mock_refresh_token',
          token_type = 'Bearer',
          expires_in = 3600,
          scope = { 'chat:read', 'chat:edit' },
          expires_at = os.time() + 3600,
        }
        callback(true, mock_token)
      end

      -- Mock the start_callback_server function
      local original_start_server = auth.start_callback_server
      auth.start_callback_server = function(callback)
        -- Simulate successful OAuth flow
        vim.defer_fn(function()
          callback(true, {
            access_token = 'mock_access_token',
            refresh_token = 'mock_refresh_token',
            token_type = 'Bearer',
            expires_in = 3600,
            scope = { 'chat:read', 'chat:edit' },
            expires_at = os.time() + 3600,
          })
        end, 10)
      end

      -- Mock the open_browser function
      local original_open_browser = auth.open_browser
      auth.open_browser = function(url)
        -- Do nothing in tests
      end

      auth.start_oauth_flow(function(success, error)
        callback_called = true
        success_result = success
      end)

      -- Wait for callback
      vim.wait(100, function()
        return callback_called
      end)

      assert.is_true(callback_called)
      assert.is_true(success_result)

      -- Restore original functions
      auth.exchange_code_for_token = original_exchange
      auth.start_callback_server = original_start_server
      auth.open_browser = original_open_browser
    end)
  end)
end)
