-- tests/twitch-chat/health_spec.lua
-- Comprehensive health checking system tests

local health = require('twitch-chat.health')
local config = require('twitch-chat.config')
local utils = require('twitch-chat.utils')

describe('TwitchChat Health Check System', function()
  local original_config
  local original_vim = {}
  local original_pcall

  before_each(function()
    -- Save original state
    original_config = config.export()
    original_pcall = _G.pcall

    -- Save vim functions
    original_vim.version = rawget(vim, 'version')
    original_vim.fn = {}
    original_vim.fn.executable = rawget(vim.fn, 'executable')
    original_vim.fn.system = rawget(vim.fn, 'system')
    original_vim.fn.json_decode = rawget(vim.fn, 'json_decode')
    original_vim.loop = {}
    original_vim.loop.fs_stat = rawget(vim.loop, 'fs_stat')
    original_vim.loop.now = rawget(vim.loop, 'now')
    original_vim.v = {}
    original_vim.v.shell_error = rawget(vim.v, 'shell_error')
    original_vim.health = rawget(vim, 'health')
    original_vim.api = {}
    original_vim.api.nvim_create_buf = rawget(vim.api, 'nvim_create_buf')
    original_vim.api.nvim_buf_set_lines = rawget(vim.api, 'nvim_buf_set_lines')
    original_vim.api.nvim_buf_set_option = rawget(vim.api, 'nvim_buf_set_option')
    original_vim.api.nvim_buf_set_name = rawget(vim.api, 'nvim_buf_set_name')
    original_vim.api.nvim_win_set_buf = rawget(vim.api, 'nvim_win_set_buf')
    original_vim.cmd = rawget(vim, 'cmd')

    -- Reset to clean state
    config.reset()
    config.setup()
  end)

  after_each(function()
    -- Restore original state
    config.import(original_config)
    _G.pcall = original_pcall

    -- Restore vim functions
    rawset(vim, 'version', original_vim.version)
    rawset(vim.fn, 'executable', original_vim.fn.executable)
    rawset(vim.fn, 'system', original_vim.fn.system)
    rawset(vim.fn, 'json_decode', original_vim.fn.json_decode)
    rawset(vim.loop, 'fs_stat', original_vim.loop.fs_stat)
    rawset(vim.loop, 'now', original_vim.loop.now)
    rawset(vim.v, 'shell_error', original_vim.v.shell_error)
    rawset(vim, 'health', original_vim.health)
    rawset(vim.api, 'nvim_create_buf', original_vim.api.nvim_create_buf)
    rawset(vim.api, 'nvim_buf_set_lines', original_vim.api.nvim_buf_set_lines)
    rawset(vim.api, 'nvim_buf_set_option', original_vim.api.nvim_buf_set_option)
    rawset(vim.api, 'nvim_buf_set_name', original_vim.api.nvim_buf_set_name)
    rawset(vim.api, 'nvim_win_set_buf', original_vim.api.nvim_win_set_buf)
    rawset(vim, 'cmd', original_vim.cmd)
  end)

  describe('setup()', function()
    it('should initialize health check system', function()
      assert.has_no.errors(function()
        health.setup()
      end)
    end)

    it('should not require any configuration', function()
      -- Should work without any setup
      assert.has_no.errors(function()
        health.setup()
      end)
    end)
  end)

  describe('Health Check Status Constants', function()
    it('should define proper status constants', function()
      assert.equals('ok', health.OK)
      assert.equals('warn', health.WARN)
      assert.equals('error', health.ERROR)
    end)
  end)

  describe('check_neovim_version()', function()
    it('should return OK for supported Neovim versions', function()
      rawset(vim, 'version', function()
        return { major = 0, minor = 9, patch = 0 }
      end)

      local result = health.check_neovim_version()
      assert.is_not_nil(result)
      if result then
        assert.equals(health.OK, result.status)
        assert.matches('supported', result.message)
        assert.is_nil(result.suggestion)
      end
    end)

    it('should return OK for newer versions', function()
      rawset(vim, 'version', function()
        return { major = 0, minor = 10, patch = 0 }
      end)

      local result = health.check_neovim_version()
      assert.is_not_nil(result)
      if result then
        assert.equals(health.OK, result.status)
        assert.matches('supported', result.message)
      end
    end)

    it('should return OK for major version 1+', function()
      rawset(vim, 'version', function()
        return { major = 1, minor = 0, patch = 0 }
      end)

      local result = health.check_neovim_version()
      assert.is_not_nil(result)
      if result then
        assert.equals(health.OK, result.status)
        assert.matches('supported', result.message)
      end
    end)

    it('should return ERROR for unsupported versions', function()
      rawset(vim, 'version', function()
        return { major = 0, minor = 8, patch = 0 }
      end)

      local result = health.check_neovim_version()
      assert.is_not_nil(result)
      if result then
        assert.equals(health.ERROR, result.status)
        assert.matches('not supported', result.message)
        assert.matches('upgrade', result.suggestion)
      end
    end)

    it('should return ERROR for very old versions', function()
      rawset(vim, 'version', function()
        return { major = 0, minor = 7, patch = 1 }
      end)

      local result = health.check_neovim_version()
      assert.is_not_nil(result)
      if result then
        assert.equals(health.ERROR, result.status)
        assert.matches('not supported', result.message)
        assert.matches('Please upgrade', result.suggestion)
      end
    end)
  end)

  describe('check_dependencies()', function()
    it('should return OK when all dependencies are available', function()
      -- Mock successful requires
      local original_require = require
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.require = function(module)
        if module == 'plenary.nvim' then
          return {}
        elseif
          module == 'telescope.nvim'
          or module == 'nvim-cmp'
          or module == 'which-key.nvim'
          or module == 'nvim-notify'
          or module == 'lualine.nvim'
        then
          return {}
        else
          return original_require(module)
        end
      end

      local result = health.check_dependencies()
      assert.equals(health.OK, result.status)
      assert.matches('All dependencies are available', result.message)
      assert.is_nil(result.suggestion)

      _G.require = original_require
    end)

    it('should return ERROR when required dependencies are missing', function()
      -- Mock failed require for plenary
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'plenary.nvim' then
          return false, 'module not found'
        end
        return original_pcall(func, module)
      end

      local result = health.check_dependencies()
      assert.equals(health.ERROR, result.status)
      assert.matches('Missing required dependencies', result.message)
      assert.matches('plenary.nvim', result.message)
      assert.matches('Install missing dependencies', result.suggestion)
    end)

    it('should return WARN when optional dependencies are missing', function()
      -- Mock successful require for required, failed for optional
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'plenary.nvim' then
          return true, {}
        elseif module == 'telescope.nvim' then
          return false, 'module not found'
        end
        return original_pcall(func, module)
      end

      local result = health.check_dependencies()
      assert.equals(health.WARN, result.status)
      assert.matches('Missing optional dependencies', result.message)
      assert.matches('telescope.nvim', result.message)
      assert.matches('Install optional dependencies', result.suggestion)
    end)

    it('should handle multiple missing dependencies', function()
      -- Mock failed requires for multiple modules
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'telescope.nvim' or module == 'nvim-cmp' then
          return false, 'module not found'
        elseif module == 'plenary.nvim' then
          return true, {}
        end
        return original_pcall(func, module)
      end

      local result = health.check_dependencies()
      assert.equals(health.WARN, result.status)
      assert.matches('Missing optional dependencies', result.message)
      assert.matches('telescope.nvim', result.message)
      assert.matches('nvim%-cmp', result.message)
    end)
  end)

  describe('check_configuration()', function()
    it('should return OK for valid configuration', function()
      config.setup({
        auth = {
          client_id = 'test_client_id',
          redirect_uri = 'http://localhost:3000/callback',
          scopes = { 'chat:read', 'chat:edit' },
          token_file = '/tmp/token.json',
          auto_refresh = true,
        },
        ui = {
          width = 80,
          height = 20,
          position = 'center',
          border = 'rounded',
        },
      })

      local result = health.check_configuration()
      assert.equals(health.OK, result.status)
      assert.matches('Configuration is valid', result.message)
      assert.is_nil(result.suggestion)
    end)

    it('should return ERROR when configuration is not initialized', function()
      config.options = nil

      local result = health.check_configuration()
      assert.equals(health.ERROR, result.status)
      assert.matches('Configuration is not initialized', result.message)
      assert.matches('setup', result.suggestion)
    end)

    it('should return ERROR when configuration is empty', function()
      config.options = {}

      local result = health.check_configuration()
      assert.equals(health.ERROR, result.status)
      assert.matches('Configuration is not initialized', result.message)
      assert.matches('setup', result.suggestion)
    end)

    it('should return ERROR when configuration validation fails', function()
      config.setup({
        ui = {
          position = 'invalid_position',
        },
      })

      local result = health.check_configuration()
      assert.equals(health.ERROR, result.status)
      assert.matches('Configuration validation failed', result.message)
      assert.matches('Check your configuration', result.suggestion)
    end)

    it('should return WARN when client ID is not set', function()
      config.setup({
        auth = {
          client_id = '',
        },
      })

      local result = health.check_configuration()
      assert.equals(health.WARN, result.status)
      assert.matches('client ID is not configured', result.message)
      assert.matches('Set auth.client_id', result.suggestion)
    end)

    it('should return WARN when client ID is missing', function()
      config.setup({
        auth = {},
      })

      local result = health.check_configuration()
      assert.equals(health.WARN, result.status)
      assert.matches('client ID is not configured', result.message)
      assert.matches('Set auth.client_id', result.suggestion)
    end)
  end)

  describe('check_authentication()', function()
    it('should return WARN when client ID is not configured', function()
      config.setup({
        auth = {
          client_id = '',
        },
      })

      local result = health.check_authentication()
      assert.equals(health.WARN, result.status)
      assert.matches('Authentication not configured', result.message)
      assert.matches('Set up Twitch client ID', result.suggestion)
    end)

    it('should return WARN when token file does not exist', function()
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = '/nonexistent/token.json',
        },
      })

      local result = health.check_authentication()
      assert.equals(health.WARN, result.status)
      assert.matches('No authentication token found', result.message)
      assert.matches('Run :TwitchAuth', result.suggestion)
    end)

    it('should return ERROR when token file cannot be read', function()
      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      -- Create file but mock read failure
      utils.write_file(temp_file, '{"access_token": "test"}')
      local original_read_file = utils.read_file
      utils.read_file = function()
        return nil
      end

      local result = health.check_authentication()
      assert.equals(health.ERROR, result.status)
      assert.matches('Cannot read authentication token file', result.message)
      assert.matches('Check file permissions', result.suggestion)

      utils.read_file = original_read_file
      os.remove(temp_file)
    end)

    it('should return ERROR when token file has invalid JSON', function()
      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      utils.write_file(temp_file, 'invalid json')

      local result = health.check_authentication()
      assert.equals(health.ERROR, result.status)
      assert.matches('Invalid token file format', result.message)
      assert.matches('Re%-authenticate', result.suggestion)

      os.remove(temp_file)
    end)

    it('should return WARN when token has expired', function()
      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      local expired_token = {
        access_token = 'test_token',
        expires_at = os.time() - 3600, -- Expired 1 hour ago
      }
      utils.write_file(temp_file, vim.fn.json_encode(expired_token))

      local result = health.check_authentication()
      assert.equals(health.WARN, result.status)
      assert.matches('token has expired', result.message)
      assert.matches('Re%-authenticate', result.suggestion)

      os.remove(temp_file)
    end)

    it('should return OK when token is valid', function()
      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      local valid_token = {
        access_token = 'test_token',
        expires_at = os.time() + 3600, -- Expires in 1 hour
      }
      utils.write_file(temp_file, vim.fn.json_encode(valid_token))

      local result = health.check_authentication()
      assert.equals(health.OK, result.status)
      assert.matches('Authentication is configured and valid', result.message)
      assert.is_nil(result.suggestion)

      os.remove(temp_file)
    end)

    it('should return OK when token has no expiry', function()
      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      local token = {
        access_token = 'test_token',
      }
      utils.write_file(temp_file, vim.fn.json_encode(token))

      local result = health.check_authentication()
      assert.equals(health.OK, result.status)
      assert.matches('Authentication is configured and valid', result.message)

      os.remove(temp_file)
    end)
  end)

  describe('check_network()', function()
    it('should return OK when network connectivity is available', function()
      rawset(vim.fn, 'system', function(cmd)
        if cmd:match('nslookup') then
          return 'success'
        elseif cmd:match('curl') then
          return '200'
        end
        return 'error'
      end)
      rawset(vim.v, 'shell_error', 0)
      rawset(vim.fn, 'executable', function(cmd)
        return cmd == 'curl' and 1 or 0
      end)

      local result = health.check_network()
      assert.equals(health.OK, result.status)
      assert.matches('Network connectivity to Twitch is available', result.message)
      assert.is_nil(result.suggestion)
    end)

    it('should return WARN when DNS resolution fails', function()
      rawset(vim.fn, 'system', function()
        return 'error'
      end)
      rawset(vim.v, 'shell_error', 1)

      local result = health.check_network()
      assert.equals(health.WARN, result.status)
      assert.matches('Cannot resolve Twitch IRC server', result.message)
      assert.matches('Check your internet connection', result.suggestion)
    end)

    it('should return WARN when curl is available but connection fails', function()
      rawset(vim.fn, 'system', function(cmd)
        if cmd:match('nslookup') then
          return 'success'
        elseif cmd:match('curl') then
          return '404'
        end
        return 'error'
      end)
      rawset(vim.v, 'shell_error', 0)
      rawset(vim.fn, 'executable', function(cmd)
        return cmd == 'curl' and 1 or 0
      end)

      local result = health.check_network()
      assert.equals(health.WARN, result.status)
      assert.matches('Cannot connect to Twitch servers', result.message)
      assert.matches('Check your internet connection', result.suggestion)
    end)

    it('should return OK when curl is not available but DNS works', function()
      rawset(vim.fn, 'system', function(cmd)
        if cmd:match('nslookup') then
          return 'success'
        end
        return 'error'
      end)
      rawset(vim.v, 'shell_error', 0)
      rawset(vim.fn, 'executable', function()
        return 0
      end)

      local result = health.check_network()
      assert.equals(health.OK, result.status)
      assert.matches('Basic network connectivity checks passed', result.message)
    end)

    it('should handle system call errors gracefully', function()
      rawset(vim.fn, 'system', function()
        error('System call failed')
      end)

      local result = health.check_network()
      assert.equals(health.WARN, result.status)
      assert.matches('Cannot resolve Twitch IRC server', result.message)
    end)
  end)

  describe('check_file_permissions()', function()
    it('should return OK when file permissions are correct', function()
      local temp_dir = '/tmp/test_twitch_chat'
      config.setup({
        auth = {
          token_file = temp_dir .. '/token.json',
        },
      })

      -- Clean up first
      os.execute('rm -rf ' .. temp_dir)

      local result = health.check_file_permissions()
      assert.equals(health.OK, result.status)
      assert.matches('File permissions are correct', result.message)
      assert.is_nil(result.suggestion)

      -- Clean up
      os.execute('rm -rf ' .. temp_dir)
    end)

    it('should return ERROR when directory cannot be created', function()
      config.setup({
        auth = {
          token_file = '/root/readonly/token.json',
        },
      })

      local original_ensure_dir = utils.ensure_dir
      utils.ensure_dir = function()
        return false
      end

      local result = health.check_file_permissions()
      assert.equals(health.ERROR, result.status)
      assert.matches('Cannot create token directory', result.message)
      assert.matches('Check file permissions', result.suggestion)

      utils.ensure_dir = original_ensure_dir
    end)

    it('should return ERROR when write permissions are insufficient', function()
      local temp_dir = '/tmp/test_twitch_chat'
      config.setup({
        auth = {
          token_file = temp_dir .. '/token.json',
        },
      })

      -- Create directory but mock write failure
      utils.ensure_dir(temp_dir)
      local original_write_file = utils.write_file
      utils.write_file = function()
        return false
      end

      local result = health.check_file_permissions()
      assert.equals(health.ERROR, result.status)
      assert.matches('No write permissions', result.message)
      assert.matches('Check file permissions', result.suggestion)

      utils.write_file = original_write_file
      os.execute('rm -rf ' .. temp_dir)
    end)

    it('should handle existing directories correctly', function()
      local temp_dir = '/tmp/test_twitch_chat'
      config.setup({
        auth = {
          token_file = temp_dir .. '/token.json',
        },
      })

      -- Create directory first
      utils.ensure_dir(temp_dir)

      local result = health.check_file_permissions()
      assert.equals(health.OK, result.status)
      assert.matches('File permissions are correct', result.message)

      os.execute('rm -rf ' .. temp_dir)
    end)
  end)

  describe('check_integrations()', function()
    it('should return OK when no integrations are enabled', function()
      config.setup({
        integrations = {
          telescope = false,
          cmp = false,
          which_key = false,
          notify = false,
          lualine = false,
        },
      })

      local result = health.check_integrations()
      assert.equals(health.OK, result.status)
      assert.matches('No integrations enabled', result.message)
      assert.is_nil(result.suggestion)
    end)

    it('should return OK when all enabled integrations are available', function()
      config.setup({
        integrations = {
          telescope = true,
          cmp = true,
          which_key = false,
          notify = false,
          lualine = false,
        },
      })

      -- Mock successful requires
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'telescope' or module == 'cmp' then
          return true, {}
        end
        return original_pcall(func, module)
      end

      local result = health.check_integrations()
      assert.equals(health.OK, result.status)
      assert.matches('Integration status:', result.message)
      assert.matches('telescope: available', result.message)
      assert.matches('nvim%-cmp: available', result.message)
      assert.is_nil(result.suggestion)
    end)

    it('should return WARN when enabled integrations are missing', function()
      config.setup({
        integrations = {
          telescope = true,
          cmp = true,
          which_key = false,
          notify = false,
          lualine = false,
        },
      })

      -- Mock failed requires
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'telescope' then
          return true, {}
        elseif module == 'cmp' then
          return false, 'not found'
        end
        return original_pcall(func, module)
      end

      local result = health.check_integrations()
      assert.equals(health.WARN, result.status)
      assert.matches('Integration status:', result.message)
      assert.matches('telescope: available', result.message)
      assert.matches('nvim%-cmp: enabled but not installed', result.message)
      assert.matches('Install missing integrations', result.suggestion)
    end)

    it('should check all integration types', function()
      config.setup({
        integrations = {
          telescope = true,
          cmp = true,
          which_key = true,
          notify = true,
          lualine = true,
        },
      })

      -- Mock all integrations as available
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if
          module == 'telescope'
          or module == 'cmp'
          or module == 'which-key'
          or module == 'notify'
          or module == 'lualine'
        then
          return true, {}
        end
        return original_pcall(func, module)
      end

      local result = health.check_integrations()
      assert.equals(health.OK, result.status)
      assert.matches('telescope: available', result.message)
      assert.matches('nvim%-cmp: available', result.message)
      assert.matches('which%-key: available', result.message)
      assert.matches('nvim%-notify: available', result.message)
      assert.matches('lualine: available', result.message)
    end)

    it('should handle mixed integration status', function()
      config.setup({
        integrations = {
          telescope = true,
          cmp = true,
          which_key = true,
          notify = false,
          lualine = false,
        },
      })

      -- Mock some available, some not
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.pcall = function(func, module)
        if module == 'telescope' or module == 'which-key' then
          return true, {}
        elseif module == 'cmp' then
          return false, 'not found'
        end
        return original_pcall(func, module)
      end

      local result = health.check_integrations()
      assert.equals(health.WARN, result.status)
      assert.matches('telescope: available', result.message)
      assert.matches('nvim%-cmp: enabled but not installed', result.message)
      assert.matches('which%-key: available', result.message)
      assert.not_matches('nvim%-notify', result.message)
      assert.not_matches('lualine', result.message)
    end)
  end)

  describe('check() - Main health check function', function()
    it('should run all health checks and return results with names', function()
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = '/tmp/test_token.json',
        },
      })

      local results = health.check()
      assert.is_table(results)
      assert.equals(7, #results)

      local result_names = {}
      for _, result in ipairs(results) do
        assert.is_string(result.name)
        assert.is_string(result.status)
        assert.is_string(result.message)
        table.insert(result_names, result.name)
      end

      assert.truthy(utils.table_contains(result_names, 'Neovim Version'))
      assert.truthy(utils.table_contains(result_names, 'Dependencies'))
      assert.truthy(utils.table_contains(result_names, 'Configuration'))
      assert.truthy(utils.table_contains(result_names, 'Authentication'))
      assert.truthy(utils.table_contains(result_names, 'Network'))
      assert.truthy(utils.table_contains(result_names, 'File Permissions'))
      assert.truthy(utils.table_contains(result_names, 'Integrations'))
    end)

    it('should return consistent result structure', function()
      local results = health.check()

      for _, result in ipairs(results) do
        assert.is_string(result.name)
        assert.is_string(result.status)
        assert.is_string(result.message)
        assert.truthy(
          result.status == health.OK
            or result.status == health.WARN
            or result.status == health.ERROR
        )

        if result.suggestion then
          assert.is_string(result.suggestion)
        end
      end
    end)

    it('should handle errors in individual checks gracefully', function()
      local original_check_neovim = health.check_neovim_version
      health.check_neovim_version = function()
        error('Test error')
      end

      -- Should not crash the entire check
      assert.has_no.errors(function()
        health.check()
      end)

      health.check_neovim_version = original_check_neovim
    end)
  end)

  describe('get_health_summary()', function()
    it('should return correct summary counts', function()
      -- Mock some checks to return specific statuses
      local original_check_neovim = health.check_neovim_version
      local original_check_config = health.check_configuration
      local original_check_auth = health.check_authentication

      health.check_neovim_version = function()
        return { status = health.OK, message = 'OK' }
      end
      health.check_configuration = function()
        return { status = health.WARN, message = 'Warning' }
      end
      health.check_authentication = function()
        return { status = health.ERROR, message = 'Error' }
      end

      local summary = health.get_health_summary()
      assert.is_table(summary)
      assert.is_number(summary.ok)
      assert.is_number(summary.warn)
      assert.is_number(summary.error)
      assert.truthy(summary.ok >= 1)
      assert.truthy(summary.warn >= 1)
      assert.truthy(summary.error >= 1)
      assert.equals(7, summary.ok + summary.warn + summary.error)

      health.check_neovim_version = original_check_neovim
      health.check_configuration = original_check_config
      health.check_authentication = original_check_auth
    end)

    it('should handle all OK results', function()
      -- Mock all checks to return OK
      local original_functions = {}
      local check_functions = {
        'check_neovim_version',
        'check_dependencies',
        'check_configuration',
        'check_authentication',
        'check_network',
        'check_file_permissions',
        'check_integrations',
      }

      for _, func_name in ipairs(check_functions) do
        original_functions[func_name] = health[func_name]
        health[func_name] = function()
          return { status = health.OK, message = 'OK' }
        end
      end

      local summary = health.get_health_summary()
      assert.equals(7, summary.ok)
      assert.equals(0, summary.warn)
      assert.equals(0, summary.error)

      -- Restore original functions
      for func_name, original_func in pairs(original_functions) do
        health[func_name] = original_func
      end
    end)
  end)

  describe('is_healthy()', function()
    it('should return true when no errors exist', function()
      -- Mock all checks to return OK or WARN
      local original_functions = {}
      local check_functions = {
        'check_neovim_version',
        'check_dependencies',
        'check_configuration',
        'check_authentication',
        'check_network',
        'check_file_permissions',
        'check_integrations',
      }

      for i, func_name in ipairs(check_functions) do
        original_functions[func_name] = health[func_name]
        health[func_name] = function()
          return { status = i <= 3 and health.OK or health.WARN, message = 'Test' }
        end
      end

      assert.is_true(health.is_healthy())

      -- Restore original functions
      for func_name, original_func in pairs(original_functions) do
        health[func_name] = original_func
      end
    end)

    it('should return false when errors exist', function()
      -- Mock one check to return ERROR
      local original_check_neovim = health.check_neovim_version
      health.check_neovim_version = function()
        return { status = health.ERROR, message = 'Error' }
      end

      assert.is_false(health.is_healthy())

      health.check_neovim_version = original_check_neovim
    end)
  end)

  describe('get_check_result()', function()
    it('should return specific check results', function()
      local result = health.get_check_result('neovim_version')
      assert.is_table(result)
      assert.is_not_nil(result)
      if result then
        assert.is_string(result.status)
        assert.is_string(result.message)
      end
    end)

    it('should return nil for invalid check names', function()
      local result = health.get_check_result('invalid_check')
      assert.is_nil(result)
    end)

    it('should validate check name parameter', function()
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        health.get_check_result(123)
      end)
      assert.has.errors(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        health.get_check_result(nil)
      end)
    end)

    it('should support all check types', function()
      local check_types = {
        'neovim_version',
        'dependencies',
        'configuration',
        'authentication',
        'network',
        'file_permissions',
        'integrations',
      }

      for _, check_type in ipairs(check_types) do
        local result = health.get_check_result(check_type)
        assert.is_table(result)
        assert.is_not_nil(result)
        if result then
          assert.is_string(result.status)
          assert.is_string(result.message)
        end
      end
    end)
  end)

  describe('report_health_result()', function()
    it('should handle OK results', function()
      local result = { status = health.OK, message = 'Test OK' }

      -- Mock vim.health functions
      local reported_ok = false
      rawset(vim, 'health', {
        ok = function(msg)
          reported_ok = true
          assert.equals('Test OK', msg)
        end,
      })

      assert.has_no.errors(function()
        health.report_health_result(result)
      end)
      assert.is_true(reported_ok)
    end)

    it('should handle WARN results', function()
      local result = { status = health.WARN, message = 'Test Warning', suggestion = 'Fix this' }

      local reported_warn = false
      rawset(vim, 'health', {
        warn = function(msg, suggestion)
          reported_warn = true
          assert.equals('Test Warning', msg)
          assert.equals('Fix this', suggestion)
        end,
      })

      assert.has_no.errors(function()
        health.report_health_result(result)
      end)
      assert.is_true(reported_warn)
    end)

    it('should handle ERROR results', function()
      local result = { status = health.ERROR, message = 'Test Error', suggestion = 'Fix this' }

      local reported_error = false
      rawset(vim, 'health', {
        error = function(msg, suggestion)
          reported_error = true
          assert.equals('Test Error', msg)
          assert.equals('Fix this', suggestion)
        end,
      })

      assert.has_no.errors(function()
        health.report_health_result(result)
      end)
      assert.is_true(reported_error)
    end)
  end)

  describe('format_fallback_results()', function()
    it('should format results correctly', function()
      local results = {
        { status = health.OK, message = 'OK message' },
        { status = health.WARN, message = 'Warning message', suggestion = 'Fix warning' },
        { status = health.ERROR, message = 'Error message', suggestion = 'Fix error' },
      }

      local lines = health.format_fallback_results(results)
      assert.is_table(lines)
      assert.truthy(#lines > 0)

      local content = table.concat(lines, '\n')
      assert.matches('TwitchChat Health Check Results', content)
      assert.matches('✓ OK message', content)
      assert.matches('⚠ Warning message', content)
      assert.matches('✗ Error message', content)
      assert.matches('→ Fix warning', content)
      assert.matches('→ Fix error', content)
    end)

    it('should handle empty results', function()
      local results = {}
      local lines = health.format_fallback_results(results)
      assert.is_table(lines)
      assert.truthy(#lines >= 2) -- At least title and empty line
    end)

    it('should handle results without suggestions', function()
      local results = {
        { status = health.OK, message = 'OK message' },
      }

      local lines = health.format_fallback_results(results)
      local content = table.concat(lines, '\n')
      assert.matches('✓ OK message', content)
      assert.not_matches('→', content)
    end)
  end)

  describe('create_health_buffer()', function()
    it('should create buffer with correct content', function()
      local lines = { 'Line 1', 'Line 2', 'Line 3' }

      -- Mock vim.api functions
      local created_buffer = false
      local set_lines_called = false
      local set_options_called = 0
      local buffer_name_set = false

      rawset(vim.api, 'nvim_create_buf', function(listed, scratch)
        created_buffer = true
        assert.is_false(listed)
        assert.is_true(scratch)
        return 123 -- Mock buffer number
      end)

      rawset(vim.api, 'nvim_buf_set_lines', function(bufnr, start, end_line, strict, content)
        set_lines_called = true
        assert.equals(123, bufnr)
        assert.equals(0, start)
        assert.equals(-1, end_line)
        assert.is_false(strict)
        assert.same(lines, content)
      end)

      rawset(vim.api, 'nvim_buf_set_option', function(bufnr, option, value)
        set_options_called = set_options_called + 1
        assert.equals(123, bufnr)
        assert.truthy(option == 'modifiable' or option == 'buftype')
        if option == 'modifiable' then
          assert.is_false(value)
        elseif option == 'buftype' then
          assert.equals('nofile', value)
        end
      end)

      rawset(vim.api, 'nvim_buf_set_name', function(bufnr, name)
        buffer_name_set = true
        assert.equals(123, bufnr)
        assert.equals('TwitchChat Health Check', name)
      end)

      rawset(vim.api, 'nvim_win_set_buf', function(winnr, bufnr)
        assert.equals(0, winnr)
        assert.equals(123, bufnr)
      end)

      rawset(vim, 'cmd', function(cmd)
        assert.equals('split', cmd)
      end)

      assert.has_no.errors(function()
        health.create_health_buffer(lines)
      end)

      assert.is_true(created_buffer)
      assert.is_true(set_lines_called)
      assert.equals(2, set_options_called)
      assert.is_true(buffer_name_set)
    end)
  end)

  describe('display_fallback_results()', function()
    it('should call format and create buffer functions', function()
      local results = {
        { status = health.OK, message = 'Test message' },
      }

      local format_called = false
      local create_buffer_called = false
      local formatted_lines = { 'Formatted line 1', 'Formatted line 2' }

      local original_format = health.format_fallback_results
      local original_create = health.create_health_buffer

      health.format_fallback_results = function(input_results)
        format_called = true
        assert.same(results, input_results)
        return formatted_lines
      end

      health.create_health_buffer = function(lines)
        create_buffer_called = true
        assert.same(formatted_lines, lines)
      end

      assert.has_no.errors(function()
        health.display_fallback_results(results)
      end)

      assert.is_true(format_called)
      assert.is_true(create_buffer_called)

      health.format_fallback_results = original_format
      health.create_health_buffer = original_create
    end)
  end)

  describe('run_health_check()', function()
    it('should run checks and display results', function()
      local check_called = false
      local display_called = false
      local mock_results = {
        { status = health.OK, message = 'Test' },
      }

      local original_check = health.check
      local original_display = health.display_fallback_results

      health.check = function()
        check_called = true
        return mock_results
      end

      -- Mock vim.health not available by removing start method
      rawset(vim, 'health', {})

      health.display_fallback_results = function(results)
        display_called = true
        assert.same(mock_results, results)
      end

      assert.has_no.errors(function()
        health.run_health_check()
      end)

      assert.is_true(check_called)
      assert.is_true(display_called)

      health.check = original_check
      health.display_fallback_results = original_display
    end)

    it('should use vim.health when available', function()
      local check_called = false
      local health_start_called = false
      local report_called = false
      local mock_results = {
        { status = health.OK, message = 'Test' },
      }

      local original_check = health.check
      health.check = function()
        check_called = true
        return mock_results
      end

      rawset(vim, 'health', {
        start = function(title)
          health_start_called = true
          assert.equals('TwitchChat Health Check', title)
        end,
        ok = function(msg)
          report_called = true
          assert.equals('Test', msg)
        end,
      })

      assert.has_no.errors(function()
        health.run_health_check()
      end)

      assert.is_true(check_called)
      assert.is_true(health_start_called)
      assert.is_true(report_called)

      health.check = original_check
    end)
  end)

  describe('Edge Cases and Error Handling', function()
    it('should handle missing vim.health gracefully', function()
      rawset(vim, 'health', nil)

      assert.has_no.errors(function()
        health.run_health_check()
      end)
    end)

    it('should handle file system errors gracefully', function()
      rawset(vim.loop, 'fs_stat', function()
        error('File system error')
      end)

      assert.has_no.errors(function()
        health.check_file_permissions()
      end)
    end)

    it('should handle network errors gracefully', function()
      rawset(vim.fn, 'system', function()
        error('Network error')
      end)

      assert.has_no.errors(function()
        health.check_network()
      end)
    end)

    it('should handle JSON parsing errors gracefully', function()
      rawset(vim.fn, 'json_decode', function()
        error('JSON parsing error')
      end)

      local temp_file = '/tmp/test_token.json'
      config.setup({
        auth = {
          client_id = 'test_client_id',
          token_file = temp_file,
        },
      })

      utils.write_file(temp_file, 'invalid json')

      assert.has_no.errors(function()
        health.check_authentication()
      end)

      os.remove(temp_file)
    end)
  end)

  describe('Performance and Caching', function()
    it('should complete health checks within reasonable time', function()
      local start_time = vim.loop.now()
      health.check()
      local end_time = vim.loop.now()

      -- Health checks should complete within 1 second
      assert.truthy(end_time - start_time < 1000)
    end)

    it('should handle multiple concurrent check calls', function()
      local results = {}
      for i = 1, 5 do
        results[i] = health.check()
      end

      -- All results should be consistent
      for i = 2, 5 do
        assert.equals(#results[1], #results[i])
      end
    end)
  end)
end)
