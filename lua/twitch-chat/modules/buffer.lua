---@class TwitchChatBuffer
---Buffer management for Twitch chat display
local M = {}
local uv = vim.uv or vim.loop
local utils = require('twitch-chat.utils')

-- TwitchMessage class is defined in api.lua

---@class ChatBuffer
---@field bufnr number
---@field winid number?
---@field channel string
---@field messages TwitchMessage[]
---@field max_messages number
---@field auto_scroll boolean
---@field last_update number
---@field pending_updates TwitchMessage[]
---@field update_timer any?
---@field namespace_id number
---@field virtual_text_enabled boolean
---@field virtualization VirtualizationState
---@field message_cache MessageCache

---@class VirtualizationState
---@field enabled boolean Whether virtualization is enabled
---@field window_size number Number of messages to keep in buffer
---@field total_messages number Total number of messages received
---@field visible_start number Index of first visible message
---@field visible_end number Index of last visible message
---@field scroll_position number Current scroll position (0-1)

---@class MessageCache
---@field compressed_messages table[] Compressed message storage
---@field index_map table<number, number> Map from message index to cache index
---@field memory_usage number Estimated memory usage in bytes
---@field hash_map table<string, number> Map from message hash to cache index for deduplication
---@field duplicate_count number Number of duplicates detected and skipped

---@type table<string, ChatBuffer>
local buffers = {}

---@type number
local update_interval = 16 -- 16ms for ~60fps updates

---@type number
local batch_size = 50 -- Process up to 50 messages per update

-- Virtualization configuration
local VIRTUALIZATION_CONFIG = {
  enabled = true, -- Enable message virtualization
  threshold = 1000, -- Start virtualizing after this many messages
  window_size = 200, -- Number of messages to keep visible
  cache_compression = true, -- Compress cached messages
  memory_limit = 50 * 1024 * 1024, -- 50MB memory limit
  gc_interval = 30000, -- Garbage collection interval (ms)
}

-- Create namespace for virtual text and highlights
local namespace_id = vim.api.nvim_create_namespace('twitch_chat_highlights')

-- Default configuration (will be overridden by actual config)
local default_config = {
  ui = {
    timestamp_format = '[%H:%M:%S]',
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
  },
}

---Initialize the buffer module
---@param config table?
function M.setup(config)
  if config then
    default_config = vim.tbl_deep_extend('force', default_config, config)
  end

  -- Setup autocmds for buffer management
  local group = vim.api.nvim_create_augroup('TwitchChatBuffer', { clear = true })

  -- Cleanup when buffer is deleted
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    pattern = 'twitch-chat://*',
    callback = function(args)
      local bufnr = args.buf
      for channel, buffer in pairs(buffers) do
        if buffer.bufnr == bufnr then
          M.cleanup_buffer(channel)
          break
        end
      end
    end,
  })

  -- Handle window close
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local winid = tonumber(args.match)
      if winid then
        for channel, buffer in pairs(buffers) do
          if buffer.winid == winid then
            buffer.winid = nil
            break
          end
        end
      end
    end,
  })
end

---Create a new chat buffer for a channel
---@param channel string
---@return ChatBuffer
---Create a new buffer (alias for create_chat_buffer)
---@param channel string
---@return ChatBuffer?
function M.create_buffer(channel)
  return M.create_chat_buffer(channel)
end

function M.create_chat_buffer(channel)
  -- Clean up existing buffer if it exists
  if buffers[channel] then
    M.cleanup_buffer(channel)
  end

  -- Also check for any existing buffer with the same name in Neovim and clean it up
  local buffer_name = 'twitch-chat://' .. channel
  local existing_bufnr = vim.fn.bufnr(buffer_name)
  if existing_bufnr ~= -1 and vim.api.nvim_buf_is_valid(existing_bufnr) then
    vim.api.nvim_buf_delete(existing_bufnr, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(bufnr, 'filetype', 'twitch-chat')
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)

  -- Set buffer name
  vim.api.nvim_buf_set_name(bufnr, buffer_name)

  ---@type ChatBuffer
  local buffer = {
    bufnr = bufnr,
    winid = nil,
    channel = channel,
    messages = {},
    max_messages = default_config.ui.max_messages,
    auto_scroll = default_config.ui.auto_scroll,
    last_update = 0,
    pending_updates = {},
    update_timer = nil,
    namespace_id = namespace_id,
    virtual_text_enabled = default_config.ui.virtual_text_enabled,
    virtualization = {
      enabled = VIRTUALIZATION_CONFIG.enabled,
      window_size = VIRTUALIZATION_CONFIG.window_size,
      total_messages = 0,
      visible_start = 1,
      visible_end = 0,
      scroll_position = 1.0,
    },
    message_cache = {
      compressed_messages = {},
      index_map = {},
      memory_usage = 0,
      hash_map = {},
      duplicate_count = 0,
    },
  }

  buffers[channel] = buffer

  -- Setup buffer keymaps
  M.setup_keymaps(buffer)

  -- Setup syntax highlighting
  M.setup_syntax(buffer)

  -- Start garbage collection timer for virtualization
  if buffer.virtualization.enabled then
    M._start_gc_timer(buffer)
  end

  return buffer
end

---Get existing chat buffer for a channel
---@param channel string
---@return ChatBuffer?
function M.get_chat_buffer(channel)
  return buffers[channel]
end

---Get all chat buffers
---@return table<string, ChatBuffer>
function M.get_all_buffers()
  return buffers
end

---Add a message to the buffer with deduplication and batching for performance
---@param channel string
---@param message TwitchMessage
function M.add_message(channel, message)
  local buffer = buffers[channel]
  if not buffer then
    return
  end

  -- Check for duplicates first
  local is_duplicate, hash = M._is_duplicate_message(buffer, message)
  if is_duplicate then
    -- Log duplicate detection for debugging
    local logger = require('twitch-chat.modules.logger')
    logger.debug('Duplicate message detected and skipped', {
      channel = channel,
      username = message.username,
      content_preview = string.sub(message.content or '', 1, 50),
      hash = hash,
      duplicate_count = buffer.message_cache.duplicate_count,
    }, { notify = false, category = 'debug_info' })
    return
  end

  -- Add to cache for virtualization (includes deduplication tracking)
  if buffer.virtualization.enabled then
    M._add_to_cache(buffer, message, hash)
  end

  -- Add to pending updates for batch processing
  table.insert(buffer.pending_updates, message)

  -- Schedule update if not already scheduled
  if not buffer.update_timer then
    buffer.update_timer = vim.defer_fn(function()
      M.process_pending_updates(channel)
    end, update_interval)
  end
end

---Process pending message updates in batches
---@param channel string
function M.process_pending_updates(channel)
  local buffer = buffers[channel]
  if not buffer then
    return
  end

  -- Clear the timer
  buffer.update_timer = nil

  -- Process messages in batches
  local processed = 0
  while #buffer.pending_updates > 0 and processed < batch_size do
    local message = table.remove(buffer.pending_updates, 1)
    table.insert(buffer.messages, message)
    processed = processed + 1
  end

  -- Limit message history
  while #buffer.messages > buffer.max_messages do
    table.remove(buffer.messages, 1)
  end

  -- Update buffer content
  M.update_buffer_content(buffer)

  -- Schedule next update if there are more pending messages
  if #buffer.pending_updates > 0 then
    buffer.update_timer = vim.defer_fn(function()
      M.process_pending_updates(channel)
    end, update_interval)
  end
end

---Update the buffer content with all messages using display module
---@param buffer ChatBuffer
function M.update_buffer_content(buffer)
  -- Check if buffer is still valid
  if not buffer or not buffer.bufnr or not vim.api.nvim_buf_is_valid(buffer.bufnr) then
    return
  end

  local start_time = uv.hrtime()

  -- Use the formatter and display modules for consistent rendering
  local formatter = require('twitch-chat.modules.formatter')
  local display = require('twitch-chat.modules.display')

  -- Format all messages
  local formatted_messages = {}
  for i, message in ipairs(buffer.messages) do
    local formatted_message = formatter.format_message(message, {
      include_timestamp = true,
      detect_mentions = true,
      detect_commands = true,
      detect_emotes = true,
      detect_urls = true,
    })
    table.insert(formatted_messages, formatted_message)
  end

  -- Render all messages using display module
  local render_context = {
    bufnr = buffer.bufnr,
    winid = buffer.winid,
    namespace_id = buffer.namespace_id,
    start_line = 0,
    end_line = #formatted_messages,
  }

  local render_success = display.render_messages(formatted_messages, render_context, {
    virtual_text_enabled = buffer.virtual_text_enabled,
  })

  if not render_success then
    utils.log(vim.log.levels.ERROR, 'Failed to render messages for channel: ' .. buffer.channel)
    return
  end

  -- Auto-scroll to bottom
  if buffer.auto_scroll and buffer.winid and vim.api.nvim_win_is_valid(buffer.winid) then
    local line_count = vim.api.nvim_buf_line_count(buffer.bufnr)
    if line_count > 0 then
      vim.api.nvim_win_set_cursor(buffer.winid, { line_count, 0 })
    end
  end

  -- Update performance tracking
  buffer.last_update = uv.hrtime() - start_time
end

---Format a message for display using the formatter module
---@param message TwitchMessage
---@param line_number number
---@return string formatted_line
---@return table highlights
function M.format_message(message, line_number)
  -- Use the dedicated formatter module for consistent formatting
  local formatter = require('twitch-chat.modules.formatter')

  -- Format the message using the formatter module
  local formatted_message = formatter.format_message(message, {
    include_timestamp = true,
    detect_mentions = true,
    detect_commands = true,
    detect_emotes = true,
    detect_urls = true,
  })

  -- Get highlights for display
  local highlights = formatter.get_highlights(formatted_message, default_config.ui.highlights)

  return formatted_message.formatted_line, highlights
end

---Setup syntax highlighting for the buffer (delegates to display module)
---@param buffer ChatBuffer
function M.setup_syntax(buffer)
  -- Delegate syntax highlighting setup to the display module
  local display = require('twitch-chat.modules.display')

  -- The display module handles all highlight group setup
  -- This function is kept for compatibility but delegates the work
  display.setup()
end

---Setup basic buffer keymaps (UI module handles window-specific keymaps)
---@param buffer ChatBuffer
function M.setup_keymaps(buffer)
  local opts = { noremap = true, silent = true, buffer = buffer.bufnr }

  -- Buffer-specific keymaps only
  vim.keymap.set('n', 'K', function()
    M.toggle_auto_scroll(buffer.channel)
  end, vim.tbl_extend('force', opts, { desc = 'Toggle auto-scroll' }))

  vim.keymap.set('n', 'C', function()
    M.clear_buffer(buffer.channel)
  end, vim.tbl_extend('force', opts, { desc = 'Clear buffer' }))
end

---Trigger input for sending messages (delegates to UI module)
---@param channel string
function M.open_input_buffer(channel)
  -- Delegate to UI module for consistent input handling
  local ui = require('twitch-chat.modules.ui')
  if ui and ui.quick_input then
    ui.quick_input(channel)
  else
    -- Fallback to simple input
    vim.ui.input({
      prompt = 'Message for ' .. channel .. ': ',
      default = '',
    }, function(input)
      if input and input ~= '' then
        local events = require('twitch-chat.events')
        if events then
          events.emit('send_message', { channel = channel, content = input })
        end
      end
    end)
  end
end

---Close a chat buffer (delegates window management to UI module)
---@param channel string
function M.close_buffer(channel)
  local buffer = buffers[channel]
  if buffer then
    -- Delegate window closing to UI module
    local ui = require('twitch-chat.modules.ui')
    if ui and ui.close_window then
      ui.close_window(channel)
    else
      -- Fallback: just close window if valid
      if buffer.winid and vim.api.nvim_win_is_valid(buffer.winid) then
        vim.api.nvim_win_close(buffer.winid, true)
      end
    end

    -- Buffer cleanup is still handled here
    if vim.api.nvim_buf_is_valid(buffer.bufnr) then
      vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
    end
  end
end

---Switch channel prompt (delegates to UI module)
function M.switch_channel_prompt()
  -- Delegate to UI module for consistent channel switching
  local ui = require('twitch-chat.modules.ui')
  if ui and ui.switch_channel then
    ui.switch_channel()
  else
    -- Fallback implementation
    local channels = {}
    for channel, _ in pairs(buffers) do
      table.insert(channels, channel)
    end

    if #channels == 0 then
      vim.notify('No channels available', vim.log.levels.INFO)
      return
    end

    vim.ui.select(channels, {
      prompt = 'Select channel: ',
      format_item = function(channel)
        return channel
      end,
    }, function(choice)
      if choice then
        local ui_mod = require('twitch-chat.modules.ui')
        if ui_mod then
          ui_mod.show_buffer(choice)
        end
      end
    end)
  end
end

---Toggle auto-scroll for a buffer
---@param channel string
function M.toggle_auto_scroll(channel)
  local buffer = buffers[channel]
  if buffer then
    buffer.auto_scroll = not buffer.auto_scroll
    local status = buffer.auto_scroll and 'enabled' or 'disabled'
    vim.notify('Auto-scroll ' .. status .. ' for ' .. channel, vim.log.levels.INFO)
  end
end

---Clear all messages from a buffer
---@param channel string
function M.clear_buffer(channel)
  local buffer = buffers[channel]
  if buffer then
    buffer.messages = {}
    buffer.pending_updates = {}
    M.update_buffer_content(buffer)
    vim.notify('Buffer cleared for ' .. channel, vim.log.levels.INFO)
  end
end

---Cleanup a buffer and its resources
---@param channel string
function M.cleanup_buffer(channel)
  local buffer = buffers[channel]
  if buffer then
    -- Cancel any pending updates
    if buffer.update_timer then
      -- vim.defer_fn returns a timer ID, not an object with stop method
      -- The timer will be cancelled when the function completes anyway
      buffer.update_timer = nil
    end

    -- Clear highlights
    if vim.api.nvim_buf_is_valid(buffer.bufnr) then
      vim.api.nvim_buf_clear_namespace(buffer.bufnr, buffer.namespace_id, 0, -1)
      -- Delete the buffer from Neovim
      vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
    end

    -- Remove from buffers table
    buffers[channel] = nil
  end
end

---Get buffer statistics with deduplication and compression info
---@param channel string
---@return table?
function M.get_buffer_stats(channel)
  local buffer = buffers[channel]
  if not buffer then
    return nil
  end

  local memory_usage_mb = buffer.message_cache.memory_usage / (1024 * 1024)
  local compression_ratio = 0
  if buffer.virtualization.total_messages > 0 then
    compression_ratio = #buffer.message_cache.compressed_messages
      / buffer.virtualization.total_messages
  end

  return {
    channel = channel,
    message_count = #buffer.messages,
    pending_count = #buffer.pending_updates,
    last_update_time = buffer.last_update / 1000000, -- Convert to milliseconds
    auto_scroll = buffer.auto_scroll,
    buffer_number = buffer.bufnr,
    window_id = buffer.winid,
    -- Virtualization and compression stats
    virtualization_enabled = buffer.virtualization.enabled,
    total_messages_received = buffer.virtualization.total_messages,
    cached_messages = #buffer.message_cache.compressed_messages,
    memory_usage_mb = memory_usage_mb,
    compression_ratio = compression_ratio,
    -- Deduplication stats
    duplicate_count = buffer.message_cache.duplicate_count,
    hash_map_size = utils.table_length(buffer.message_cache.hash_map),
    deduplication_rate = buffer.virtualization.total_messages > 0
        and (buffer.message_cache.duplicate_count / (buffer.virtualization.total_messages + buffer.message_cache.duplicate_count))
      or 0,
  }
end

---Get performance statistics for all buffers with deduplication metrics
---@return table
function M.get_performance_stats()
  local stats = {
    total_buffers = 0,
    total_messages = 0,
    total_pending = 0,
    average_update_time = 0,
    -- Memory and compression stats
    total_memory_usage_mb = 0,
    total_cached_messages = 0,
    total_messages_received = 0,
    average_compression_ratio = 0,
    -- Deduplication stats
    total_duplicates_detected = 0,
    average_deduplication_rate = 0,
    total_hash_map_entries = 0,
  }

  local update_times = {}
  local compression_ratios = {}
  local deduplication_rates = {}

  for channel, buffer in pairs(buffers) do
    stats.total_buffers = stats.total_buffers + 1
    stats.total_messages = stats.total_messages + #buffer.messages
    stats.total_pending = stats.total_pending + #buffer.pending_updates

    -- Memory and compression metrics
    stats.total_memory_usage_mb = stats.total_memory_usage_mb
      + (buffer.message_cache.memory_usage / (1024 * 1024))
    stats.total_cached_messages = stats.total_cached_messages
      + #buffer.message_cache.compressed_messages
    stats.total_messages_received = stats.total_messages_received
      + buffer.virtualization.total_messages

    -- Deduplication metrics
    stats.total_duplicates_detected = stats.total_duplicates_detected
      + buffer.message_cache.duplicate_count
    stats.total_hash_map_entries = stats.total_hash_map_entries
      + utils.table_length(buffer.message_cache.hash_map)

    if buffer.last_update > 0 then
      table.insert(update_times, buffer.last_update / 1000000)
    end

    if buffer.virtualization.total_messages > 0 then
      local compression_ratio = #buffer.message_cache.compressed_messages
        / buffer.virtualization.total_messages
      table.insert(compression_ratios, compression_ratio)

      local total_potential = buffer.virtualization.total_messages
        + buffer.message_cache.duplicate_count
      if total_potential > 0 then
        local dedup_rate = buffer.message_cache.duplicate_count / total_potential
        table.insert(deduplication_rates, dedup_rate)
      end
    end
  end

  -- Calculate averages
  if #update_times > 0 then
    local sum = 0
    for _, time in ipairs(update_times) do
      sum = sum + time
    end
    stats.average_update_time = sum / #update_times
  end

  if #compression_ratios > 0 then
    local sum = 0
    for _, ratio in ipairs(compression_ratios) do
      sum = sum + ratio
    end
    stats.average_compression_ratio = sum / #compression_ratios
  end

  if #deduplication_rates > 0 then
    local sum = 0
    for _, rate in ipairs(deduplication_rates) do
      sum = sum + rate
    end
    stats.average_deduplication_rate = sum / #deduplication_rates
  end

  return stats
end

---Listen for events from other modules
local function setup_event_listeners()
  -- Try to get events module, but don't fail if it doesn't exist yet
  local ok, events = pcall(require, 'twitch-chat.events')
  if ok and events then
    -- Listen for incoming messages
    events.on('message_received', function(data)
      if data.channel and data.message then
        M.add_message(data.channel, data.message)
      end
    end)

    -- Listen for channel joins
    events.on('channel_joined', function(data)
      if data.channel then
        M.create_chat_buffer(data.channel)
      end
    end)

    -- Listen for channel parts
    events.on('channel_left', function(data)
      if data.channel then
        M.cleanup_buffer(data.channel)
      end
    end)
  end
end

-- Message Virtualization and Deduplication Functions

---Generate a hash for message deduplication
---@param message table Message to hash
---@return string hash
function M._generate_message_hash(message)
  -- Create hash based on content, username, and timestamp (within 1 second window)
  local timestamp_window = math.floor((message.timestamp or os.time()) / 1)
  local hash_content =
    string.format('%s:%s:%d', message.username or '', message.content or '', timestamp_window)

  -- Simple hash function (could be improved with a proper hash algorithm)
  local hash = 0
  for i = 1, #hash_content do
    hash = ((hash * 31) + string.byte(hash_content, i)) % 2147483647
  end

  return tostring(hash)
end

---Check if message is a duplicate
---@param buffer ChatBuffer
---@param message table Message to check
---@return boolean is_duplicate
---@return string hash
function M._is_duplicate_message(buffer, message)
  local hash = M._generate_message_hash(message)
  local existing_index = buffer.message_cache.hash_map[hash]

  if existing_index then
    -- Found duplicate, update duplicate count
    buffer.message_cache.duplicate_count = buffer.message_cache.duplicate_count + 1
    return true, hash
  end

  return false, hash
end

---Enhanced compression with better memory efficiency
---@param message table Message to compress
---@return table compressed_message
function M._compress_message(message)
  local compressed = {
    u = message.username, -- username (compressed key)
    c = message.content, -- content
    t = message.timestamp, -- timestamp
  }

  -- Only store non-empty/non-default values to save memory
  if message.badges and #message.badges > 0 then
    compressed.b = message.badges
  end

  if message.emotes and #message.emotes > 0 then
    compressed.e = message.emotes
  end

  if message.user_color and message.user_color ~= '' then
    compressed.col = message.user_color
  end

  -- Use bit flags for boolean values to save space
  local flags = 0
  if message.is_mod then
    flags = flags + 1
  end
  if message.is_vip then
    flags = flags + 2
  end
  if message.is_subscriber then
    flags = flags + 4
  end
  if message.is_self then
    flags = flags + 8
  end

  if flags > 0 then
    compressed.f = flags
  end

  return compressed
end

---Decompress a message from storage
---@param compressed table Compressed message
---@return table message
function M._decompress_message(compressed)
  local message = {
    username = compressed.u,
    content = compressed.c,
    timestamp = compressed.t,
    badges = compressed.b or {},
    emotes = compressed.e or {},
    user_color = compressed.col,
  }

  -- Decode bit flags for boolean values
  local flags = compressed.f or 0
  message.is_mod = (flags & 1) ~= 0
  message.is_vip = (flags & 2) ~= 0
  message.is_subscriber = (flags & 4) ~= 0
  message.is_self = (flags & 8) ~= 0

  return message
end

---Check if buffer should be virtualized
---@param buffer ChatBuffer
---@return boolean should_virtualize
function M._should_virtualize(buffer)
  return buffer.virtualization.enabled
    and buffer.virtualization.total_messages > VIRTUALIZATION_CONFIG.threshold
end

---Add message to cache and manage virtualization with deduplication tracking
---@param buffer ChatBuffer
---@param message table
---@param hash string? Pre-computed hash for deduplication
function M._add_to_cache(buffer, message, hash)
  buffer.virtualization.total_messages = buffer.virtualization.total_messages + 1

  local compressed_message
  local message_size

  if VIRTUALIZATION_CONFIG.cache_compression then
    compressed_message = M._compress_message(message)

    -- More accurate memory usage calculation
    local json_str = vim.json.encode(compressed_message)
    message_size = string.len(json_str)
    buffer.message_cache.memory_usage = buffer.message_cache.memory_usage + message_size
  else
    compressed_message = message
    -- Rough estimate for uncompressed message
    message_size = string.len(vim.json.encode(message))
    buffer.message_cache.memory_usage = buffer.message_cache.memory_usage + message_size
  end

  table.insert(buffer.message_cache.compressed_messages, compressed_message)

  -- Update index map
  local cache_index = #buffer.message_cache.compressed_messages
  buffer.message_cache.index_map[buffer.virtualization.total_messages] = cache_index

  -- Update hash map for deduplication
  if not hash then
    hash = M._generate_message_hash(message)
  end
  buffer.message_cache.hash_map[hash] = cache_index

  -- Clean up old hashes to prevent memory bloat
  if #buffer.message_cache.compressed_messages % 100 == 0 then
    M._cleanup_old_hashes(buffer)
  end
end

---Get message from cache by index
---@param buffer ChatBuffer
---@param index number Global message index
---@return table? message
function M._get_from_cache(buffer, index)
  local cache_index = buffer.message_cache.index_map[index]
  if not cache_index then
    return nil
  end

  local cached = buffer.message_cache.compressed_messages[cache_index]
  if not cached then
    return nil
  end

  if VIRTUALIZATION_CONFIG.cache_compression then
    return M._decompress_message(cached)
  else
    return cached
  end
end

---Update visible window based on scroll position
---@param buffer ChatBuffer
function M._update_visible_window(buffer)
  if not M._should_virtualize(buffer) then
    return
  end

  local total = buffer.virtualization.total_messages
  local window_size = buffer.virtualization.window_size

  -- Calculate visible range based on scroll position
  local scroll_pos = buffer.virtualization.scroll_position
  local window_end = math.ceil(total * scroll_pos)
  local window_start = math.max(1, window_end - window_size + 1)

  -- Ensure we don't exceed bounds
  window_end = math.min(total, window_end)
  window_start = math.max(1, window_start)

  buffer.virtualization.visible_start = window_start
  buffer.virtualization.visible_end = window_end

  -- Update buffer content if range changed
  M._refresh_buffer_content(buffer)
end

---Refresh buffer content with visible messages
---@param buffer ChatBuffer
function M._refresh_buffer_content(buffer)
  if not M._should_virtualize(buffer) then
    return
  end

  local lines = {}
  local visible_start = buffer.virtualization.visible_start
  local visible_end = buffer.virtualization.visible_end

  -- Load visible messages from cache
  for i = visible_start, visible_end do
    local message = M._get_from_cache(buffer, i)
    if message then
      local formatted = M.format_message(message)
      table.insert(lines, formatted)
    end
  end

  -- Update buffer content
  vim.api.nvim_buf_set_option(buffer.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buffer.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buffer.bufnr, 'modifiable', false)
end

---Start garbage collection timer
---@param buffer ChatBuffer
function M._start_gc_timer(buffer)
  local timer = uv.new_timer()
  timer:start(VIRTUALIZATION_CONFIG.gc_interval, VIRTUALIZATION_CONFIG.gc_interval, function()
    vim.schedule(function()
      M._garbage_collect(buffer)
    end)
  end)
  buffer.gc_timer = timer
end

---Clean up old hashes to prevent memory bloat
---@param buffer ChatBuffer
function M._cleanup_old_hashes(buffer)
  local hash_count = 0
  for _ in pairs(buffer.message_cache.hash_map) do
    hash_count = hash_count + 1
  end

  -- If we have more than 2x the number of messages, clean up old hashes
  if hash_count > #buffer.message_cache.compressed_messages * 2 then
    local valid_indices = {}
    for i = 1, #buffer.message_cache.compressed_messages do
      valid_indices[i] = true
    end

    -- Rebuild hash map with only valid indices
    local new_hash_map = {}
    for hash, cache_index in pairs(buffer.message_cache.hash_map) do
      if valid_indices[cache_index] then
        new_hash_map[hash] = cache_index
      end
    end

    buffer.message_cache.hash_map = new_hash_map
  end
end

---Perform garbage collection on message cache with deduplication cleanup
---@param buffer ChatBuffer
function M._garbage_collect(buffer)
  if buffer.message_cache.memory_usage < VIRTUALIZATION_CONFIG.memory_limit then
    return
  end

  -- Remove oldest messages beyond cache limit
  local target_size = VIRTUALIZATION_CONFIG.memory_limit * 0.8 -- Keep 80% after GC
  local removed = 0

  while
    buffer.message_cache.memory_usage > target_size
    and #buffer.message_cache.compressed_messages > 0
  do
    table.remove(buffer.message_cache.compressed_messages, 1)
    removed = removed + 1
  end

  if removed > 0 then
    -- Rebuild index map
    buffer.message_cache.index_map = {}
    for i, _ in ipairs(buffer.message_cache.compressed_messages) do
      local global_index = buffer.virtualization.total_messages
        - #buffer.message_cache.compressed_messages
        + i
      buffer.message_cache.index_map[global_index] = i
    end

    -- Clean up hash map - rebuild with only valid indices
    local new_hash_map = {}
    for hash, cache_index in pairs(buffer.message_cache.hash_map) do
      -- Adjust cache index after removal
      local new_cache_index = cache_index - removed
      if new_cache_index > 0 and new_cache_index <= #buffer.message_cache.compressed_messages then
        new_hash_map[hash] = new_cache_index
      end
    end
    buffer.message_cache.hash_map = new_hash_map

    -- Recalculate memory usage
    buffer.message_cache.memory_usage = buffer.message_cache.memory_usage * 0.8

    local logger = require('twitch-chat.modules.logger')
    logger.debug('Message cache garbage collection completed', {
      channel = buffer.channel,
      messages_removed = removed,
      remaining_messages = #buffer.message_cache.compressed_messages,
      memory_usage_mb = buffer.message_cache.memory_usage / (1024 * 1024),
      duplicate_count = buffer.message_cache.duplicate_count,
      hash_map_size = utils.table_length(buffer.message_cache.hash_map),
    }, { notify = false, category = 'performance' })
  end
end

-- Initialize event listeners
setup_event_listeners()

return M
