#!/bin/bash

# typecheck.sh - Run typechecking with lua-language-server
# Usage: ./scripts/typecheck.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔬 Running type checking with Lua Language Server...${NC}"

# Check if lua-language-server is installed
if ! command -v lua-language-server &> /dev/null; then
    echo -e "${RED}❌ lua-language-server is not installed. Install with: brew install lua-language-server${NC}"
    exit 1
fi

# Check if we're in the right directory
if [[ ! -f ".luarc.json" ]]; then
    echo -e "${RED}❌ .luarc.json not found. Make sure you're in the project root.${NC}"
    exit 1
fi

# Create temp log file
LOG_FILE="/tmp/luals-typecheck-$(date +%s)-$$.log"

echo -e "${BLUE}🔍 Running diagnostics...${NC}"

# Run lua-language-server check
luals_exit_code=0
lua-language-server --check . --logpath="$LOG_FILE" 2>&1 || luals_exit_code=$?

# Count problems
if [[ -f "$LOG_FILE" ]]; then
    error_count=$(grep -c "Error" "$LOG_FILE" 2>/dev/null || echo "0")
    warning_count=$(grep -c "Warning" "$LOG_FILE" 2>/dev/null || echo "0")
else
    error_count=0
    warning_count=0
fi

echo ""
echo -e "${BLUE}📊 Type Checking Summary:${NC}"
echo -e "   Errors: ${error_count}"
echo -e "   Warnings: ${warning_count}"

# Cleanup
rm -f "$LOG_FILE"

if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
    echo -e "${GREEN}✅ No type checking issues found!${NC}"
    exit 0
elif [[ $error_count -eq 0 ]]; then
    echo -e "${YELLOW}⚠️  Found ${warning_count} warnings but no errors${NC}"
    echo -e "${YELLOW}💡 Consider addressing warnings for better type safety${NC}"
    exit 0
else
    echo -e "${RED}❌ Found ${error_count} type errors${NC}"
    echo -e "${RED}🚨 Please fix type errors before committing${NC}"
    exit 1
fi