#!/bin/bash

# format.sh - Format all Lua files with StyLua
# Usage: ./scripts/format.sh [--check]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🎨 Formatting Lua files with StyLua...${NC}"

# Check if stylua is installed
if ! command -v stylua &> /dev/null; then
    echo -e "${RED}❌ StyLua is not installed. Install with: brew install stylua${NC}"
    exit 1
fi

# Check if we're in the right directory
if [[ ! -f "stylua.toml" ]]; then
    echo -e "${RED}❌ stylua.toml not found. Make sure you're in the project root.${NC}"
    exit 1
fi

# Run stylua
if [[ "$1" == "--check" ]]; then
    echo -e "🔍 Checking code formatting..."
    if stylua --check .; then
        echo -e "${GREEN}✅ All files are properly formatted!${NC}"
    else
        echo -e "${RED}❌ Some files need formatting. Run: ./scripts/format.sh${NC}"
        exit 1
    fi
else
    echo -e "🔧 Formatting files..."
    stylua .
    echo -e "${GREEN}✅ Code formatting complete!${NC}"
fi