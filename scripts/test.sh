#!/bin/bash

# Test runner script for twitch-chat.nvim
# This script runs the comprehensive test suite using plenary.nvim

set -e

echo "🧪 Running TwitchChat.nvim Test Suite"
echo "====================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if Neovim is available
if ! command -v nvim &> /dev/null; then
    echo -e "${RED}❌ Neovim not found. Please install Neovim >= 0.8.0${NC}"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}📁 Project directory: $PROJECT_DIR${NC}"
echo ""

# Check if plenary is available (try both clean and regular)
echo -e "${YELLOW}🔍 Checking dependencies...${NC}"
PLENARY_AVAILABLE=false

# First try with regular nvim (respects plugin manager)
if nvim --headless -c "lua require('plenary')" -c "q" 2>/dev/null; then
    PLENARY_AVAILABLE=true
    USE_CLEAN_FLAG=""
elif nvim --clean --headless -c "set runtimepath+=~/.local/share/nvim/site/pack/vendor/start/plenary.nvim" -c "lua require('plenary')" -c "q" 2>/dev/null; then
    PLENARY_AVAILABLE=true
    USE_CLEAN_FLAG="--clean -c \"set runtimepath+=~/.local/share/nvim/site/pack/vendor/start/plenary.nvim\""
fi

if [ "$PLENARY_AVAILABLE" = false ]; then
    echo -e "${RED}❌ plenary.nvim not found. Please install plenary.nvim first.${NC}"
    echo "   Install with your plugin manager or clone:"
    echo "   git clone https://github.com/nvim-lua/plenary.nvim.git ~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"
    exit 1
fi
echo -e "${GREEN}✅ plenary.nvim found${NC}"

# Run tests
cd "$PROJECT_DIR"

echo ""
echo -e "${YELLOW}🏃 Running test suite...${NC}"
echo ""

# Test files in order
test_files=(
    "tests/twitch-chat/config_spec.lua"
    "tests/twitch-chat/auth_spec.lua"
    "tests/twitch-chat/buffer_spec.lua"
    "tests/twitch-chat/commands_spec.lua"
    "tests/twitch-chat/completion_spec.lua"
    "tests/twitch-chat/emotes_spec.lua"
    "tests/twitch-chat/error_resilience_spec.lua"
    "tests/twitch-chat/events_spec.lua"
    "tests/twitch-chat/filter_spec.lua"
    "tests/twitch-chat/health_spec.lua"
    "tests/twitch-chat/integration_spec.lua"
    "tests/twitch-chat/integration_advanced_spec.lua"
    "tests/twitch-chat/irc_spec.lua"
    "tests/twitch-chat/memory_leak_spec.lua"
    "tests/twitch-chat/performance_spec.lua"
    "tests/twitch-chat/telescope_spec.lua"
    "tests/twitch-chat/ui_spec.lua"
    "tests/twitch-chat/utils_spec.lua"
    "tests/twitch-chat/websocket_spec.lua"
)

failed_tests=()
passed_tests=()

for test_file in "${test_files[@]}"; do
    echo -e "${BLUE}📋 Running: $test_file${NC}"
    
    if [ -z "$USE_CLEAN_FLAG" ]; then
        TEST_CMD="nvim --headless -c \"PlenaryBustedFile $test_file\" -c \"q\""
    else
        TEST_CMD="nvim $USE_CLEAN_FLAG -c \"PlenaryBustedFile $test_file\" -c \"q\""
    fi
    
    if eval "$TEST_CMD" 2>&1; then
        echo -e "${GREEN}✅ PASSED: $(basename "$test_file")${NC}"
        passed_tests+=("$test_file")
    else
        echo -e "${RED}❌ FAILED: $(basename "$test_file")${NC}"
        failed_tests+=("$test_file")
    fi
    echo ""
done

# Run all tests together for comprehensive coverage
echo -e "${YELLOW}🔄 Running comprehensive test suite...${NC}"
if [ -z "$USE_CLEAN_FLAG" ]; then
    COMPREHENSIVE_CMD="nvim --headless -c \"PlenaryBustedDirectory tests/\" -c \"q\""
else
    COMPREHENSIVE_CMD="nvim $USE_CLEAN_FLAG -c \"PlenaryBustedDirectory tests/\" -c \"q\""
fi

if eval "$COMPREHENSIVE_CMD" 2>&1; then
    echo -e "${GREEN}✅ PASSED: Comprehensive test suite${NC}"
else
    echo -e "${RED}❌ FAILED: Comprehensive test suite${NC}"
    failed_tests+=("comprehensive")
fi

echo ""
echo "📊 Test Results Summary"
echo "======================"
echo -e "${GREEN}✅ Passed: ${#passed_tests[@]}${NC}"
echo -e "${RED}❌ Failed: ${#failed_tests[@]}${NC}"

if [ ${#passed_tests[@]} -gt 0 ]; then
    echo ""
    echo -e "${GREEN}Passed tests:${NC}"
    for test in "${passed_tests[@]}"; do
        echo -e "  ${GREEN}✅ $(basename "$test")${NC}"
    done
fi

if [ ${#failed_tests[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed tests:${NC}"
    for test in "${failed_tests[@]}"; do
        echo -e "  ${RED}❌ $(basename "$test")${NC}"
    done
    echo ""
    echo -e "${RED}💡 To debug failures, run individual tests with:${NC}"
    if [ -z "$USE_CLEAN_FLAG" ]; then
        echo "   nvim --headless -c \"PlenaryBustedFile tests/twitch-chat/[test_name]_spec.lua\" -c \"q\""
    else
        echo "   nvim $USE_CLEAN_FLAG -c \"PlenaryBustedFile tests/twitch-chat/[test_name]_spec.lua\" -c \"q\""
    fi
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 All tests passed! The plugin is ready for use.${NC}"
echo ""
echo -e "${BLUE}📝 Next steps:${NC}"
echo "   1. Set up your Twitch application (see README.md)"
echo "   2. Configure the plugin with your client_id"
echo "   3. Run :TwitchAuth to authenticate"
echo "   4. Connect to your favorite channel with :TwitchChat"
echo ""
echo -e "${YELLOW}📚 Documentation:${NC}"
echo "   - :help twitch-chat (vimdoc)"
echo "   - README.md (usage guide)"
echo "   - CHANGELOG.md (version history)"