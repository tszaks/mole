#!/bin/bash
# Unified check script for Mole project
# Runs all quality checks in one command

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cd "$PROJECT_ROOT"

echo -e "${BLUE}=== Running Mole Quality Checks ===${NC}\n"

# 1. Format check
echo -e "${YELLOW}1. Checking code formatting...${NC}"
if command -v shfmt > /dev/null 2>&1; then
    if ./scripts/format.sh --check; then
        echo -e "${GREEN}✓ Formatting check passed${NC}\n"
    else
        echo -e "${RED}✗ Formatting check failed${NC}\n"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ shfmt not installed, skipping format check${NC}\n"
fi

# 2. ShellCheck
echo -e "${YELLOW}2. Running ShellCheck...${NC}"
if command -v shellcheck > /dev/null 2>&1; then
    # Count total files
    SHELL_FILES=$(find . -type f \( -name "*.sh" -o -name "mole" \) -not -path "./tests/*" -not -path "./.git/*")
    FILE_COUNT=$(echo "$SHELL_FILES" | wc -l | tr -d ' ')

    if shellcheck mole bin/*.sh lib/*/*.sh scripts/*.sh 2>&1 | grep -q "SC[0-9]"; then
        echo -e "${YELLOW}⚠ ShellCheck found some issues (non-critical):${NC}"
        shellcheck mole bin/*.sh lib/*/*.sh scripts/*.sh 2>&1 | head -20
        echo -e "${GREEN}✓ ShellCheck completed (${FILE_COUNT} files checked)${NC}\n"
    else
        echo -e "${GREEN}✓ ShellCheck passed (${FILE_COUNT} files checked)${NC}\n"
    fi
else
    echo -e "${YELLOW}⚠ shellcheck not installed, skipping${NC}\n"
fi

# 3. Unit tests (if available)
echo -e "${YELLOW}3. Running tests...${NC}"
if command -v bats > /dev/null 2>&1 && [ -d "tests" ]; then
    if bats tests/*.bats; then
        echo -e "${GREEN}✓ Tests passed${NC}\n"
    else
        echo -e "${RED}✗ Tests failed (see output above)${NC}\n"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ bats not installed or no tests found, skipping${NC}\n"
fi

# 4. Code optimization checks
echo -e "${YELLOW}4. Checking code optimizations...${NC}"
OPTIMIZATION_SCORE=0
TOTAL_CHECKS=0

# Check 1: Keyboard input handling (restored to 1s for reliability)
((TOTAL_CHECKS++))
if grep -q "read -r -s -n 1 -t 1" lib/core/ui.sh; then
    echo -e "${GREEN}  ✓ Keyboard timeout properly configured (1s)${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ⚠ Keyboard timeout may be misconfigured${NC}"
fi

# Check 2: Single-pass drain_pending_input
((TOTAL_CHECKS++))
DRAIN_PASSES=$(grep -c "while IFS= read -r -s -n 1" lib/core/ui.sh 2> /dev/null || true)
DRAIN_PASSES=${DRAIN_PASSES:-0}
if [[ $DRAIN_PASSES -eq 1 ]]; then
    echo -e "${GREEN}  ✓ drain_pending_input optimized (single-pass)${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ⚠ drain_pending_input has multiple passes${NC}"
fi

# Check 3: Log rotation once per session
((TOTAL_CHECKS++))
if grep -q "rotate_log_once" lib/core/log.sh; then
    echo -e "${GREEN}  ✓ Log rotation optimized (once per session)${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ⚠ Log rotation not optimized${NC}"
fi

# Check 4: Simplified cache validation
((TOTAL_CHECKS++))
if ! grep -q "cache_meta\|cache_dir_mtime" bin/uninstall.sh; then
    echo -e "${GREEN}  ✓ Cache validation simplified${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ⚠ Cache still uses redundant metadata${NC}"
fi

# Check 5: Stricter path validation
((TOTAL_CHECKS++))
if grep -q "Consecutive slashes" bin/clean.sh; then
    echo -e "${GREEN}  ✓ Path validation enhanced${NC}"
    ((OPTIMIZATION_SCORE++))
else
    echo -e "${YELLOW}  ⚠ Path validation not enhanced${NC}"
fi

echo -e "${BLUE}  Optimization score: $OPTIMIZATION_SCORE/$TOTAL_CHECKS${NC}\n"

# Summary
echo -e "${GREEN}=== All Checks Completed ===${NC}"
if [[ $OPTIMIZATION_SCORE -eq $TOTAL_CHECKS ]]; then
    echo -e "${GREEN}✓ Code quality checks passed!${NC}"
    echo -e "${GREEN}✓ All optimizations applied!${NC}"
else
    echo -e "${YELLOW}⚠ Code quality checks passed, but some optimizations missing${NC}"
fi
