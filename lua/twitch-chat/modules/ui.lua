---@class TwitchChatUI
---UI components and window management for Twitch chat
local M = {}
local logger = require('twitch-chat.modules.logger')

---@class WindowConfig
---@field width number|string
---@field height number|string
---@field row number|string
---@field col number|string
---@field relative string
---@field anchor string?
---@field border string|table
---@field title string?
---@field title_pos string?
---@field style string?
---@field focusable boolean?
---@field zindex number?

---@class LayoutConfig
---@field type string -- 'float', 'split', 'vsplit', 'tab'
---@field position string -- 'center', 'top', 'bottom', 'left', 'right'
---@field size number -- percentage or absolute size
---@field relative_to string -- 'editor', 'win', 'cursor'

---@class UIState
---@field windows table<string, number> -- channel -> winid mapping
---@field layout_type string
---@field current_channel string?
---@field input_winid number?
---@field input_bufnr number?

---@type UIState
local state = {
  windows = {},
  layout_type = 'float',
  current_channel = nil,
  input_winid = nil,
  input_bufnr = nil,
}

-- Default configuration
local default_config = {
  ui = {
    layout = {
      type = 'float',
      position = 'center',
      size = 80, -- percentage
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
    split = {
      position = 'right',
      size = 50, -- columns for vsplit, rows for split
    },
    highlights = {
      border = 'FloatBorder',
      title = 'FloatTitle',
      background = 'Normal',
    },
    keymaps = {
      toggle_input = '<C-i>',
      cycle_layout = '<C-L>',
      focus_chat = '<C-c>',
      close_all = '<C-q>',
    },
  },
}

---Initialize the UI module
---@param config table?
---@return nil
function M.setup(config)
  if config then
    default_config = vim.tbl_deep_extend('force', default_config, config)
  end

  -- Setup autocmds for UI management
  local group = vim.api.nvim_create_augroup('TwitchChatUI', { clear = true })

  -- Handle window resize
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      M.resize_windows()
    end,
  })

  -- Clean up on vim leave
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      M.close_all_windows()
    end,
  })

  -- Setup global keymaps
  M.setup_global_keymaps()

  -- Setup highlight groups
  M.setup_highlights()
end

---Setup global keymaps for UI control
---@return nil
function M.setup_global_keymaps()
  local keymaps = default_config.ui and default_config.ui.keymaps
  if not keymaps then
    logger.warn('UI keymaps configuration is missing', { module = 'ui' })
    return
  end

  vim.keymap.set('n', keymaps.toggle_input, function()
    M.toggle_input_window()
  end, { desc = 'Toggle Twitch chat input' })

  vim.keymap.set('n', keymaps.cycle_layout, function()
    M.cycle_layout()
  end, { desc = 'Cycle Twitch chat layout' })

  vim.keymap.set('n', keymaps.focus_chat, function()
    M.focus_chat_window()
  end, { desc = 'Focus Twitch chat window' })

  vim.keymap.set('n', keymaps.close_all, function()
    M.close_all_windows()
  end, { desc = 'Close all Twitch chat windows' })
end

---Setup highlight groups for UI elements
---@return nil
function M.setup_highlights()
  local highlights = default_config.ui and default_config.ui.highlights
  if not highlights then
    logger.warn('UI highlights configuration is missing', { module = 'ui' })
    return
  end

  -- Set default highlights if they don't exist
  if not vim.fn.hlexists('TwitchChatBorder') then
    vim.api.nvim_set_hl(0, 'TwitchChatBorder', { link = highlights.border })
  end

  if not vim.fn.hlexists('TwitchChatTitle') then
    vim.api.nvim_set_hl(0, 'TwitchChatTitle', { link = highlights.title })
  end

  if not vim.fn.hlexists('TwitchChatBackground') then
    vim.api.nvim_set_hl(0, 'TwitchChatBackground', { link = highlights.background })
  end
end

---Set common window options for chat windows
---@param winid number Window ID
---@param window_type string Type of window ('chat', 'input')
---@return nil
function M.set_common_window_options(winid, window_type)
  -- Common options for all chat windows
  vim.api.nvim_win_set_option(winid, 'wrap', true)
  vim.api.nvim_win_set_option(winid, 'linebreak', true)
  vim.api.nvim_win_set_option(winid, 'number', false)
  vim.api.nvim_win_set_option(winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(winid, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(winid, 'foldcolumn', '0')
  vim.api.nvim_win_set_option(winid, 'colorcolumn', '')

  -- Window-type specific options
  if window_type == 'chat' then
    vim.api.nvim_win_set_option(winid, 'cursorline', false)
  elseif window_type == 'input' then
    vim.api.nvim_win_set_option(winid, 'cursorline', true)
  end
end

---Create a floating window for chat display
---@param channel string
---@param bufnr number
---@return number winid
function M.create_floating_window(channel, bufnr)
  local config = default_config.ui.float

  -- Calculate window dimensions
  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor(vim.o.lines * config.row)
  local col = math.floor(vim.o.columns * config.col)

  -- Ensure window fits on screen
  if col + width > vim.o.columns then
    col = vim.o.columns - width
  end
  if row + height > vim.o.lines then
    row = vim.o.lines - height
  end

  ---@type WindowConfig
  local win_config = {
    width = width,
    height = height,
    row = row,
    col = col,
    relative = 'editor',
    border = config.border,
    title = config.title .. ' - ' .. channel,
    title_pos = config.title_pos,
    style = config.style,
    focusable = config.focusable,
    zindex = config.zindex,
  }

  local winid = vim.api.nvim_open_win(bufnr, true, win_config)

  -- Set common window options
  M.set_common_window_options(winid, 'chat')

  -- Set window-specific highlights
  vim.api.nvim_win_set_option(
    winid,
    'winhl',
    'Normal:TwitchChatBackground,FloatBorder:TwitchChatBorder'
  )

  return winid
end

---Create a split window for chat display
---@param channel string
---@param bufnr number
---@param split_type string -- 'split' or 'vsplit'
---@return number winid
function M.create_split_window(channel, bufnr, split_type)
  local config = default_config.ui.split
  split_type = split_type
    or (config.position == 'left' or config.position == 'right') and 'vsplit'
    or 'split'

  local cmd
  if split_type == 'vsplit' then
    if config.position == 'left' then
      cmd = 'topleft ' .. config.size .. 'vsplit'
    else
      cmd = 'botright ' .. config.size .. 'vsplit'
    end
  else
    if config.position == 'top' then
      cmd = 'topleft ' .. config.size .. 'split'
    else
      cmd = 'botright ' .. config.size .. 'split'
    end
  end

  -- Execute split command
  vim.cmd(cmd)
  local winid = vim.api.nvim_get_current_win()

  -- Set the buffer
  vim.api.nvim_win_set_buf(winid, bufnr)

  -- Set common window options
  M.set_common_window_options(winid, 'chat')

  -- Set window title if supported
  if vim.fn.has('nvim-0.10') then
    vim.api.nvim_win_set_option(winid, 'statusline', '%t - ' .. channel)
  end

  return winid
end

---Create a tab for chat display
---@param channel string
---@param bufnr number
---@return number winid
function M.create_tab_window(channel, bufnr)
  vim.cmd('tabnew')
  local winid = vim.api.nvim_get_current_win()

  -- Set the buffer
  vim.api.nvim_win_set_buf(winid, bufnr)

  -- Set tab title
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')

  -- Set common window options
  M.set_common_window_options(winid, 'chat')

  return winid
end

---Show a chat buffer in a window
---@param channel string
---@param layout_type string?
function M.show_buffer(channel, layout_type)
  local buffer = require('twitch-chat.modules.buffer')
  local chat_buffer = buffer.get_chat_buffer(channel)

  if not chat_buffer then
    logger.error(
      'No buffer found for channel',
      { channel = channel, module = 'ui' },
      { notify = true, category = 'user_action' }
    )
    return
  end

  layout_type = layout_type or state.layout_type

  -- Close existing window for this channel
  if state.windows[channel] and vim.api.nvim_win_is_valid(state.windows[channel]) then
    vim.api.nvim_win_close(state.windows[channel], true)
  end

  local winid
  if layout_type == 'float' then
    winid = M.create_floating_window(channel, chat_buffer.bufnr)
  elseif layout_type == 'split' then
    winid = M.create_split_window(channel, chat_buffer.bufnr, 'split')
  elseif layout_type == 'vsplit' then
    winid = M.create_split_window(channel, chat_buffer.bufnr, 'vsplit')
  elseif layout_type == 'tab' then
    winid = M.create_tab_window(channel, chat_buffer.bufnr)
  else
    logger.error('Unknown layout type', { layout_type = layout_type, module = 'ui' })
    return
  end

  -- Update state consistently
  M._update_window_state(channel, winid, chat_buffer)

  -- Setup window-specific keymaps
  M.setup_window_keymaps(winid, channel)

  -- Auto-scroll to bottom
  local line_count = vim.api.nvim_buf_line_count(chat_buffer.bufnr)
  if line_count > 0 then
    vim.api.nvim_win_set_cursor(winid, { line_count, 0 })
  end
end

---Create buffer and show in window (unified interface)
---@param channel string
---@param layout_type string?
---@return boolean success
function M.create_and_show_buffer(channel, layout_type)
  local buffer = require('twitch-chat.modules.buffer')

  -- Create buffer if it doesn't exist
  local chat_buffer = buffer.get_chat_buffer(channel)
  if not chat_buffer then
    chat_buffer = buffer.create_chat_buffer(channel)
    if not chat_buffer then
      logger.error('Failed to create buffer for channel', { channel = channel, module = 'ui' })
      return false
    end
  end

  -- Show the buffer
  M.show_buffer(channel, layout_type)
  return true
end

---Update window state consistently
---@param channel string
---@param winid number
---@param chat_buffer table
---@return nil
function M._update_window_state(channel, winid, chat_buffer)
  -- Update UI state
  state.windows[channel] = winid
  state.current_channel = channel

  -- Update buffer state
  chat_buffer.winid = winid

  -- Emit event for other modules
  local events = require('twitch-chat.events')
  if events then
    events.emit('window_created', {
      channel = channel,
      winid = winid,
      layout_type = state.layout_type,
    })
  end
end

---Setup window-specific keymaps
---@param winid number
---@param channel string
function M.setup_window_keymaps(winid, channel)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Input and messaging
  vim.keymap.set('n', 'i', function()
    M.quick_input(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Quick input for ' .. channel }))

  vim.keymap.set('n', 'I', function()
    M.focus_input_window(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Focus input window' }))

  vim.keymap.set('n', '<CR>', function()
    M.quick_input(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Send message' }))

  -- Channel and layout management
  vim.keymap.set('n', 'c', function()
    M.switch_channel()
  end, vim.tbl_extend('force', opts, { desc = 'Switch channel' }))

  vim.keymap.set('n', 'l', function()
    M.toggle_layout(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Toggle layout' }))

  -- Buffer operations (delegate to buffer module)
  vim.keymap.set('n', 'K', function()
    local buffer = require('twitch-chat.modules.buffer')
    buffer.toggle_auto_scroll(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Toggle auto-scroll' }))

  vim.keymap.set('n', 'C', function()
    local buffer = require('twitch-chat.modules.buffer')
    buffer.clear_buffer(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Clear buffer' }))

  -- Window operations
  vim.keymap.set('n', 'q', function()
    M.close_window(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Close window' }))

  vim.keymap.set('n', '<Esc>', function()
    M.close_window(channel)
  end, vim.tbl_extend('force', opts, { desc = 'Close window' }))

  -- Navigation
  vim.keymap.set('n', '<C-u>', '<C-u>', opts)
  vim.keymap.set('n', '<C-d>', '<C-d>', opts)
end

---Create input window for typing messages
---@param channel string
---@return number winid
function M.create_input_window(channel)
  -- Create input buffer
  local input_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(input_bufnr, 'buftype', 'prompt')
  vim.api.nvim_buf_set_option(input_bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_name(input_bufnr, 'twitch-chat-input://' .. channel)

  -- Set prompt
  vim.fn.prompt_setprompt(input_bufnr, channel .. '> ')

  -- Calculate input window position (below chat window)
  local chat_winid = state.windows[channel]
  local input_height = 3

  local win_config
  if state.layout_type == 'float' and chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
    local chat_config = vim.api.nvim_win_get_config(chat_winid)
    win_config = {
      width = chat_config.width,
      height = input_height,
      row = chat_config.row + chat_config.height,
      col = chat_config.col,
      relative = 'editor',
      border = 'rounded',
      title = 'Input - ' .. channel,
      title_pos = 'center',
      style = 'minimal',
      focusable = true,
      zindex = 51,
    }
  else
    -- Fallback to bottom split
    win_config = {
      width = vim.o.columns,
      height = input_height,
      row = vim.o.lines - input_height - 2,
      col = 0,
      relative = 'editor',
      border = 'rounded',
      title = 'Input - ' .. channel,
      title_pos = 'center',
      style = 'minimal',
      focusable = true,
      zindex = 51,
    }
  end

  local input_winid = vim.api.nvim_open_win(input_bufnr, true, win_config)

  -- Set common window options
  M.set_common_window_options(input_winid, 'input')

  -- Setup input handling
  vim.fn.prompt_setcallback(input_bufnr, function(text)
    if text and text ~= '' then
      -- Emit send message event
      local events = require('twitch-chat.events')
      if events then
        events.emit('send_message', { channel = channel, content = text })
      end
    end

    -- Clear input
    vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { '' })
    vim.fn.prompt_setprompt(input_bufnr, channel .. '> ')
  end)

  -- Setup escape to close
  vim.keymap.set('i', '<Esc>', function()
    if vim.api.nvim_win_is_valid(input_winid) then
      vim.api.nvim_win_close(input_winid, true)
    end
    state.input_winid = nil
    state.input_bufnr = nil
  end, { buffer = input_bufnr })

  -- Enter insert mode
  vim.cmd('startinsert')

  -- Update state
  state.input_winid = input_winid
  state.input_bufnr = input_bufnr

  return input_winid
end

---Quick input using vim.ui.input
---@param channel string
function M.quick_input(channel)
  vim.ui.input({
    prompt = channel .. '> ',
    default = '',
  }, function(input)
    if input and input ~= '' then
      -- Emit send message event
      local events = require('twitch-chat.events')
      if events then
        events.emit('send_message', { channel = channel, content = input })
      end
    end
  end)
end

---Toggle input window
function M.toggle_input_window()
  if not state.current_channel then
    logger.warn('No active chat channel', { function_name = 'toggle_input_window', module = 'ui' })
    return
  end

  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_win_close(state.input_winid, true)
    state.input_winid = nil
    state.input_bufnr = nil
  else
    M.create_input_window(state.current_channel)
  end
end

---Focus input window
---@param channel string?
function M.focus_input_window(channel)
  channel = channel or state.current_channel
  if not channel then
    logger.warn('No active chat channel', { function_name = 'focus_input_window', module = 'ui' })
    return
  end

  if not state.input_winid or not vim.api.nvim_win_is_valid(state.input_winid) then
    M.create_input_window(channel)
  else
    vim.api.nvim_set_current_win(state.input_winid)
    vim.cmd('startinsert')
  end
end

---Focus chat window
function M.focus_chat_window()
  if not state.current_channel then
    logger.warn('No active chat channel', { function_name = 'focus_chat_window', module = 'ui' })
    return
  end

  local winid = state.windows[state.current_channel]
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
  end
end

---Switch channel using selection
function M.switch_channel()
  local buffer = require('twitch-chat.modules.buffer')
  local buffers = buffer.get_all_buffers()

  local channels = {}
  for channel, _ in pairs(buffers) do
    table.insert(channels, channel)
  end

  if #channels == 0 then
    logger.info('No channels available', { function_name = 'switch_channel', module = 'ui' })
    return
  end

  vim.ui.select(channels, {
    prompt = 'Select channel: ',
    format_item = function(channel)
      local is_active = state.current_channel == channel and '● ' or '○ '
      return is_active .. channel
    end,
  }, function(choice)
    if choice and choice ~= state.current_channel then
      M.show_buffer(choice, state.layout_type)
    end
  end)
end

---Toggle layout for current channel
---@param channel string?
function M.toggle_layout(channel)
  channel = channel or state.current_channel
  if not channel then
    logger.warn('No active chat channel', { function_name = 'toggle_layout', module = 'ui' })
    return
  end

  local layouts = { 'float', 'vsplit', 'split', 'tab' }
  local current_index = 1

  for i, layout in ipairs(layouts) do
    if layout == state.layout_type then
      current_index = i
      break
    end
  end

  local next_index = (current_index % #layouts) + 1
  local next_layout = layouts[next_index]

  state.layout_type = next_layout
  M.show_buffer(channel, next_layout)

  logger.info(
    'Layout changed',
    { previous_layout = layout_type, new_layout = next_layout, channel = channel, module = 'ui' }
  )
end

---Cycle through available layouts
function M.cycle_layout()
  M.toggle_layout()
end

---Resize windows based on current vim dimensions
function M.resize_windows()
  for channel, winid in pairs(state.windows) do
    if vim.api.nvim_win_is_valid(winid) then
      local config = vim.api.nvim_win_get_config(winid)
      if config.relative == 'editor' then
        -- Recalculate floating window dimensions
        local float_config = default_config.ui.float
        local width = math.floor(vim.o.columns * float_config.width)
        local height = math.floor(vim.o.lines * float_config.height)
        local row = math.floor(vim.o.lines * float_config.row)
        local col = math.floor(vim.o.columns * float_config.col)

        config.width = width
        config.height = height
        config.row = row
        config.col = col

        vim.api.nvim_win_set_config(winid, config)
      end
    end
  end
end

---Close all chat windows
function M.close_all_windows()
  -- Close input window
  if state.input_winid and vim.api.nvim_win_is_valid(state.input_winid) then
    vim.api.nvim_win_close(state.input_winid, true)
  end

  -- Close chat windows
  for channel, winid in pairs(state.windows) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  -- Reset state
  state.windows = {}
  state.current_channel = nil
  state.input_winid = nil
  state.input_bufnr = nil
end

---Close window for specific channel and cleanup
---@param channel string
function M.close_window(channel)
  local winid = state.windows[channel]
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end

  -- Update UI state
  state.windows[channel] = nil

  -- Update buffer state to reflect window closure
  local buffer = require('twitch-chat.modules.buffer')
  local chat_buffer = buffer.get_chat_buffer(channel)
  if chat_buffer then
    chat_buffer.winid = nil
  end

  if state.current_channel == channel then
    -- Find another active channel
    local next_channel = next(state.windows)
    state.current_channel = next_channel

    if not next_channel then
      logger.info('All chat windows closed', { module = 'ui' })
    end
  end
end

---Get UI state information
---@return table
function M.get_state()
  return {
    windows = vim.tbl_map(function(winid)
      return {
        winid = winid,
        valid = vim.api.nvim_win_is_valid(winid),
        config = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid) or nil,
      }
    end, state.windows),
    layout_type = state.layout_type,
    current_channel = state.current_channel,
    input_window = state.input_winid and {
      winid = state.input_winid,
      valid = vim.api.nvim_win_is_valid(state.input_winid),
      bufnr = state.input_bufnr,
    } or nil,
  }
end

---Set layout type
---@param layout_type string
function M.set_layout_type(layout_type)
  local valid_layouts = { 'float', 'split', 'vsplit', 'tab' }
  if vim.tbl_contains(valid_layouts, layout_type) then
    state.layout_type = layout_type
  else
    logger.error('Invalid layout type', { layout_type = layout_type, module = 'ui' })
  end
end

---Get current layout type
---@return string
function M.get_layout_type()
  return state.layout_type
end

---Check if a channel window is visible
---@param channel string
---@return boolean
function M.is_channel_visible(channel)
  local winid = state.windows[channel]
  return winid and vim.api.nvim_win_is_valid(winid) or false
end

---Get window ID for a channel
---@param channel string
---@return number?
function M.get_window_id(channel)
  local winid = state.windows[channel]
  return winid and vim.api.nvim_win_is_valid(winid) and winid or nil
end

---Listen for events from other modules
local function setup_event_listeners()
  -- Try to get events module, but don't fail if it doesn't exist yet
  local ok, events = pcall(require, 'twitch-chat.events')
  if ok and events then
    -- Listen for channel joins to show buffer
    events.on('channel_joined', function(data)
      if data.channel then
        vim.schedule(function()
          M.show_buffer(data.channel)
        end)
      end
    end)

    -- Listen for channel parts to close windows
    events.on('channel_left', function(data)
      if data.channel then
        vim.schedule(function()
          M.close_window(data.channel)
        end)
      end
    end)
  end
end

-- Initialize event listeners
setup_event_listeners()

return M
