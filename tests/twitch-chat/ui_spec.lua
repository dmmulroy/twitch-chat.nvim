-- tests/twitch-chat/ui_spec.lua
-- UI system tests

local ui = require('twitch-chat.modules.ui')

describe('TwitchChat UI System', function()
  local test_channel = 'test_channel'
  local test_bufnr = 1234
  local test_winid = 5678
  local original_api = {}

  -- Mock vim.api functions
  local function setup_vim_api_mocks()
    original_api.nvim_open_win = vim.api.nvim_open_win
    original_api.nvim_win_is_valid = vim.api.nvim_win_is_valid
    original_api.nvim_win_close = vim.api.nvim_win_close
    original_api.nvim_win_set_option = vim.api.nvim_win_set_option
    original_api.nvim_win_get_config = vim.api.nvim_win_get_config
    original_api.nvim_win_set_config = vim.api.nvim_win_set_config
    original_api.nvim_win_get_buf = vim.api.nvim_win_get_buf
    original_api.nvim_win_set_buf = vim.api.nvim_win_set_buf
    original_api.nvim_get_current_win = vim.api.nvim_get_current_win
    original_api.nvim_set_current_win = vim.api.nvim_set_current_win
    original_api.nvim_buf_is_valid = vim.api.nvim_buf_is_valid
    original_api.nvim_buf_line_count = vim.api.nvim_buf_line_count
    original_api.nvim_buf_set_lines = vim.api.nvim_buf_set_lines
    original_api.nvim_buf_set_option = vim.api.nvim_buf_set_option
    original_api.nvim_buf_set_name = vim.api.nvim_buf_set_name
    original_api.nvim_buf_get_name = vim.api.nvim_buf_get_name
    original_api.nvim_create_buf = vim.api.nvim_create_buf
    original_api.nvim_win_set_cursor = vim.api.nvim_win_set_cursor
    original_api.nvim_create_augroup = vim.api.nvim_create_augroup
    original_api.nvim_create_autocmd = vim.api.nvim_create_autocmd
    original_api.nvim_set_hl = vim.api.nvim_set_hl

    -- Mock window and buffer tracking
    local valid_windows = {}
    local valid_buffers = {}
    local window_configs = {}
    local buffer_names = {}
    local buffer_options = {}
    local window_options = {}
    local window_id_counter = 1000
    local buffer_id_counter = 2000

    vim.api.nvim_open_win = function(bufnr, enter, config)
      local winid = window_id_counter
      window_id_counter = window_id_counter + 1
      valid_windows[winid] = true
      window_configs[winid] = vim.deepcopy(config)
      return winid
    end

    vim.api.nvim_win_is_valid = function(winid)
      return valid_windows[winid] == true
    end

    vim.api.nvim_win_close = function(winid, force)
      valid_windows[winid] = nil
      window_configs[winid] = nil
    end

    vim.api.nvim_win_set_option = function(winid, name, value)
      if not window_options[winid] then
        window_options[winid] = {}
      end
      window_options[winid][name] = value
    end

    vim.api.nvim_win_get_config = function(winid)
      return window_configs[winid] or {}
    end

    vim.api.nvim_win_set_config = function(winid, config)
      window_configs[winid] = vim.deepcopy(config)
    end

    vim.api.nvim_win_get_buf = function(winid)
      return test_bufnr
    end

    vim.api.nvim_win_set_buf = function(winid, bufnr)
      -- Mock implementation
    end

    vim.api.nvim_get_current_win = function()
      return test_winid
    end

    vim.api.nvim_set_current_win = function(winid)
      -- Mock implementation
    end

    vim.api.nvim_buf_is_valid = function(bufnr)
      return valid_buffers[bufnr] == true
    end

    vim.api.nvim_buf_line_count = function(bufnr)
      return 10
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_buf_set_lines = function(bufnr, start, end_, strict, lines)
      -- Mock implementation
    end

    vim.api.nvim_buf_set_option = function(bufnr, name, value)
      if not buffer_options[bufnr] then
        buffer_options[bufnr] = {}
      end
      buffer_options[bufnr][name] = value
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_buf_set_name = function(bufnr, name)
      buffer_names[bufnr] = name
    end

    vim.api.nvim_buf_get_name = function(bufnr)
      return buffer_names[bufnr] or ''
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_create_buf = function(listed, scratch)
      local bufnr = buffer_id_counter
      buffer_id_counter = buffer_id_counter + 1
      valid_buffers[bufnr] = true
      return bufnr
    end

    vim.api.nvim_win_set_cursor = function(winid, pos)
      -- Mock implementation
    end

    vim.api.nvim_create_augroup = function(name, opts)
      return 1
    end

    vim.api.nvim_create_autocmd = function(event, opts)
      return 1
    end

    vim.api.nvim_set_hl = function(ns, name, val)
      -- Mock implementation
    end
  end

  local function restore_vim_api()
    for name, func in pairs(original_api) do
      vim.api[name] = func
    end
  end

  -- Mock buffer module
  local function setup_buffer_mock()
    package.loaded['twitch-chat.modules.buffer'] = {
      get_chat_buffer = function(channel)
        if channel == test_channel then
          return {
            bufnr = test_bufnr,
            channel = channel,
            winid = nil,
          }
        end
        return nil
      end,
      get_all_buffers = function()
        return {
          [test_channel] = {
            bufnr = test_bufnr,
            channel = test_channel,
          },
          ['another_channel'] = {
            bufnr = test_bufnr + 1,
            channel = 'another_channel',
          },
        }
      end,
    }
  end

  -- Mock events module
  local function setup_events_mock()
    package.loaded['twitch-chat.events'] = {
      emit = function(event, data)
        -- Mock implementation
      end,
      on = function(event, callback)
        -- Mock implementation
      end,
    }
  end

  -- Mock vim functions
  local function setup_vim_mocks()
    -- Mock vim.o
    vim.o.columns = 120
    vim.o.lines = 30

    -- Mock vim.fn
    vim.fn['hlexists'] = function(name)
      return 0
    end

    vim.fn.prompt_setprompt = function(bufnr, prompt)
      -- Mock implementation
    end

    vim.fn.prompt_setcallback = function(bufnr, callback)
      -- Mock implementation
    end

    vim.fn['has'] = function(feature)
      return 1
    end

    vim.fn['expand'] = function(expr)
      return 'test_user'
    end

    -- Mock vim.cmd
    vim.cmd = function(cmd)
      -- Mock implementation
    end

    -- Mock vim.ui
    vim.ui = vim.ui or {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, callback)
      if callback then
        callback('test input')
      end
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, callback)
      if callback and #items > 0 then
        callback(items[1])
      end
    end

    -- Mock vim.keymap
    vim.keymap = vim.keymap or {}
    vim.keymap.set = function(mode, lhs, rhs, opts)
      -- Mock implementation
    end

    -- Mock vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim['notify'] = function(msg, level)
      -- Mock implementation
    end

    -- Mock vim.tbl_deep_extend
    vim.tbl_deep_extend = function(behavior, ...)
      local result = {}
      for _, tbl in ipairs({ ... }) do
        for k, v in pairs(tbl) do
          result[k] = v
        end
      end
      return result
    end

    -- Mock vim.tbl_contains
    vim.tbl_contains = function(tbl, value)
      for _, v in ipairs(tbl) do
        if v == value then
          return true
        end
      end
      return false
    end

    -- Mock vim.tbl_map
    vim.tbl_map = function(func, tbl)
      local result = {}
      for k, v in pairs(tbl) do
        result[k] = func(v)
      end
      return result
    end

    -- Mock vim.tbl_extend
    vim.tbl_extend = function(behavior, ...)
      local result = {}
      for _, tbl in ipairs({ ... }) do
        for k, v in pairs(tbl) do
          result[k] = v
        end
      end
      return result
    end

    -- Mock vim.tbl_count
    vim.tbl_count = function(tbl)
      local count = 0
      for _ in pairs(tbl) do
        count = count + 1
      end
      return count
    end

    -- Mock vim.deepcopy
    vim.deepcopy = function(tbl)
      if type(tbl) ~= 'table' then
        return tbl
      end
      local result = {}
      for k, v in pairs(tbl) do
        result[k] = vim.deepcopy(v)
      end
      return result
    end

    -- Mock vim.schedule
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.schedule = function(callback)
      callback()
    end

    -- Mock vim.wait
    vim.wait = function(timeout, callback)
      return callback()
    end

    -- Mock vim.log
    vim.log = {
      levels = {
        ERROR = 1,
        WARN = 2,
        INFO = 3,
        DEBUG = 4,
      },
    }
  end

  before_each(function()
    setup_vim_mocks()
    setup_vim_api_mocks()
    setup_buffer_mock()
    setup_events_mock()
  end)

  after_each(function()
    restore_vim_api()
    -- Clear module cache
    package.loaded['twitch-chat.modules.ui'] = nil
    package.loaded['twitch-chat.modules.buffer'] = nil
    package.loaded['twitch-chat.events'] = nil
    -- Reload the module
    ui = require('twitch-chat.modules.ui')
  end)

  describe('setup and configuration', function()
    it('should initialize with default configuration', function()
      assert.has_no.errors(function()
        ui.setup()
      end)
    end)

    it('should merge custom configuration', function()
      local custom_config = {
        ui = {
          float = {
            width = 0.9,
            height = 0.7,
            title = 'Custom Chat',
          },
          split = {
            size = 40,
            position = 'left',
          },
        },
      }

      assert.has_no.errors(function()
        ui.setup(custom_config)
      end)
    end)

    it('should setup autocmds for window management', function()
      local autocmd_calls = {}
      vim.api.nvim_create_autocmd = function(event, opts)
        table.insert(autocmd_calls, { event = event, opts = opts })
        return 1
      end

      ui.setup()

      assert.is_true(#autocmd_calls > 0)

      -- Check for VimResized autocmd
      local has_vim_resized = false
      for _, call in ipairs(autocmd_calls) do
        if call.event == 'VimResized' then
          has_vim_resized = true
          break
        end
      end
      assert.is_true(has_vim_resized)
    end)

    it('should setup global keymaps', function()
      local keymap_calls = {}
      vim.keymap.set = function(mode, lhs, rhs, opts)
        table.insert(keymap_calls, { mode = mode, lhs = lhs, opts = opts })
      end

      ui.setup()

      assert.is_true(#keymap_calls > 0)
    end)

    it('should setup highlight groups', function()
      local highlight_calls = {}
      vim.api.nvim_set_hl = function(ns, name, val)
        table.insert(highlight_calls, { ns = ns, name = name, val = val })
      end

      ui.setup()

      assert.is_true(#highlight_calls > 0)
    end)
  end)

  describe('floating window creation', function()
    it('should create floating window with correct configuration', function()
      local created_windows = {}
      vim.api.nvim_open_win = function(bufnr, enter, config)
        table.insert(created_windows, { bufnr = bufnr, enter = enter, config = config })
        return test_winid
      end

      local winid = ui.create_floating_window(test_channel, test_bufnr)

      assert.equals(test_winid, winid)
      assert.equals(1, #created_windows)

      local window = created_windows[1]
      assert.equals(test_bufnr, window.bufnr)
      assert.is_true(window.enter)
      assert.is_table(window.config)
      assert.equals('editor', window.config.relative)
      assert.matches(test_channel, window.config.title)
    end)

    it('should calculate window dimensions correctly', function()
      vim.o.columns = 100
      vim.o.lines = 50

      local created_windows = {}
      vim.api.nvim_open_win = function(bufnr, enter, config)
        table.insert(created_windows, { config = config })
        return test_winid
      end

      ui.create_floating_window(test_channel, test_bufnr)

      local config = created_windows[1].config
      assert.is_number(config.width)
      assert.is_number(config.height)
      assert.is_number(config.row)
      assert.is_number(config.col)
      assert.is_true(config.width > 0)
      assert.is_true(config.height > 0)
    end)

    it('should ensure window fits on screen', function()
      vim.o.columns = 50
      vim.o.lines = 20

      local created_windows = {}
      vim.api.nvim_open_win = function(bufnr, enter, config)
        table.insert(created_windows, { config = config })
        return test_winid
      end

      ui.create_floating_window(test_channel, test_bufnr)

      local config = created_windows[1].config
      assert.is_true(config.col + config.width <= vim.o.columns)
      assert.is_true(config.row + config.height <= vim.o.lines)
    end)

    it('should set window options correctly', function()
      local window_options = {}
      vim.api.nvim_win_set_option = function(winid, name, value)
        if not window_options[winid] then
          window_options[winid] = {}
        end
        window_options[winid][name] = value
      end

      local winid = ui.create_floating_window(test_channel, test_bufnr)

      assert.is_table(window_options[winid])
      assert.equals(true, window_options[winid].wrap)
      assert.equals(false, window_options[winid].number)
      assert.equals('no', window_options[winid].signcolumn)
    end)
  end)

  describe('split window creation', function()
    it('should create split window with correct command', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      ui.create_split_window(test_channel, test_bufnr, 'split')

      assert.is_true(#cmd_calls > 0)
      assert.matches('split', cmd_calls[1])
    end)

    it('should create vsplit window with correct command', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      ui.create_split_window(test_channel, test_bufnr, 'vsplit')

      assert.is_true(#cmd_calls > 0)
      assert.matches('vsplit', cmd_calls[1])
    end)

    it('should set buffer in split window', function()
      local buf_calls = {}
      vim.api.nvim_win_set_buf = function(winid, bufnr)
        table.insert(buf_calls, { winid = winid, bufnr = bufnr })
      end

      ui.create_split_window(test_channel, test_bufnr, 'split')

      assert.equals(1, #buf_calls)
      assert.equals(test_bufnr, buf_calls[1].bufnr)
    end)

    it('should set window options for split', function()
      local window_options = {}
      vim.api.nvim_win_set_option = function(winid, name, value)
        if not window_options[winid] then
          window_options[winid] = {}
        end
        window_options[winid][name] = value
      end

      ui.create_split_window(test_channel, test_bufnr, 'split')

      assert.is_table(window_options[test_winid])
      assert.equals(true, window_options[test_winid].wrap)
      assert.equals(false, window_options[test_winid].number)
    end)
  end)

  describe('tab window creation', function()
    it('should create new tab', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      ui.create_tab_window(test_channel, test_bufnr)

      assert.is_true(#cmd_calls > 0)
      assert.equals('tabnew', cmd_calls[1])
    end)

    it('should set buffer in tab window', function()
      local buf_calls = {}
      vim.api.nvim_win_set_buf = function(winid, bufnr)
        table.insert(buf_calls, { winid = winid, bufnr = bufnr })
      end

      ui.create_tab_window(test_channel, test_bufnr)

      assert.equals(1, #buf_calls)
      assert.equals(test_bufnr, buf_calls[1].bufnr)
    end)

    it('should set buffer options for tab', function()
      local buffer_options = {}
      vim.api.nvim_buf_set_option = function(bufnr, name, value)
        if not buffer_options[bufnr] then
          buffer_options[bufnr] = {}
        end
        buffer_options[bufnr][name] = value
      end

      ui.create_tab_window(test_channel, test_bufnr)

      assert.is_table(buffer_options[test_bufnr])
      assert.equals('nofile', buffer_options[test_bufnr].buftype)
    end)
  end)

  describe('buffer display', function()
    it('should show buffer in floating layout', function()
      local opened_windows = {}
      vim.api.nvim_open_win = function(bufnr, enter, config)
        table.insert(opened_windows, { bufnr = bufnr, config = config })
        return test_winid
      end

      ui.show_buffer(test_channel, 'float')

      assert.equals(1, #opened_windows)
      assert.equals(test_bufnr, opened_windows[1].bufnr)
    end)

    it('should show buffer in split layout', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      ui.show_buffer(test_channel, 'split')

      assert.is_true(#cmd_calls > 0)
      assert.matches('split', cmd_calls[1])
    end)

    it('should show buffer in tab layout', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      ui.show_buffer(test_channel, 'tab')

      assert.is_true(#cmd_calls > 0)
      assert.equals('tabnew', cmd_calls[1])
    end)

    it('should handle non-existent buffer', function()
      package.loaded['twitch-chat.modules.buffer'].get_chat_buffer = function()
        return nil
      end

      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.show_buffer('non_existent_channel', 'float')

      assert.equals(1, #notifications)
      assert.matches('No buffer found', notifications[1].msg)
    end)

    it('should close existing window before creating new one', function()
      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      -- First show
      ui.show_buffer(test_channel, 'float')

      -- Show again (should close previous)
      ui.show_buffer(test_channel, 'float')

      assert.equals(1, #closed_windows)
    end)

    it('should set up window keymaps', function()
      local keymap_calls = {}
      vim.keymap.set = function(mode, lhs, rhs, opts)
        table.insert(keymap_calls, { mode = mode, lhs = lhs, opts = opts })
      end

      ui.show_buffer(test_channel, 'float')

      -- Should have window-specific keymaps
      local buffer_keymaps = {}
      for _, call in ipairs(keymap_calls) do
        if call.opts and call.opts.buffer then
          table.insert(buffer_keymaps, call)
        end
      end
      assert.is_true(#buffer_keymaps > 0)
    end)

    it('should auto-scroll to bottom', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(winid, pos)
        table.insert(cursor_calls, { winid = winid, pos = pos })
      end

      ui.show_buffer(test_channel, 'float')

      assert.equals(1, #cursor_calls)
      assert.equals(10, cursor_calls[1].pos[1]) -- Line count from mock
    end)
  end)

  describe('input window management', function()
    it('should create input window', function()
      local created_buffers = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.api.nvim_create_buf = function(listed, scratch)
        table.insert(created_buffers, { listed = listed, scratch = scratch })
        return test_bufnr + 100
      end

      ui.create_input_window(test_channel)

      assert.equals(1, #created_buffers)
      assert.is_false(created_buffers[1].listed)
      assert.is_true(created_buffers[1].scratch)
    end)

    it('should set prompt buffer options', function()
      local buffer_options = {}
      vim.api.nvim_buf_set_option = function(bufnr, name, value)
        if not buffer_options[bufnr] then
          buffer_options[bufnr] = {}
        end
        buffer_options[bufnr][name] = value
      end

      ui.create_input_window(test_channel)

      local input_bufnr = test_bufnr + 100
      assert.is_table(buffer_options[input_bufnr])
      assert.equals('prompt', buffer_options[input_bufnr].buftype)
      assert.equals('wipe', buffer_options[input_bufnr].bufhidden)
    end)

    it('should position input window below chat window', function()
      local created_windows = {}
      vim.api.nvim_open_win = function(bufnr, enter, config)
        table.insert(created_windows, { bufnr = bufnr, config = config })
        return test_winid + 100
      end

      -- First show chat window
      ui.show_buffer(test_channel, 'float')

      -- Then create input window
      ui.create_input_window(test_channel)

      -- Should have two windows: chat and input
      assert.is_true(#created_windows >= 2)

      -- Input window should be positioned below chat
      local input_config = created_windows[#created_windows].config
      assert.is_table(input_config)
      assert.equals('editor', input_config.relative)
    end)

    it('should toggle input window', function()
      ui.show_buffer(test_channel, 'float')

      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      -- First toggle should create input window
      ui.toggle_input_window()

      -- Second toggle should close input window
      ui.toggle_input_window()

      assert.equals(1, #closed_windows)
    end)

    it('should handle no active channel', function()
      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.toggle_input_window()

      assert.equals(1, #notifications)
      assert.matches('No active chat channel', notifications[1].msg)
    end)
  end)

  describe('layout switching', function()
    it('should toggle between layouts', function()
      ui.show_buffer(test_channel, 'float')

      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.toggle_layout(test_channel)

      assert.equals(1, #notifications)
      assert.matches('Layout changed to:', notifications[1].msg)
    end)

    it('should cycle through all layout types', function()
      ui.show_buffer(test_channel, 'float')

      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      -- Should cycle through: float -> vsplit -> split -> tab -> float
      ui.toggle_layout(test_channel)
      ui.toggle_layout(test_channel)
      ui.toggle_layout(test_channel)
      ui.toggle_layout(test_channel)

      assert.equals(4, #notifications)
    end)

    it('should handle invalid layout type', function()
      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.show_buffer(test_channel, 'invalid_layout')

      assert.equals(1, #notifications)
      assert.matches('Unknown layout type:', notifications[1].msg)
    end)

    it('should set layout type', function()
      ui.set_layout_type('vsplit')
      assert.equals('vsplit', ui.get_layout_type())
    end)

    it('should reject invalid layout type', function()
      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.set_layout_type('invalid')

      assert.equals(1, #notifications)
      assert.matches('Invalid layout type:', notifications[1].msg)
    end)
  end)

  describe('window management', function()
    it('should resize windows on vim resize', function()
      ui.show_buffer(test_channel, 'float')

      local config_calls = {}
      vim.api.nvim_win_set_config = function(winid, config)
        table.insert(config_calls, { winid = winid, config = config })
      end

      ui.resize_windows()

      assert.equals(1, #config_calls)
      assert.is_table(config_calls[1].config)
    end)

    it('should close all windows', function()
      ui.show_buffer(test_channel, 'float')

      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      ui.close_all_windows()

      assert.is_true(#closed_windows > 0)
    end)

    it('should close specific channel window', function()
      ui.show_buffer(test_channel, 'float')

      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      ui.close_window(test_channel)

      assert.equals(1, #closed_windows)
    end)

    it('should focus chat window', function()
      ui.show_buffer(test_channel, 'float')

      local focus_calls = {}
      vim.api.nvim_set_current_win = function(winid)
        table.insert(focus_calls, winid)
      end

      ui.focus_chat_window()

      assert.equals(1, #focus_calls)
    end)

    it('should handle focus with no active channel', function()
      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.focus_chat_window()

      assert.equals(1, #notifications)
      assert.matches('No active chat channel', notifications[1].msg)
    end)
  end)

  describe('channel switching', function()
    it('should show channel selection', function()
      local select_calls = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(items, opts, callback)
        table.insert(select_calls, { items = items, opts = opts })
        if callback then
          callback(items[1])
        end
      end

      ui.switch_channel()

      assert.equals(1, #select_calls)
      assert.is_table(select_calls[1].items)
      assert.is_true(#select_calls[1].items > 0)
    end)

    it('should handle no channels available', function()
      package.loaded['twitch-chat.modules.buffer'].get_all_buffers = function()
        return {}
      end

      local notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim['notify'] = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      ui.switch_channel()

      assert.equals(1, #notifications)
      assert.matches('No channels available', notifications[1].msg)
    end)
  end)

  describe('state management', function()
    it('should provide UI state information', function()
      ui.show_buffer(test_channel, 'float')

      local state = ui.get_state()

      assert.is_table(state)
      assert.is_table(state.windows)
      assert.is_string(state.layout_type)
      assert.is_string(state.current_channel)
    end)

    it('should check if channel is visible', function()
      ui.show_buffer(test_channel, 'float')

      assert.is_true(ui.is_channel_visible(test_channel))
      assert.is_false(ui.is_channel_visible('non_existent_channel'))
    end)

    it('should get window ID for channel', function()
      ui.show_buffer(test_channel, 'float')

      local winid = ui.get_window_id(test_channel)
      assert.is_number(winid)

      local invalid_winid = ui.get_window_id('non_existent_channel')
      assert.is_nil(invalid_winid)
    end)
  end)

  describe('input handling', function()
    it('should handle quick input', function()
      local input_calls = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, callback)
        table.insert(input_calls, opts)
        if callback then
          callback('test message')
        end
      end

      ui.quick_input(test_channel)

      assert.equals(1, #input_calls)
      assert.matches(test_channel, input_calls[1].prompt)
    end)

    it('should emit send message event on input', function()
      local event_calls = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      package.loaded['twitch-chat.events'].emit = function(event, data)
        table.insert(event_calls, { event = event, data = data })
      end

      ui.quick_input(test_channel)

      assert.equals(1, #event_calls)
      assert.equals('send_message', event_calls[1].event)
      assert.equals(test_channel, event_calls[1].data.channel)
    end)

    it('should handle empty input', function()
      local event_calls = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      package.loaded['twitch-chat.events'].emit = function(event, data)
        table.insert(event_calls, { event = event, data = data })
      end

      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, callback)
        if callback then
          callback('')
        end
      end

      ui.quick_input(test_channel)

      assert.equals(0, #event_calls)
    end)
  end)

  describe('edge cases and error handling', function()
    it('should handle invalid window operations', function()
      assert.has_no.errors(function()
        ui.close_window('non_existent_channel')
      end)

      assert.has_no.errors(function()
        ui.focus_chat_window()
      end)

      assert.has_no.errors(function()
        ui.toggle_layout('non_existent_channel')
      end)
    end)

    it('should handle missing buffer module', function()
      package.loaded['twitch-chat.modules.buffer'] = nil

      assert.has_no.errors(function()
        ui.show_buffer(test_channel, 'float')
      end)
    end)

    it('should handle missing events module', function()
      package.loaded['twitch-chat.events'] = nil

      assert.has_no.errors(function()
        ui.quick_input(test_channel)
      end)
    end)

    it('should handle window creation failures', function()
      vim.api.nvim_open_win = function()
        error('Window creation failed')
      end

      assert.has_errors(function()
        ui.create_floating_window(test_channel, test_bufnr)
      end)
    end)

    it('should handle invalid buffer references', function()
      vim.api.nvim_buf_is_valid = function()
        return false
      end

      assert.has_no.errors(function()
        ui.show_buffer(test_channel, 'float')
      end)
    end)
  end)

  describe('multiple windows', function()
    it('should handle multiple channel windows', function()
      ui.show_buffer(test_channel, 'float')
      ui.show_buffer('another_channel', 'split')

      local state = ui.get_state()
      assert.is_true(vim.tbl_count(state.windows) >= 2)
    end)

    it('should track multiple windows correctly', function()
      ui.show_buffer(test_channel, 'float')
      ui.show_buffer('another_channel', 'split')

      assert.is_true(ui.is_channel_visible(test_channel))
      assert.is_true(ui.is_channel_visible('another_channel'))
    end)

    it('should close multiple windows', function()
      ui.show_buffer(test_channel, 'float')
      ui.show_buffer('another_channel', 'split')

      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      ui.close_all_windows()

      assert.is_true(#closed_windows >= 2)
    end)
  end)

  describe('integration with events', function()
    it('should listen for channel_joined events', function()
      local event_listeners = {}
      package.loaded['twitch-chat.events'].on = function(event, callback)
        table.insert(event_listeners, { event = event, callback = callback })
      end

      -- Reload module to trigger event listener setup
      package.loaded['twitch-chat.modules.ui'] = nil
      ui = require('twitch-chat.modules.ui')

      -- Check that channel_joined listener was registered
      local has_joined_listener = false
      for _, listener in ipairs(event_listeners) do
        if listener.event == 'channel_joined' then
          has_joined_listener = true
          break
        end
      end
      assert.is_true(has_joined_listener)
    end)

    it('should listen for channel_left events', function()
      local event_listeners = {}
      package.loaded['twitch-chat.events'].on = function(event, callback)
        table.insert(event_listeners, { event = event, callback = callback })
      end

      -- Reload module to trigger event listener setup
      package.loaded['twitch-chat.modules.ui'] = nil
      ui = require('twitch-chat.modules.ui')

      -- Check that channel_left listener was registered
      local has_left_listener = false
      for _, listener in ipairs(event_listeners) do
        if listener.event == 'channel_left' then
          has_left_listener = true
          break
        end
      end
      assert.is_true(has_left_listener)
    end)
  end)

  describe('performance', function()
    it('should handle rapid layout changes', function()
      ui.show_buffer(test_channel, 'float')

      local start_time = vim.loop and vim.loop.hrtime() or 0

      -- Rapidly cycle through layouts
      for i = 1, 10 do
        ui.toggle_layout(test_channel)
      end

      local end_time = vim.loop and vim.loop.hrtime() or 0

      -- Should complete quickly (if vim.loop is available)
      if vim.loop then
        local elapsed_ms = (end_time - start_time) / 1000000
        assert.is_true(elapsed_ms < 100)
      end
    end)

    it('should handle window resize efficiently', function()
      ui.show_buffer(test_channel, 'float')

      local config_calls = {}
      vim.api.nvim_win_set_config = function(winid, config)
        table.insert(config_calls, { winid = winid, config = config })
      end

      -- Multiple resize calls should be handled efficiently
      for i = 1, 5 do
        ui.resize_windows()
      end

      assert.equals(5, #config_calls)
    end)

    it('should cleanup resources properly', function()
      ui.show_buffer(test_channel, 'float')
      ui.create_input_window(test_channel)

      local closed_windows = {}
      vim.api.nvim_win_close = function(winid, force)
        table.insert(closed_windows, { winid = winid, force = force })
      end

      ui.close_all_windows()

      local state = ui.get_state()
      assert.equals(0, vim.tbl_count(state.windows))
      assert.is_nil(state.current_channel)
    end)
  end)
end)
