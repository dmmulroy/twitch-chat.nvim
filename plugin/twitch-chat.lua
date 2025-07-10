-- plugin/twitch-chat.lua
-- Plugin initialization file

if vim.g.loaded_twitch_chat == 1 then
  return
end

-- Check Neovim version
if vim.fn.has('nvim-0.9.0') == 0 then
  vim.api.nvim_err_writeln('twitch-chat.nvim requires Neovim 0.9.0 or higher')
  return
end

vim.api.nvim_set_var('loaded_twitch_chat', 1)
