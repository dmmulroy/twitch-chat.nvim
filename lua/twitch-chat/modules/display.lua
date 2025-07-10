---@class TwitchChatDisplay
---Display and rendering logic separated from formatting concerns
local M = {}

---@class DisplayConfig
---@field highlight_groups table<string, string> Custom highlight group mappings
---@field virtual_text_enabled boolean Enable virtual text rendering
---@field emote_rendering_mode string Emote rendering mode ('virtual_text', 'unicode', 'text')
---@field animation_enabled boolean Enable animated rendering
---@field line_wrapping boolean Enable intelligent line wrapping
---@field max_line_length number Maximum line length before wrapping
---@field syntax_highlighting boolean Enable syntax highlighting

---@class RenderContext
---@field bufnr number Buffer number
---@field winid number? Window ID
---@field namespace_id number Namespace for highlights
---@field start_line number Starting line number
---@field end_line number Ending line number

local config = require('twitch-chat.config')
local formatter = require('twitch-chat.modules.formatter')
local utils = require('twitch-chat.utils')

---@type DisplayConfig
local default_config = {
  highlight_groups = {},
  virtual_text_enabled = true,
  emote_rendering_mode = 'virtual_text',
  animation_enabled = false,
  line_wrapping = true,
  max_line_length = 120,
  syntax_highlighting = true,
}

-- Create namespace for display highlights
local display_namespace = vim.api.nvim_create_namespace('twitch_chat_display')

---Initialize the display module
---@param user_config DisplayConfig?
---@return boolean success
function M.setup(user_config)
  if user_config then
    default_config = utils.deep_merge(default_config, user_config)
  end

  -- Setup default highlight groups
  M._setup_highlight_groups()

  return true
end

---Render a formatted message to a buffer
---@param formatted_message table Formatted message from formatter module
---@param context RenderContext Rendering context
---@param options table? Rendering options
---@return boolean success
function M.render_message(formatted_message, context, options)
  vim.validate({
    formatted_message = { formatted_message, 'table' },
    context = { context, 'table' },
    options = { options, 'table', true },
  })

  options = options or {}

  -- Ensure buffer is valid
  if not vim.api.nvim_buf_is_valid(context.bufnr) then
    return false
  end

  -- Prepare line content
  local line_content = formatted_message.formatted_line

  -- Handle line wrapping if enabled
  if default_config.line_wrapping and #line_content > default_config.max_line_length then
    line_content = M._wrap_line(line_content, formatted_message.components)
  end

  -- Set line content in buffer
  local lines = type(line_content) == 'table' and line_content or { line_content }
  local start_line = context.start_line or 0

  -- Make buffer temporarily modifiable
  local was_modifiable = vim.api.nvim_buf_get_option(context.bufnr, 'modifiable')
  if not was_modifiable then
    vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', true)
  end

  -- Set lines
  vim.api.nvim_buf_set_lines(context.bufnr, start_line, start_line + 1, false, lines)

  -- Apply highlights if enabled
  if default_config.syntax_highlighting then
    M._apply_highlights(formatted_message, context, lines)
  end

  -- Apply virtual text for emotes if enabled
  if default_config.virtual_text_enabled and formatted_message.metadata.has_emotes then
    M._apply_emote_virtual_text(formatted_message, context, start_line)
  end

  -- Restore buffer modifiability
  if not was_modifiable then
    vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', false)
  end

  return true
end

---Apply syntax highlighting to rendered message
---@param formatted_message table Formatted message
---@param context RenderContext Rendering context
---@param lines string[] Rendered lines
---@return nil
function M._apply_highlights(formatted_message, context, lines)
  local namespace_id = context.namespace_id or display_namespace

  -- Clear existing highlights for this line
  local start_line = context.start_line or 0
  vim.api.nvim_buf_clear_namespace(context.bufnr, namespace_id, start_line, start_line + #lines)

  -- Get highlights from formatter
  local highlights = formatter.get_highlights(formatted_message, default_config.highlight_groups)

  -- Apply each highlight
  for _, highlight in ipairs(highlights) do
    local line_idx = M._calculate_line_index(highlight.col_start, lines)
    local adjusted_col_start, adjusted_col_end =
      M._adjust_highlight_positions(highlight.col_start, highlight.col_end, lines, line_idx)

    if adjusted_col_start and adjusted_col_end then
      vim.api.nvim_buf_add_highlight(
        context.bufnr,
        namespace_id,
        highlight.hl_group,
        start_line + line_idx,
        adjusted_col_start,
        adjusted_col_end
      )
    end
  end
end

---Apply virtual text for emotes
---@param formatted_message table Formatted message
---@param context RenderContext Rendering context
---@param start_line number Starting line number
---@return nil
function M._apply_emote_virtual_text(formatted_message, context, start_line)
  if default_config.emote_rendering_mode ~= 'virtual_text' then
    return
  end

  local namespace_id = context.namespace_id or display_namespace
  local emote_components = {}

  -- Collect emote components
  for _, component in ipairs(formatted_message.components) do
    if component.type == 'emote' then
      table.insert(emote_components, component)
    end
  end

  if #emote_components == 0 then
    return
  end

  -- Create virtual text for emotes
  local virt_text = {}
  for _, emote in ipairs(emote_components) do
    local emote_display = M._get_emote_display_text(emote)
    if emote_display then
      table.insert(virt_text, { emote_display, 'TwitchChatEmote' })
    end
  end

  if #virt_text > 0 then
    vim.api.nvim_buf_set_extmark(context.bufnr, namespace_id, start_line, -1, {
      virt_text = virt_text,
      virt_text_pos = 'eol',
    })
  end
end

---Get display text for emote
---@param emote_component table Emote component
---@return string? display_text
function M._get_emote_display_text(emote_component)
  if emote_component.metadata and emote_component.metadata.emote_data then
    local emote_data = emote_component.metadata.emote_data

    -- Try to get unicode representation
    if emote_data.unicode then
      return emote_data.unicode
    end

    -- Fallback to text representation
    return '[' .. emote_component.content .. ']'
  end

  return '[' .. emote_component.content .. ']'
end

---Wrap line content intelligently
---@param content string Line content
---@param components table[] Message components
---@return string[] wrapped_lines
function M._wrap_line(content, components)
  -- Simple word-based wrapping for now
  -- Could be enhanced to respect component boundaries

  local max_length = default_config.max_line_length
  if #content <= max_length then
    return { content }
  end

  local lines = {}
  local current_line = ''
  local words = vim.split(content, ' ', { plain = true })

  for _, word in ipairs(words) do
    if #current_line + #word + 1 <= max_length then
      current_line = current_line .. (current_line ~= '' and ' ' or '') .. word
    else
      if current_line ~= '' then
        table.insert(lines, current_line)
      end
      current_line = word
    end
  end

  if current_line ~= '' then
    table.insert(lines, current_line)
  end

  return lines
end

---Calculate which line index a column position falls into
---@param col_pos number Column position
---@param lines string[] Line content
---@return number line_index
function M._calculate_line_index(col_pos, lines)
  local current_pos = 0

  for i, line in ipairs(lines) do
    if col_pos <= current_pos + #line then
      return i - 1 -- 0-indexed
    end
    current_pos = current_pos + #line + 1 -- +1 for line break
  end

  return #lines - 1 -- Default to last line
end

---Adjust highlight positions for wrapped lines
---@param col_start number Start column
---@param col_end number End column
---@param lines string[] Line content
---@param line_idx number Target line index
---@return number? adjusted_start
---@return number? adjusted_end
function M._adjust_highlight_positions(col_start, col_end, lines, line_idx)
  if line_idx >= #lines then
    return nil, nil
  end

  local line_start_pos = 0
  for i = 1, line_idx do
    line_start_pos = line_start_pos + #lines[i] + 1
  end

  local line = lines[line_idx + 1] -- 1-indexed access
  local line_end_pos = line_start_pos + #line

  -- Check if highlight overlaps with this line
  if col_end < line_start_pos or col_start > line_end_pos then
    return nil, nil
  end

  -- Adjust positions relative to line
  local adjusted_start = math.max(0, col_start - line_start_pos)
  local adjusted_end = math.min(#line, col_end - line_start_pos)

  return adjusted_start, adjusted_end
end

---Setup default highlight groups
---@return nil
function M._setup_highlight_groups()
  local base_highlights = config.get('ui.highlights') or {}

  -- Define default highlight groups
  local default_highlights = {
    TwitchChatTimestamp = { link = base_highlights.timestamp or 'Comment' },
    TwitchChatBadge = { link = base_highlights.badge or 'Special' },
    TwitchChatUsername = { link = base_highlights.username or 'Identifier' },
    TwitchChatModerator = { link = base_highlights.moderator or 'Function' },
    TwitchChatVIP = { link = base_highlights.vip or 'Special' },
    TwitchChatSubscriber = { link = base_highlights.subscriber or 'Identifier' },
    TwitchChatContent = { link = base_highlights.message or 'Normal' },
    TwitchChatMention = { link = base_highlights.mention or 'WarningMsg' },
    TwitchChatCommand = { link = base_highlights.command or 'Function' },
    TwitchChatEmote = { link = base_highlights.emote or 'Special' },
    TwitchChatURL = { link = base_highlights.url or 'Underlined' },
  }

  -- Set highlight groups if they don't exist
  for group_name, group_def in pairs(default_highlights) do
    if not vim.fn.hlexists(group_name) then
      vim.api.nvim_set_hl(0, group_name, group_def)
    end
  end
end

---Render multiple messages efficiently
---@param formatted_messages table[] Array of formatted messages
---@param context RenderContext Rendering context
---@param options table? Rendering options
---@return boolean success
function M.render_messages(formatted_messages, context, options)
  vim.validate({
    formatted_messages = { formatted_messages, 'table' },
    context = { context, 'table' },
    options = { options, 'table', true },
  })

  options = options or {}

  if not vim.api.nvim_buf_is_valid(context.bufnr) then
    return false
  end

  -- Batch render for performance
  local all_lines = {}
  local line_to_message_map = {}

  -- Prepare all content
  for i, formatted_message in ipairs(formatted_messages) do
    local line_content = formatted_message.formatted_line

    if default_config.line_wrapping and #line_content > default_config.max_line_length then
      local wrapped = M._wrap_line(line_content, formatted_message.components)
      for j, wrapped_line in ipairs(wrapped) do
        table.insert(all_lines, wrapped_line)
        line_to_message_map[#all_lines] = { message_idx = i, line_idx = j }
      end
    else
      table.insert(all_lines, line_content)
      line_to_message_map[#all_lines] = { message_idx = i, line_idx = 1 }
    end
  end

  -- Set all lines at once
  local start_line = context.start_line or 0
  local was_modifiable = vim.api.nvim_buf_get_option(context.bufnr, 'modifiable')

  if not was_modifiable then
    vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', true)
  end

  vim.api.nvim_buf_set_lines(context.bufnr, start_line, start_line + #all_lines, false, all_lines)

  -- Apply highlights for all messages
  if default_config.syntax_highlighting then
    for line_num, mapping in pairs(line_to_message_map) do
      local msg = formatted_messages[mapping.message_idx]
      local line_context = vim.tbl_deep_extend('force', context, {
        start_line = start_line + line_num - 1,
      })

      M._apply_highlights(msg, line_context, { all_lines[line_num] })
    end
  end

  if not was_modifiable then
    vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', false)
  end

  return true
end

---Clear all display content from buffer
---@param context RenderContext Rendering context
---@return nil
function M.clear_display(context)
  vim.validate({
    context = { context, 'table' },
  })

  if not vim.api.nvim_buf_is_valid(context.bufnr) then
    return
  end

  local namespace_id = context.namespace_id or display_namespace

  -- Clear highlights
  vim.api.nvim_buf_clear_namespace(context.bufnr, namespace_id, 0, -1)

  -- Clear buffer content if requested
  if context.clear_content then
    local was_modifiable = vim.api.nvim_buf_get_option(context.bufnr, 'modifiable')
    if not was_modifiable then
      vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', true)
    end

    vim.api.nvim_buf_set_lines(context.bufnr, 0, -1, false, {})

    if not was_modifiable then
      vim.api.nvim_buf_set_option(context.bufnr, 'modifiable', false)
    end
  end
end

---Set display configuration
---@param new_config DisplayConfig Configuration updates
---@return nil
function M.set_config(new_config)
  vim.validate({
    new_config = { new_config, 'table' },
  })

  default_config = utils.deep_merge(default_config, new_config)

  -- Re-setup highlight groups if changed
  if new_config.highlight_groups then
    M._setup_highlight_groups()
  end
end

---Get current display configuration
---@return DisplayConfig config
function M.get_config()
  return vim.deepcopy(default_config)
end

---Get display statistics
---@return table stats
function M.get_stats()
  return {
    namespace_id = display_namespace,
    config = default_config,
    highlight_groups_count = vim.fn.hlexists('TwitchChatTimestamp') and 1 or 0,
  }
end

return M
