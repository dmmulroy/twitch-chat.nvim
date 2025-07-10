---@class TwitchChatEmotes
---Emote handling and display for Twitch chat
local M = {}
local uv = vim.uv or vim.loop

---@class Timer
---@field start fun(self: Timer, timeout: number, repeat_timeout: number, callback: function): boolean
---@field stop fun(self: Timer): boolean
---@field close fun(self: Timer): nil

---@class EmoteConfig
---@field enabled boolean
---@field display_mode string -- 'text', 'unicode', 'virtual_text'
---@field virtual_text_config EmoteVirtualTextConfig
---@field providers EmoteProvidersConfig
---@field cache_config EmoteCacheConfig
---@field rendering_config EmoteRenderingConfig

---@class EmoteVirtualTextConfig
---@field enabled boolean
---@field position string -- 'eol', 'overlay', 'right_align'
---@field highlight_group string
---@field prefix string
---@field suffix string
---@field max_width number

---@class EmoteProvidersConfig
---@field twitch EmoteProviderConfig
---@field bttv EmoteProviderConfig
---@field ffz EmoteProviderConfig
---@field seventv EmoteProviderConfig

---@class EmoteProviderConfig
---@field enabled boolean
---@field global_emotes boolean
---@field channel_emotes boolean
---@field api_url string?
---@field cache_duration number -- seconds

---@class EmoteCacheConfig
---@field enabled boolean
---@field max_size number
---@field cleanup_interval number -- seconds
---@field persist_to_disk boolean
---@field cache_file string?

---@class EmoteRenderingConfig
---@field max_emotes_per_message number
---@field render_delay number -- milliseconds
---@field batch_size number
---@field async_rendering boolean

---@class EmoteData
---@field name string
---@field id string
---@field url string
---@field provider string
---@field type string -- 'global', 'channel', 'subscriber'
---@field animated boolean?
---@field width number?
---@field height number?
---@field unicode string?
---@field aliases string[]?

---@class EmoteMatch
---@field text string
---@field start_pos number
---@field end_pos number
---@field emote EmoteData

---@class EmoteRenderJob
---@field channel string
---@field bufnr number
---@field line_number number
---@field emotes EmoteMatch[]
---@field render_mode string

local config = require('twitch-chat.config')
local utils = require('twitch-chat.utils')
local events = require('twitch-chat.events')
local circuit_breaker = require('twitch-chat.modules.circuit_breaker')

-- Circuit breakers for emote APIs
local emote_api_breakers = {
  twitch = circuit_breaker.get_or_create('twitch_emotes', {
    failure_threshold = 3,
    recovery_timeout = 60000, -- 1 minute
    success_threshold = 2,
    timeout = 8000,
  }),
  bttv = circuit_breaker.get_or_create('bttv_emotes', {
    failure_threshold = 5,
    recovery_timeout = 120000, -- 2 minutes
    success_threshold = 3,
    timeout = 10000,
  }),
  ffz = circuit_breaker.get_or_create('ffz_emotes', {
    failure_threshold = 5,
    recovery_timeout = 120000, -- 2 minutes
    success_threshold = 3,
    timeout = 10000,
  }),
  seventv = circuit_breaker.get_or_create('7tv_emotes', {
    failure_threshold = 5,
    recovery_timeout = 120000, -- 2 minutes
    success_threshold = 3,
    timeout = 10000,
  }),
}

---@type EmoteConfig
local default_config = {
  enabled = true,
  display_mode = 'virtual_text', -- 'text', 'unicode', 'virtual_text'
  virtual_text_config = {
    enabled = true,
    position = 'eol',
    highlight_group = 'TwitchChatEmote',
    prefix = ' ',
    suffix = '',
    max_width = 50,
  },
  providers = {
    twitch = {
      enabled = true,
      global_emotes = true,
      channel_emotes = true,
      api_url = 'https://api.twitch.tv/helix/chat/emotes',
      cache_duration = 3600, -- 1 hour
    },
    bttv = {
      enabled = true,
      global_emotes = true,
      channel_emotes = true,
      api_url = 'https://api.betterttv.net/3/cached',
      cache_duration = 1800, -- 30 minutes
    },
    ffz = {
      enabled = true,
      global_emotes = true,
      channel_emotes = true,
      api_url = 'https://api.frankerfacez.com/v1',
      cache_duration = 1800, -- 30 minutes
    },
    seventv = {
      enabled = true,
      global_emotes = true,
      channel_emotes = true,
      api_url = 'https://api.7tv.app/v2',
      cache_duration = 1800, -- 30 minutes
    },
  },
  cache_config = {
    enabled = true,
    max_size = 10000,
    cleanup_interval = 300, -- 5 minutes
    persist_to_disk = true,
    cache_file = vim.fn.stdpath('cache') .. '/twitch-chat/emotes.json',
  },
  rendering_config = {
    max_emotes_per_message = 20,
    render_delay = 100, -- milliseconds
    batch_size = 50,
    async_rendering = true,
  },
}

-- Emote caches
local emote_cache = {
  global = {},
  channels = {},
  metadata = {},
}

-- Render queue and timers
local render_queue = {}
---@type Timer?
local render_timer = nil
---@type Timer?
local cache_cleanup_timer = nil

-- Namespace for virtual text
local emote_namespace = vim.api.nvim_create_namespace('twitch_chat_emotes')

-- Common emote unicode mappings
local unicode_emotes = {
  ['Kappa'] = '😏',
  ['PogChamp'] = '😲',
  ['LUL'] = '😂',
  ['OMEGALUL'] = '🤣',
  ['MonkaS'] = '😰',
  ['EZ'] = '😎',
  ['5Head'] = '🧠',
  ['Pepega'] = '🤪',
  ['KEKW'] = '😹',
  ['Sadge'] = '😢',
  ['Pog'] = '😮',
  ['Jebaited'] = '😤',
  ['Kreygasm'] = '😍',
  ['ResidentSleeper'] = '😴',
  ['TriHard'] = '😤',
  ['CoolStoryBob'] = '😒',
  ['BibleThump'] = '😭',
  ['FeelsGoodMan'] = '😊',
  ['FeelsBadMan'] = '😞',
  ['MonkaW'] = '😨',
  ['POGGERS'] = '😮',
  ['AYAYA'] = '😊',
  ['WeirdChamp'] = '😬',
  ['Clap'] = '👏',
  ['EZ Clap'] = '👏',
  ['LULW'] = '😂',
}

---Initialize the emotes module
---@param user_config table?
---@return boolean success
function M.setup(user_config)
  if user_config then
    default_config = utils.deep_merge(default_config, user_config)
  end

  -- Check if emotes are enabled
  if not default_config.enabled then
    return false
  end

  -- Setup namespace and highlights
  M._setup_highlights()

  -- Setup event listeners
  M._setup_event_listeners()

  -- Initialize caches
  M._init_caches()

  -- Start timers
  M._start_timers()

  -- Load global emotes
  M._load_global_emotes()

  return true
end

---Initialize emotes module (alias for setup)
---@param config EmoteConfig?
function M.init(config)
  M.setup(config)
end

---Check if emotes are enabled
---@return boolean enabled
function M.is_enabled()
  return default_config.enabled
end

---Parse emotes from message content
---@param content string Message content
---@param channel string Channel name
---@return EmoteMatch[]
function M.parse_emotes(content, channel)
  vim.validate({
    content = { content, 'string' },
    channel = { channel, 'string' },
  })

  if not default_config.enabled then
    return {}
  end

  local emotes = {}
  local words = utils.split(content, ' ')
  local current_pos = 1

  for _, word in ipairs(words) do
    -- Find word position in original content
    local word_start = content:find(vim.pesc(word), current_pos, true)
    if word_start then
      local word_end = word_start + #word - 1

      -- Check if word is an emote
      local emote_data = M._find_emote(word, channel)
      if emote_data then
        table.insert(emotes, {
          text = word,
          start_pos = word_start,
          end_pos = word_end,
          emote = emote_data,
        })
      end

      current_pos = word_end + 1
    end
  end

  -- Limit number of emotes per message
  if #emotes > default_config.rendering_config.max_emotes_per_message then
    local limited = {}
    for i = 1, default_config.rendering_config.max_emotes_per_message do
      limited[i] = emotes[i]
    end
    emotes = limited
  end

  return emotes
end

---Render emotes for a message
---@param channel string Channel name
---@param bufnr number Buffer number
---@param line_number number Line number
---@param content string Message content
---@param emotes EmoteMatch[]?
---@return nil
function M.render_emotes(channel, bufnr, line_number, content, emotes)
  vim.validate({
    channel = { channel, 'string' },
    bufnr = { bufnr, 'number' },
    line_number = { line_number, 'number' },
    content = { content, 'string' },
    emotes = { emotes, 'table', true },
  })

  if not default_config.enabled then
    return
  end

  -- Parse emotes if not provided
  if not emotes then
    emotes = M.parse_emotes(content, channel)
  end

  if #emotes == 0 then
    return
  end

  -- Queue for rendering
  if default_config.rendering_config.async_rendering then
    table.insert(render_queue, {
      channel = channel,
      bufnr = bufnr,
      line_number = line_number,
      emotes = emotes,
      render_mode = default_config.display_mode,
    })

    M._process_render_queue()
  else
    M._render_emotes_sync(bufnr, line_number, emotes)
  end
end

---Process render queue
---@return nil
function M._process_render_queue()
  if render_timer then
    return -- Already processing
  end

  ---@type Timer
  render_timer = uv.new_timer()
  render_timer:start(default_config.rendering_config.render_delay, 0, function()
    vim.schedule(function()
      local batch_size = default_config.rendering_config.batch_size
      local processed = 0

      while #render_queue > 0 and processed < batch_size do
        local job = table.remove(render_queue, 1)
        M._render_emotes_sync(job.bufnr, job.line_number, job.emotes)
        processed = processed + 1
      end

      -- Reset timer
      if render_timer then
        render_timer:stop()
        render_timer = nil
      end

      -- Continue processing if more items in queue
      if #render_queue > 0 then
        M._process_render_queue()
      end
    end)
  end)
end

---Render emotes synchronously
---@param bufnr number Buffer number
---@param line_number number Line number
---@param emotes EmoteMatch[]
---@return nil
function M._render_emotes_sync(bufnr, line_number, emotes)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local display_mode = default_config.display_mode

  if display_mode == 'virtual_text' then
    M._render_virtual_text(bufnr, line_number, emotes)
  elseif display_mode == 'unicode' then
    M._render_unicode(bufnr, line_number, emotes)
  end
  -- 'text' mode doesn't need special rendering
end

---Render emotes as virtual text
---@param bufnr number Buffer number
---@param line_number number Line number
---@param emotes EmoteMatch[]
---@return nil
function M._render_virtual_text(bufnr, line_number, emotes)
  local vt_config = default_config.virtual_text_config
  if not vt_config.enabled then
    return
  end

  local emote_texts = {}
  for _, emote_match in ipairs(emotes) do
    local emote_text = M._get_emote_display_text(emote_match.emote)
    table.insert(emote_texts, emote_text)
  end

  if #emote_texts == 0 then
    return
  end

  local virt_text = vt_config.prefix .. table.concat(emote_texts, ' ') .. vt_config.suffix

  -- Truncate if too long
  if #virt_text > vt_config.max_width then
    virt_text = virt_text:sub(1, vt_config.max_width - 3) .. '...'
  end

  -- Set virtual text
  vim.api.nvim_buf_set_extmark(bufnr, emote_namespace, line_number - 1, -1, {
    virt_text = { { virt_text, vt_config.highlight_group } },
    virt_text_pos = vt_config.position,
  })
end

---Render emotes as unicode characters
---@param bufnr number Buffer number
---@param line_number number Line number
---@param emotes EmoteMatch[]
---@return nil
function M._render_unicode(bufnr, line_number, emotes)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_number - 1, line_number, false)
  if #lines == 0 then
    return
  end

  local line = lines[1]
  local new_line = line

  -- Replace emotes with unicode (in reverse order to maintain positions)
  for i = #emotes, 1, -1 do
    local emote_match = emotes[i]
    local unicode_char = M._get_emote_unicode(emote_match.emote)

    if unicode_char then
      new_line = new_line:sub(1, emote_match.start_pos - 1)
        .. unicode_char
        .. new_line:sub(emote_match.end_pos + 1)
    end
  end

  -- Update line if changed
  if new_line ~= line then
    vim.api.nvim_buf_set_lines(bufnr, line_number - 1, line_number, false, { new_line })
  end
end

---Find emote data by name
---@param name string Emote name
---@param channel string Channel name
---@return EmoteData?
function M._find_emote(name, channel)
  -- Check channel-specific emotes first
  if emote_cache.channels[channel] then
    for _, emote in ipairs(emote_cache.channels[channel]) do
      if emote.name == name then
        return emote
      end

      -- Check aliases
      if emote.aliases then
        for _, alias in ipairs(emote.aliases) do
          if alias == name then
            return emote
          end
        end
      end
    end
  end

  -- Check global emotes
  for _, emote in ipairs(emote_cache.global) do
    if emote.name == name then
      return emote
    end

    -- Check aliases
    if emote.aliases then
      for _, alias in ipairs(emote.aliases) do
        if alias == name then
          return emote
        end
      end
    end
  end

  return nil
end

---Get display text for emote
---@param emote EmoteData
---@return string
function M._get_emote_display_text(emote)
  -- Try unicode first
  local unicode_char = M._get_emote_unicode(emote)
  if unicode_char then
    return unicode_char
  end

  -- Fall back to text representation
  return '[' .. emote.name .. ']'
end

---Get unicode character for emote
---@param emote EmoteData
---@return string?
function M._get_emote_unicode(emote)
  -- Check if emote has unicode mapping
  if emote.unicode then
    return emote.unicode
  end

  -- Check common unicode mappings
  return unicode_emotes[emote.name]
end

---Setup event listeners
---@return nil
function M._setup_event_listeners()
  -- Render emotes when messages are received
  events.on(events.MESSAGE_RECEIVED, function(data)
    if data.channel and data.bufnr and data.line_number and data.content then
      M.render_emotes(data.channel, data.bufnr, data.line_number, data.content, data.emotes)
    end
  end)

  -- Load channel emotes when joining
  events.on(events.CHANNEL_JOINED, function(data)
    if data.channel then
      M._load_channel_emotes(data.channel)
    end
  end)

  -- Clear channel emotes when leaving
  events.on(events.CHANNEL_LEFT, function(data)
    if data.channel then
      M._clear_channel_emotes(data.channel)
    end
  end)
end

---Setup highlights
---@return nil
function M._setup_highlights()
  -- Create highlight group for emotes
  if not vim.fn.hlexists('TwitchChatEmote') then
    vim.api.nvim_set_hl(0, 'TwitchChatEmote', {
      link = config.get('ui.highlights.emote') or 'Special',
    })
  end
end

---Initialize caches
---@return nil
function M._init_caches()
  emote_cache = {
    global = {},
    channels = {},
    metadata = {},
  }

  -- Load from disk if enabled
  if default_config.cache_config.persist_to_disk then
    M._load_cache_from_disk()
  end
end

---Start timers
---@return nil
function M._start_timers()
  -- Cache cleanup timer
  if default_config.cache_config.enabled and default_config.cache_config.cleanup_interval > 0 then
    ---@type Timer
    cache_cleanup_timer = uv.new_timer()
    cache_cleanup_timer:start(
      default_config.cache_config.cleanup_interval * 1000,
      default_config.cache_config.cleanup_interval * 1000,
      function()
        vim.schedule(function()
          M._cleanup_cache()
        end)
      end
    )
  end
end

---Load global emotes from all enabled providers
---@return nil
function M._load_global_emotes()
  if default_config.providers.twitch.enabled and default_config.providers.twitch.global_emotes then
    M._load_twitch_global_emotes()
  end

  if default_config.providers.bttv.enabled and default_config.providers.bttv.global_emotes then
    M._load_bttv_global_emotes()
  end

  if default_config.providers.ffz.enabled and default_config.providers.ffz.global_emotes then
    M._load_ffz_global_emotes()
  end

  if
    default_config.providers.seventv.enabled and default_config.providers.seventv.global_emotes
  then
    M._load_seventv_global_emotes()
  end
end

---Load channel emotes for a specific channel
---@param channel string Channel name
---@return nil
function M._load_channel_emotes(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  if default_config.providers.twitch.enabled and default_config.providers.twitch.channel_emotes then
    M._load_twitch_channel_emotes(channel)
  end

  if default_config.providers.bttv.enabled and default_config.providers.bttv.channel_emotes then
    M._load_bttv_channel_emotes(channel)
  end

  if default_config.providers.ffz.enabled and default_config.providers.ffz.channel_emotes then
    M._load_ffz_channel_emotes(channel)
  end

  if
    default_config.providers.seventv.enabled and default_config.providers.seventv.channel_emotes
  then
    M._load_seventv_channel_emotes(channel)
  end
end

---Load Twitch global emotes from Helix API
---@return nil
function M._load_twitch_global_emotes()
  local auth = require('twitch-chat.modules.auth')
  local curl = require('plenary.curl')

  -- Check if we have authentication
  if not auth.is_authenticated() then
    utils.log(vim.log.levels.WARN, 'Cannot load Twitch emotes: not authenticated')
    return
  end

  local access_token = auth.get_access_token()
  if not access_token then
    utils.log(vim.log.levels.WARN, 'Cannot load Twitch emotes: no access token')
    return
  end

  -- Fetch global emotes from Twitch Helix API
  curl.get('https://api.twitch.tv/helix/chat/emotes/global', {
    headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
      ['Client-Id'] = auth.config and auth.config.client_id or config.get('auth.client_id') or '',
    },
    callback = function(response)
      if response.status == 200 then
        local success, data = pcall(vim.json.decode, response.body)
        if success and data.data then
          for _, emote_data in ipairs(data.data) do
            local emote = {
              name = emote_data.name,
              id = emote_data.id,
              provider = 'twitch',
              type = 'global',
              url = emote_data.images.url_1x,
              format = emote_data.format,
              scale = emote_data.scale,
              theme_mode = emote_data.theme_mode,
            }

            M._add_emote_to_cache(emote)
          end

          utils.log(
            vim.log.levels.INFO,
            string.format('Loaded %d Twitch global emotes', #data.data)
          )
        else
          utils.log(vim.log.levels.ERROR, 'Failed to parse Twitch global emotes response')
        end
      else
        utils.log(
          vim.log.levels.ERROR,
          string.format('Failed to fetch Twitch global emotes: %d', response.status)
        )
      end
    end,
  })
end

---Load BTTV global emotes from API
---@return nil
function M._load_bttv_global_emotes()
  local curl = require('plenary.curl')

  -- Fetch global emotes from BTTV API with circuit breaker protection
  local cb_success, cb_result = circuit_breaker.call(emote_api_breakers.bttv, function()
    curl.get('https://api.betterttv.net/3/cached/emotes/global', {
      callback = function(response)
        if response.status == 200 then
          local success, data = pcall(vim.json.decode, response.body)
          if success and data then
            for _, emote_data in ipairs(data) do
              local emote = {
                name = emote_data.code,
                id = emote_data.id,
                provider = 'bttv',
                type = 'global',
                url = string.format('https://cdn.betterttv.net/emote/%s/1x', emote_data.id),
                user_id = emote_data.userId,
                image_type = emote_data.imageType,
              }

              M._add_emote_to_cache(emote)
            end

            utils.log(vim.log.levels.INFO, string.format('Loaded %d BTTV global emotes', #data))
          else
            utils.log(vim.log.levels.ERROR, 'Failed to parse BTTV global emotes response')
            error('Parse failure')
          end
        else
          utils.log(
            vim.log.levels.ERROR,
            string.format('Failed to fetch BTTV global emotes: %d', response.status)
          )
          if response.status >= 500 then
            error('HTTP ' .. response.status)
          end
        end
      end,
    })
    return true
  end)

  if not cb_success then
    utils.log(
      vim.log.levels.WARN,
      'BTTV emotes unavailable: ' .. (cb_result or 'Circuit breaker open')
    )
  end
end

---Load FFZ global emotes from API
---@return nil
function M._load_ffz_global_emotes()
  local curl = require('plenary.curl')

  -- Fetch global emotes from FFZ API
  curl.get('https://api.frankerfacez.com/v1/set/global', {
    callback = function(response)
      if response.status == 200 then
        local success, data = pcall(vim.json.decode, response.body)
        if success and data and data.sets then
          local emote_count = 0
          for _, set in pairs(data.sets) do
            if set.emoticons then
              for _, emote_data in ipairs(set.emoticons) do
                local emote = {
                  name = emote_data.name,
                  id = tostring(emote_data.id),
                  provider = 'ffz',
                  type = 'global',
                  url = string.format('https://cdn.frankerfacez.com/emoticon/%d/1', emote_data.id),
                  width = emote_data.width,
                  height = emote_data.height,
                  owner = emote_data.owner,
                }

                M._add_emote_to_cache(emote)
                emote_count = emote_count + 1
              end
            end
          end

          utils.log(vim.log.levels.INFO, string.format('Loaded %d FFZ global emotes', emote_count))
        else
          utils.log(vim.log.levels.ERROR, 'Failed to parse FFZ global emotes response')
        end
      else
        utils.log(
          vim.log.levels.ERROR,
          string.format('Failed to fetch FFZ global emotes: %d', response.status)
        )
      end
    end,
  })
end

---Load 7TV global emotes from API
---@return nil
function M._load_seventv_global_emotes()
  local curl = require('plenary.curl')

  -- Fetch global emotes from 7TV API
  curl.get('https://7tv.io/v3/emote-sets/global', {
    callback = function(response)
      if response.status == 200 then
        local success, data = pcall(vim.json.decode, response.body)
        if success and data and data.emotes then
          for _, emote_data in ipairs(data.emotes) do
            local emote = {
              name = emote_data.name,
              id = emote_data.id,
              provider = '7tv',
              type = 'global',
              url = string.format('https://cdn.7tv.app/emote/%s/1x.webp', emote_data.id),
              animated = emote_data.animated or false,
              flags = emote_data.flags or 0,
              owner = emote_data.owner,
            }

            M._add_emote_to_cache(emote)
          end

          utils.log(vim.log.levels.INFO, string.format('Loaded %d 7TV global emotes', #data.emotes))
        else
          utils.log(vim.log.levels.ERROR, 'Failed to parse 7TV global emotes response')
        end
      else
        utils.log(
          vim.log.levels.ERROR,
          string.format('Failed to fetch 7TV global emotes: %d', response.status)
        )
      end
    end,
  })
end

---Load Twitch channel emotes (placeholder)
---@param channel string Channel name
---@return nil
function M._load_twitch_channel_emotes(channel)
  -- In a real implementation, this would fetch from Twitch API
  -- For now, just initialize empty channel cache
  if not emote_cache.channels[channel] then
    emote_cache.channels[channel] = {}
  end
end

---Load BTTV channel emotes (placeholder)
---@param channel string Channel name
---@return nil
function M._load_bttv_channel_emotes(channel)
  -- In a real implementation, this would fetch from BTTV API
  if not emote_cache.channels[channel] then
    emote_cache.channels[channel] = {}
  end
end

---Load FFZ channel emotes (placeholder)
---@param channel string Channel name
---@return nil
function M._load_ffz_channel_emotes(channel)
  -- In a real implementation, this would fetch from FFZ API
  if not emote_cache.channels[channel] then
    emote_cache.channels[channel] = {}
  end
end

---Load 7TV channel emotes (placeholder)
---@param channel string Channel name
---@return nil
function M._load_seventv_channel_emotes(channel)
  -- In a real implementation, this would fetch from 7TV API
  if not emote_cache.channels[channel] then
    emote_cache.channels[channel] = {}
  end
end

---Clear channel emotes
---@param channel string Channel name
---@return nil
function M._clear_channel_emotes(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  emote_cache.channels[channel] = nil
end

---Cleanup cache
---@return nil
function M._cleanup_cache()
  local now = os.time()

  -- Clean up expired cache entries
  for channel, metadata in pairs(emote_cache.metadata) do
    if metadata.expires and now > metadata.expires then
      emote_cache.channels[channel] = nil
      emote_cache.metadata[channel] = nil
    end
  end

  -- Clean up global cache if expired
  if
    emote_cache.metadata.global
    and emote_cache.metadata.global.expires
    and now > emote_cache.metadata.global.expires
  then
    emote_cache.global = {}
    emote_cache.metadata.global = nil
  end

  -- Save to disk
  if default_config.cache_config.persist_to_disk then
    M._save_cache_to_disk()
  end
end

---Load cache from disk
---@return nil
function M._load_cache_from_disk()
  local cache_file = default_config.cache_config.cache_file
  if not cache_file or not utils.file_exists(cache_file) then
    return
  end

  local content = utils.read_file(cache_file)
  if not content then
    return
  end

  local success, cache_data = pcall(vim.fn.json_decode, content)
  if success and type(cache_data) == 'table' then
    emote_cache = utils.deep_merge(emote_cache, cache_data)
  end
end

---Save cache to disk
---@return nil
function M._save_cache_to_disk()
  local cache_file = default_config.cache_config.cache_file
  if not cache_file then
    return
  end

  local cache_data = {
    global = emote_cache.global,
    channels = emote_cache.channels,
    metadata = emote_cache.metadata,
  }

  local content = vim.fn.json_encode(cache_data)
  utils.write_file(cache_file, content)
end

---Add emote to cache
---@param emote EmoteData
---@param channel string? Channel name (nil for global)
---@return nil
---Cache an emote (alias for add_emote)
---@param name string
---@param data any
function M.cache_emote(name, data)
  local emote = {
    name = name,
    id = name,
    data = data,
  }
  M.add_emote(emote, 'global')
end

function M.add_emote(emote, channel)
  vim.validate({
    emote = { emote, 'table' },
    channel = { channel, 'string', true },
  })

  if channel then
    -- Channel-specific emote
    if not emote_cache.channels[channel] then
      emote_cache.channels[channel] = {}
    end

    table.insert(emote_cache.channels[channel], emote)

    -- Update metadata
    if not emote_cache.metadata[channel] then
      emote_cache.metadata[channel] = {}
    end
    emote_cache.metadata[channel].last_updated = os.time()
  else
    -- Global emote
    table.insert(emote_cache.global, emote)

    -- Update metadata
    if not emote_cache.metadata.global then
      emote_cache.metadata.global = {}
    end
    emote_cache.metadata.global.last_updated = os.time()
  end
end

---Get all emotes for a channel
---@param channel string Channel name
---@return EmoteData[]
function M.get_channel_emotes(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  return emote_cache.channels[channel] or {}
end

---Get all global emotes
---@return EmoteData[]
function M.get_global_emotes()
  return emote_cache.global or {}
end

---Get all available emotes for a channel (global + channel-specific)
---@param channel string Channel name
---@return EmoteData[]
function M.get_available_emotes(channel)
  vim.validate({
    channel = { channel, 'string' },
  })

  local emotes = {}

  -- Add global emotes
  for _, emote in ipairs(emote_cache.global) do
    table.insert(emotes, emote)
  end

  -- Add channel-specific emotes
  local channel_emotes = emote_cache.channels[channel] or {}
  for _, emote in ipairs(channel_emotes) do
    table.insert(emotes, emote)
  end

  return emotes
end

---Clear all emote rendering for a buffer
---@param bufnr number Buffer number
---@return nil
function M.clear_emote_rendering(bufnr)
  vim.validate({
    bufnr = { bufnr, 'number' },
  })

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, emote_namespace, 0, -1)
  end
end

---Get emote cache statistics
---@return table
function M.get_cache_stats()
  local stats = {
    global_emotes = #emote_cache.global,
    channel_emotes = {},
    total_emotes = #emote_cache.global,
    cache_size = utils.table_length(emote_cache.channels),
    providers = {
      twitch = 0,
      bttv = 0,
      ffz = 0,
      seventv = 0,
    },
  }

  -- Count channel emotes
  for channel, emotes in pairs(emote_cache.channels) do
    local count = #emotes
    stats.channel_emotes[channel] = count
    stats.total_emotes = stats.total_emotes + count
  end

  -- Count by provider
  for _, emote in ipairs(emote_cache.global) do
    if stats.providers[emote.provider] then
      stats.providers[emote.provider] = stats.providers[emote.provider] + 1
    end
  end

  for channel, emotes in pairs(emote_cache.channels) do
    for _, emote in ipairs(emotes) do
      if stats.providers[emote.provider] then
        stats.providers[emote.provider] = stats.providers[emote.provider] + 1
      end
    end
  end

  return stats
end

---Cleanup function
---@return nil
function M.cleanup()
  -- Stop timers
  if render_timer then
    render_timer:stop()
    render_timer = nil
  end

  if cache_cleanup_timer then
    cache_cleanup_timer:stop()
    cache_cleanup_timer = nil
  end

  -- Save cache
  if default_config.cache_config.persist_to_disk then
    M._save_cache_to_disk()
  end

  -- Clear render queue
  render_queue = {}
end

return M
