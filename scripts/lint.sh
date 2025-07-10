#!/bin/bash

# lint.sh - Run comprehensive linting on all Lua files
# Usage: ./scripts/lint.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔍 Running comprehensive Lua linting...${NC}"

# Check if luacheck is installed
if ! command -v luacheck &> /dev/null; then
    echo -e "${RED}❌ Luacheck is not installed. Install with: brew install luacheck${NC}"
    exit 1
fi

# Check if we're in the right directory
if [[ ! -f ".luacheckrc" ]]; then
    echo -e "${RED}❌ .luacheckrc not found. Make sure you're in the project root.${NC}"
    exit 1
fi

# Run luacheck
echo -e "${BLUE}📋 Running Luacheck...${NC}"
luacheck_exit_code=0
luacheck . || luacheck_exit_code=$?

echo ""
echo -e "${BLUE}📊 Linting Summary:${NC}"

if [[ $luacheck_exit_code -eq 0 ]]; then
    echo -e "${GREEN}✅ No linting issues found!${NC}"
    exit 0
elif [[ $luacheck_exit_code -eq 1 ]]; then
    echo -e "${YELLOW}⚠️  Found warnings but no errors${NC}"
    echo -e "${YELLOW}💡 Consider fixing warnings for better code quality${NC}"
    exit 0
else
    echo -e "${RED}❌ Found critical linting errors${NC}"
    echo -e "${RED}🚨 Please fix errors before committing${NC}"
    exit 1
fi