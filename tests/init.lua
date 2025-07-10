-- tests/init.lua
-- Test initialization file

-- Add lua path for testing
local function add_to_path(path)
  package.path = package.path .. ';' .. path .. '/?.lua'
  package.path = package.path .. ';' .. path .. '/?/init.lua'
end

-- Add the plugin to the path
add_to_path(vim.fn.getcwd() .. '/lua')

-- Minimal vim setup for testing
_G.vim = vim
require('plenary.busted')
