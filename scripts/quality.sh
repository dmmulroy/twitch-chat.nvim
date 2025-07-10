#!/bin/bash

# quality.sh - Run comprehensive code quality checks
# Usage: ./scripts/quality.sh [--fix]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}🚀 Running comprehensive code quality checks...${NC}"
echo ""

# Track overall success
overall_success=true

# Function to run a check and track results
run_check() {
    local name="$1"
    local script="$2"
    local emoji="$3"
    
    echo -e "${BLUE}${emoji} ${name}${NC}"
    echo "----------------------------------------"
    
    if bash "$script"; then
        echo -e "${GREEN}✅ ${name} passed${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}❌ ${name} failed${NC}"
        echo ""
        overall_success=false
        return 1
    fi
}

# Make scripts executable
chmod +x scripts/*.sh

# 1. Code Formatting
if [[ "$1" == "--fix" ]]; then
    run_check "Code Formatting" "./scripts/format.sh" "🎨"
else
    echo -e "${BLUE}🎨 Code Formatting Check${NC}"
    echo "----------------------------------------"
    if ./scripts/format.sh --check; then
        echo -e "${GREEN}✅ Code Formatting Check passed${NC}"
        echo ""
    else
        echo -e "${RED}❌ Code Formatting Check failed${NC}"
        echo ""
        overall_success=false
    fi
fi

# 2. Linting
run_check "Lua Linting" "./scripts/lint.sh" "🔍"

# 3. Type Checking
run_check "Type Checking" "./scripts/typecheck.sh" "🔬"

# Summary
echo "========================================"
if [[ "$overall_success" == true ]]; then
    echo -e "${GREEN}🎉 All quality checks passed!${NC}"
    echo -e "${GREEN}✨ Your code is ready for production${NC}"
    exit 0
else
    echo -e "${RED}💥 Some quality checks failed${NC}"
    echo -e "${RED}🔧 Please address the issues above${NC}"
    
    if [[ "$1" != "--fix" ]]; then
        echo ""
        echo -e "${YELLOW}💡 Tip: Run with --fix to automatically format code${NC}"
        echo -e "${YELLOW}   ./scripts/quality.sh --fix${NC}"
    fi
    
    exit 1
fi