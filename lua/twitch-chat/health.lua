---@class TwitchChatHealth
local M = {}

local utils = require('twitch-chat.utils')
local config = require('twitch-chat.config')

---Health check status types
M.OK = 'ok'
M.WARN = 'warn'
M.ERROR = 'error'

---@class HealthCheckResult
---@field status string Status of the check ('ok', 'warn', 'error')
---@field message string Human-readable message
---@field suggestion string? Optional suggestion for fixing issues

---Setup health check system
---@return nil
function M.setup()
  -- Health checks are now handled directly via vim.health API
  -- No setup needed as we use the proper API methods
end

---Safely run a health check function
---@param check_func function The check function to run
---@param check_name string The name of the check for error reporting
---@return HealthCheckResult result
local function safe_check(check_func, check_name)
  local success, result = pcall(check_func)
  if not success then
    return {
      status = M.ERROR,
      message = string.format('Health check %s failed: %s', check_name, result),
      suggestion = 'Please report this error to the plugin maintainers',
    }
  end
  return result
end

---Run all health checks
---@return HealthCheckResult[] results
function M.check()
  local results = {}

  -- Check Neovim version
  local neovim_result = safe_check(M.check_neovim_version, 'Neovim Version')
  neovim_result.name = 'Neovim Version'
  table.insert(results, neovim_result)

  -- Check required dependencies
  local deps_result = safe_check(M.check_dependencies, 'Dependencies')
  deps_result.name = 'Dependencies'
  table.insert(results, deps_result)

  -- Check configuration
  local config_result = safe_check(M.check_configuration, 'Configuration')
  config_result.name = 'Configuration'
  table.insert(results, config_result)

  -- Check authentication
  local auth_result = safe_check(M.check_authentication, 'Authentication')
  auth_result.name = 'Authentication'
  table.insert(results, auth_result)

  -- Check network connectivity
  local network_result = safe_check(M.check_network, 'Network')
  network_result.name = 'Network'
  table.insert(results, network_result)

  -- Check file permissions
  local perms_result = safe_check(M.check_file_permissions, 'File Permissions')
  perms_result.name = 'File Permissions'
  table.insert(results, perms_result)

  -- Check optional integrations
  local integrations_result = safe_check(M.check_integrations, 'Integrations')
  integrations_result.name = 'Integrations'
  table.insert(results, integrations_result)

  -- Check token rotation system
  local token_rotation_result = safe_check(M.check_token_rotation, 'Token Rotation')
  token_rotation_result.name = 'Token Rotation'
  table.insert(results, token_rotation_result)

  -- Check resource management
  local resource_result = safe_check(M.check_resource_management, 'Resource Management')
  resource_result.name = 'Resource Management'
  table.insert(results, resource_result)

  -- Check configuration validation
  local config_validation_result = safe_check(M.check_config_validation, 'Configuration Validation')
  config_validation_result.name = 'Configuration Validation'
  table.insert(results, config_validation_result)

  return results
end

---Check Neovim version compatibility
---@return HealthCheckResult
function M.check_neovim_version()
  local version = vim.version()
  local required_major = 0
  local required_minor = 9

  if
    version.major > required_major
    or (version.major == required_major and version.minor >= required_minor)
  then
    return {
      status = M.OK,
      message = string.format(
        'Neovim version %d.%d.%d is supported',
        version.major,
        version.minor,
        version.patch
      ),
    }
  else
    return {
      status = M.ERROR,
      message = string.format(
        'Neovim version %d.%d.%d is not supported',
        version.major,
        version.minor,
        version.patch
      ),
      suggestion = string.format(
        'Please upgrade to Neovim %d.%d or higher',
        required_major,
        required_minor
      ),
    }
  end
end

---Check required dependencies
---@return HealthCheckResult
function M.check_dependencies()
  local required_deps = {
    'plenary.nvim',
  }

  local optional_deps = {
    'telescope.nvim',
    'nvim-cmp',
    'which-key.nvim',
    'nvim-notify',
    'lualine.nvim',
  }

  local missing_required = {}
  local missing_optional = {}

  -- Check required dependencies
  for _, dep in ipairs(required_deps) do
    local success, _ = pcall(require, dep)
    if not success then
      table.insert(missing_required, dep)
    end
  end

  -- Check optional dependencies
  for _, dep in ipairs(optional_deps) do
    local success, _ = pcall(require, dep)
    if not success then
      table.insert(missing_optional, dep)
    end
  end

  if #missing_required > 0 then
    return {
      status = M.ERROR,
      message = string.format(
        'Missing required dependencies: %s',
        utils.join(missing_required, ', ')
      ),
      suggestion = 'Install missing dependencies with your plugin manager',
    }
  elseif #missing_optional > 0 then
    return {
      status = M.WARN,
      message = string.format(
        'Missing optional dependencies: %s',
        utils.join(missing_optional, ', ')
      ),
      suggestion = 'Install optional dependencies for enhanced functionality',
    }
  else
    return {
      status = M.OK,
      message = 'All dependencies are available',
    }
  end
end

---Check configuration validity
---@return HealthCheckResult
function M.check_configuration()
  if not config.options or utils.is_empty(config.options) then
    return {
      status = M.ERROR,
      message = 'Configuration is not initialized',
      suggestion = 'Call require("twitch-chat").setup() in your config',
    }
  end

  local success, err = pcall(config.validate)
  if not success then
    return {
      status = M.ERROR,
      message = string.format('Configuration validation failed: %s', err),
      suggestion = 'Check your configuration options',
    }
  end

  -- Check if client ID is set
  if config.options.auth.client_id == '' then
    return {
      status = M.WARN,
      message = 'Twitch client ID is not configured',
      suggestion = 'Set auth.client_id in your configuration',
    }
  end

  return {
    status = M.OK,
    message = 'Configuration is valid',
  }
end

---Check authentication setup
---@return HealthCheckResult
function M.check_authentication()
  if not config.options.auth.client_id or config.options.auth.client_id == '' then
    return {
      status = M.WARN,
      message = 'Authentication not configured',
      suggestion = 'Set up Twitch client ID and redirect URI',
    }
  end

  local token_file = config.options.auth.token_file
  if not utils.file_exists(token_file) then
    return {
      status = M.WARN,
      message = 'No authentication token found',
      suggestion = 'Run :TwitchAuth to authenticate with Twitch',
    }
  end

  -- Try to read token file
  local token_content = utils.read_file(token_file)
  if not token_content then
    return {
      status = M.ERROR,
      message = 'Cannot read authentication token file',
      suggestion = 'Check file permissions for token file',
    }
  end

  -- Try to parse token
  local success, token_data = pcall(vim.fn.json_decode, token_content)
  if not success then
    return {
      status = M.ERROR,
      message = 'Invalid token file format',
      suggestion = 'Re-authenticate with :TwitchAuth',
    }
  end

  -- Check token expiry
  if token_data.expires_at and token_data.expires_at < os.time() then
    return {
      status = M.WARN,
      message = 'Authentication token has expired',
      suggestion = 'Re-authenticate with :TwitchAuth',
    }
  end

  return {
    status = M.OK,
    message = 'Authentication is configured and valid',
  }
end

---Check network connectivity
---@return HealthCheckResult
function M.check_network()
  -- Check if we can resolve DNS
  local success, _ = pcall(vim.fn.system, 'nslookup irc.chat.twitch.tv')
  if not success or vim.v.shell_error ~= 0 then
    return {
      status = M.WARN,
      message = 'Cannot resolve Twitch IRC server',
      suggestion = 'Check your internet connection and DNS settings',
    }
  end

  -- Check if we can connect to Twitch IRC (basic test)
  local curl_available = vim.fn.executable('curl') == 1
  if curl_available then
    local curl_success, curl_result = pcall(
      vim.fn.system,
      'curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://www.twitch.tv'
    )
    if curl_success and curl_result:match('200') then
      return {
        status = M.OK,
        message = 'Network connectivity to Twitch is available',
      }
    else
      return {
        status = M.WARN,
        message = 'Cannot connect to Twitch servers',
        suggestion = 'Check your internet connection and firewall settings',
      }
    end
  end

  return {
    status = M.OK,
    message = 'Basic network connectivity checks passed',
  }
end

---Check file permissions
---@return HealthCheckResult
function M.check_file_permissions()
  local token_file = config.options.auth.token_file
  local token_dir = vim.fn.fnamemodify(token_file, ':h')

  -- Check if token directory exists and is writable
  local dir_exists_success, dir_exists = pcall(utils.dir_exists, token_dir)
  if not dir_exists_success then
    return {
      status = M.ERROR,
      message = 'Cannot check file system permissions',
      suggestion = 'Check file system availability and permissions',
    }
  end

  if not dir_exists then
    local success = utils.ensure_dir(token_dir)
    if not success then
      return {
        status = M.ERROR,
        message = string.format('Cannot create token directory: %s', token_dir),
        suggestion = 'Check file permissions for the cache directory',
      }
    end
  end

  -- Test write permissions
  local test_file = token_dir .. '/test_write_permissions'
  local write_success = utils.write_file(test_file, 'test')
  if write_success then
    -- Clean up test file
    pcall(os.remove, test_file)
    return {
      status = M.OK,
      message = 'File permissions are correct',
    }
  else
    return {
      status = M.ERROR,
      message = 'No write permissions for token directory',
      suggestion = 'Check file permissions for the cache directory',
    }
  end
end

---Check optional integrations
---@return HealthCheckResult
function M.check_integrations()
  local integration_checks = {}

  -- Check telescope integration
  if config.is_integration_enabled('telescope') then
    local success, _ = pcall(require, 'telescope')
    if success then
      table.insert(integration_checks, 'telescope: available')
    else
      table.insert(integration_checks, 'telescope: enabled but not installed')
    end
  end

  -- Check nvim-cmp integration
  if config.is_integration_enabled('cmp') then
    local success, _ = pcall(require, 'cmp')
    if success then
      table.insert(integration_checks, 'nvim-cmp: available')
    else
      table.insert(integration_checks, 'nvim-cmp: enabled but not installed')
    end
  end

  -- Check which-key integration
  if config.is_integration_enabled('which_key') then
    local success, _ = pcall(require, 'which-key')
    if success then
      table.insert(integration_checks, 'which-key: available')
    else
      table.insert(integration_checks, 'which-key: enabled but not installed')
    end
  end

  -- Check nvim-notify integration
  if config.is_integration_enabled('notify') then
    local success, _ = pcall(require, 'notify')
    if success then
      table.insert(integration_checks, 'nvim-notify: available')
    else
      table.insert(integration_checks, 'nvim-notify: enabled but not installed')
    end
  end

  -- Check lualine integration
  if config.is_integration_enabled('lualine') then
    local success, _ = pcall(require, 'lualine')
    if success then
      table.insert(integration_checks, 'lualine: available')
    else
      table.insert(integration_checks, 'lualine: enabled but not installed')
    end
  end

  if #integration_checks == 0 then
    return {
      status = M.OK,
      message = 'No integrations enabled',
    }
  end

  local has_missing = false
  for _, check in ipairs(integration_checks) do
    if check:match('enabled but not installed') then
      has_missing = true
      break
    end
  end

  if has_missing then
    return {
      status = M.WARN,
      message = string.format('Integration status: %s', utils.join(integration_checks, ', ')),
      suggestion = 'Install missing integrations or disable them in config',
    }
  else
    return {
      status = M.OK,
      message = string.format('Integration status: %s', utils.join(integration_checks, ', ')),
    }
  end
end

---Display health check results using vim.health API
---@param results HealthCheckResult[]
---@return nil
local function display_health_results(results)
  if vim.health and vim.health.start then
    vim.health.start('TwitchChat Health Check')

    for _, result in ipairs(results) do
      M.report_health_result(result)
    end
  else
    M.display_fallback_results(results)
  end
end

---Report a single health check result using proper vim.health API
---@param result HealthCheckResult
---@return nil
function M.report_health_result(result)
  if not vim.health then
    return
  end
  if result.status == M.OK then
    vim.health.ok(result.message)
  elseif result.status == M.WARN then
    vim.health.warn(result.message, result.suggestion)
  elseif result.status == M.ERROR then
    vim.health.error(result.message, result.suggestion)
  end
end

---Display results for older Neovim versions
---@param results HealthCheckResult[]
---@return nil
function M.display_fallback_results(results)
  local lines = M.format_fallback_results(results)
  M.create_health_buffer(lines)
end

---Format health results for fallback display
---@param results HealthCheckResult[]
---@return string[]
function M.format_fallback_results(results)
  local lines = { 'TwitchChat Health Check Results:', '' }

  for _, result in ipairs(results) do
    local status_icon = result.status == M.OK and '✓'
      or result.status == M.WARN and '⚠'
      or '✗'

    table.insert(lines, string.format('%s %s', status_icon, result.message))
    if result.suggestion then
      table.insert(lines, string.format('  → %s', result.suggestion))
    end
    table.insert(lines, '')
  end

  return lines
end

---Create and display health check buffer
---@param lines string[]
---@return nil
function M.create_health_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_name(bufnr, 'TwitchChat Health Check')

  -- Open in a split
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, bufnr)
end

---Run health checks and display results
---@return nil
function M.run_health_check()
  local results = M.check()
  display_health_results(results)
end

---Get health check summary
---@return { ok: number, warn: number, error: number }
function M.get_health_summary()
  local results = M.check()
  local summary = { ok = 0, warn = 0, error = 0 }

  for _, result in ipairs(results) do
    if result.status == M.OK then
      summary.ok = summary.ok + 1
    elseif result.status == M.WARN then
      summary.warn = summary.warn + 1
    elseif result.status == M.ERROR then
      summary.error = summary.error + 1
    end
  end

  return summary
end

---Check if the plugin is healthy (no errors)
---@return boolean is_healthy
function M.is_healthy()
  local results = M.check()

  for _, result in ipairs(results) do
    if result.status == M.ERROR then
      return false
    end
  end

  return true
end

---Get specific health check result
---@param check_name string Name of the check to run
---@return HealthCheckResult? result
function M.get_check_result(check_name)
  vim.validate({
    check_name = { check_name, 'string' },
  })

  local check_functions = {
    neovim_version = M.check_neovim_version,
    dependencies = M.check_dependencies,
    configuration = M.check_configuration,
    authentication = M.check_authentication,
    network = M.check_network,
    file_permissions = M.check_file_permissions,
    integrations = M.check_integrations,
    token_rotation = M.check_token_rotation,
    resource_management = M.check_resource_management,
    config_validation = M.check_config_validation,
  }

  local check_func = check_functions[check_name]
  if not check_func then
    return nil
  end

  return check_func()
end

---Check token rotation system health
---@return HealthCheckResult
function M.check_token_rotation()
  local auth = require('twitch-chat.modules.auth')

  -- Check if auth module is available
  if not auth then
    return {
      status = M.ERROR,
      message = 'Auth module not available',
      suggestion = 'Ensure the auth module is properly loaded',
    }
  end

  -- Check token rotation status
  local rotation_status = auth.get_rotation_status()

  if not rotation_status.has_token then
    return {
      status = M.WARN,
      message = 'No authentication token available',
      suggestion = 'Authenticate with Twitch to enable token rotation',
    }
  end

  if not rotation_status.can_rotate then
    return {
      status = M.WARN,
      message = 'Token rotation not available (no refresh token)',
      suggestion = 'Re-authenticate to get a refresh token for automatic rotation',
    }
  end

  if rotation_status.rotation_failures > 3 then
    return {
      status = M.ERROR,
      message = string.format(
        'Token rotation failing repeatedly (%d failures)',
        rotation_status.rotation_failures
      ),
      suggestion = 'Check network connectivity and re-authenticate if necessary',
    }
  end

  if rotation_status.expires_in < 3600 then -- Less than 1 hour
    return {
      status = M.WARN,
      message = string.format('Token expires soon (%d seconds)', rotation_status.expires_in),
      suggestion = 'Token will be rotated automatically, but check logs for any issues',
    }
  end

  return {
    status = M.OK,
    message = string.format(
      'Token rotation healthy (next rotation in %d seconds)',
      rotation_status.next_rotation_in
    ),
  }
end

---Check resource management health
---@return HealthCheckResult
function M.check_resource_management()
  local init = require('twitch-chat.init')

  -- Check if init module is available
  if not init or not init.get_resource_stats then
    return {
      status = M.WARN,
      message = 'Resource monitoring not available',
      suggestion = 'Update plugin to enable resource monitoring',
    }
  end

  local stats = init.get_resource_stats()
  local issues = {}

  -- Check memory usage
  if stats.memory_estimate_bytes > 50 * 1024 * 1024 then -- 50MB
    table.insert(
      issues,
      string.format('High memory usage: %.1fMB', stats.memory_estimate_bytes / 1024 / 1024)
    )
  end

  -- Check active connections
  if stats.active_connections > 10 then
    table.insert(issues, string.format('Many active connections: %d', stats.active_connections))
  end

  -- Check active timers
  if stats.active_timers > 20 then
    table.insert(issues, string.format('Many active timers: %d', stats.active_timers))
  end

  -- Check uptime for potential memory leaks
  if stats.uptime_seconds > 86400 and stats.memory_estimate_bytes > 20 * 1024 * 1024 then -- 24 hours + 20MB
    table.insert(issues, 'Potential memory leak detected (high memory usage after long uptime)')
  end

  if #issues > 0 then
    return {
      status = M.WARN,
      message = 'Resource management issues detected: ' .. table.concat(issues, ', '),
      suggestion = 'Consider restarting the plugin or investigating resource usage',
    }
  end

  return {
    status = M.OK,
    message = string.format(
      'Resource usage healthy (Memory: %.1fKB, Connections: %d, Timers: %d)',
      stats.memory_estimate_bytes / 1024,
      stats.active_connections,
      stats.active_timers
    ),
  }
end

---Check configuration validation system
---@return HealthCheckResult
function M.check_config_validation()
  -- Test detailed validation function
  local config_module = require('twitch-chat.config')

  if not config_module.validate_detailed then
    return {
      status = M.WARN,
      message = 'Enhanced configuration validation not available',
      suggestion = 'Update plugin to enable enhanced validation',
    }
  end

  -- Run detailed validation on current config
  local valid, error_msg = config_module.validate_detailed()

  if not valid then
    return {
      status = M.ERROR,
      message = 'Configuration validation failed',
      suggestion = string.format('Fix configuration errors: %s', error_msg or 'Unknown errors'),
    }
  end

  -- Check configuration health
  local health_info = config_module.get_health_info()

  if #health_info.errors > 0 then
    return {
      status = M.ERROR,
      message = string.format('Configuration has %d errors', #health_info.errors),
      suggestion = 'Fix configuration errors: ' .. table.concat(health_info.errors, ', '),
    }
  end

  if #health_info.warnings > 0 then
    return {
      status = M.WARN,
      message = string.format('Configuration has %d warnings', #health_info.warnings),
      suggestion = 'Address configuration warnings: ' .. table.concat(health_info.warnings, ', '),
    }
  end

  return {
    status = M.OK,
    message = string.format(
      'Configuration validation healthy (%d keys validated)',
      health_info.info.total_keys
    ),
  }
end

return M
