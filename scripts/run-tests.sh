#!/bin/bash
# Quick test runner script
# Runs all tests before committing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "==============================="
echo "Mole Test Runner"
echo "==============================="
echo ""

# Track failures
FAILED=0

# 1. ShellCheck
echo "1. Running ShellCheck..."
if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck mole bin/*.sh 2> /dev/null &&
        find lib -name "*.sh" -type f -exec shellcheck {} + 2> /dev/null; then
        printf "${GREEN}✓ ShellCheck passed${NC}\n"
    else
        printf "${RED}✗ ShellCheck failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}⚠ ShellCheck not installed, skipping${NC}\n"
fi
echo ""

# 2. Syntax Check
echo "2. Running syntax check..."
if bash -n mole &&
    bash -n bin/*.sh 2> /dev/null &&
    find lib -name "*.sh" -type f -exec bash -n {} \; 2> /dev/null; then
    printf "${GREEN}✓ Syntax check passed${NC}\n"
else
    printf "${RED}✗ Syntax check failed${NC}\n"
    ((FAILED++))
fi
echo ""

# 3. Unit Tests
echo "3. Running unit tests..."
if command -v bats > /dev/null 2>&1; then
    # Note: bats might detect non-TTY and suppress color.
    # Adding --tap prevents spinner issues in background.
    if bats tests/*.bats; then
        printf "${GREEN}✓ Unit tests passed${NC}\n"
    else
        printf "${RED}✗ Unit tests failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}⚠ Bats not installed, skipping unit tests${NC}\n"
    echo "  Install with: brew install bats-core"
fi
echo ""

# 4. Go Tests
echo "4. Running Go tests..."
if command -v go > /dev/null 2>&1; then
    if go build ./... && go vet ./cmd/... && go test ./cmd/...; then
        printf "${GREEN}✓ Go tests passed${NC}\n"
    else
        printf "${RED}✗ Go tests failed${NC}\n"
        ((FAILED++))
    fi
else
    printf "${YELLOW}⚠ Go not installed, skipping Go tests${NC}\n"
fi
echo ""

# 5. Module Loading Test
echo "5. Testing module loading..."
if bash -c 'source lib/core/common.sh && echo "OK"' > /dev/null 2>&1; then
    printf "${GREEN}✓ Module loading passed${NC}\n"
else
    printf "${RED}✗ Module loading failed${NC}\n"
    ((FAILED++))
fi
echo ""

# 6. Integration Tests
echo "6. Running integration tests..."
export MOLE_MAX_PARALLEL_JOBS=30
if ./bin/clean.sh --dry-run > /dev/null 2>&1; then
    printf "${GREEN}✓ Clean dry-run passed${NC}\n"
else
    printf "${RED}✗ Clean dry-run failed${NC}\n"
    ((FAILED++))
fi
echo ""

# Summary
echo "==============================="
if [[ $FAILED -eq 0 ]]; then
    printf "${GREEN}All tests passed!${NC}\n"
    echo ""
    echo "You can now commit your changes."
    exit 0
else
    printf "${RED}$FAILED test(s) failed!${NC}\n"
    echo ""
    echo "Please fix the failing tests before committing."
    exit 1
fi
