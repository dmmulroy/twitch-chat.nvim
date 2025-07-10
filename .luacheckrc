-- Luacheck configuration for twitch-chat.nvim
-- See: https://luacheck.readthedocs.io/en/stable/config.html

-- Lua standard library version
std = "luajit"

-- Global variables
globals = {
  "vim",
  "_TEST", -- for testing
}

-- Read globals (variables that can be read but not written)
read_globals = {
  "vim",
}

-- Ignore specific warnings
ignore = {
  "212", -- Unused argument (common in callbacks)
  "213", -- Unused loop variable
  "631", -- Line is too long (handled by stylua)
}

-- Exclude files/directories
exclude_files = {
  "**/.git/**",
  "**/node_modules/**",
  "**/.luarocks/**",
}

-- File-specific overrides
files["tests/**/*_spec.lua"] = {
  read_globals = {
    "describe",
    "it", 
    "before_each",
    "after_each",
    "assert",
    "spy",
    "stub",
    "mock",
    "pending",
    "setup",
    "teardown",
  },
  globals = {
    "vim",
    "os",
  }
}

files["lua/twitch-chat/example_usage.lua"] = {
  ignore = {"unused"}
}

-- Maximum line length (handled by stylua, but good to have)
max_line_length = 100

-- Maximum cyclomatic complexity
max_cyclomatic_complexity = 15

-- Cache results
cache = true