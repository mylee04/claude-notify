#!/bin/bash

# Simple test suite for Code-Notify

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
test_start() {
    echo -n "Testing $1... "
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    echo -e "${GREEN}PASS${RESET}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Change to project root
cd "$(dirname "$0")/.."

# Test 1: Main executable exists and is executable
test_start "main executable exists"
if [[ -x "bin/code-notify" ]]; then
    test_pass
else
    test_fail "bin/code-notify not found or not executable"
fi

# Test 2: Can show version
test_start "version command"
if ./bin/code-notify version 2>&1 | grep -q "version"; then
    test_pass
else
    test_fail "version command failed"
fi

# Test 3: Can show help
test_start "help command"
if ./bin/code-notify help 2>&1 | grep -q "USAGE"; then
    test_pass
else
    test_fail "help command failed"
fi

# Test 4: Library files exist
test_start "library files"
if [[ -f "lib/code-notify/utils/colors.sh" ]] && \
   [[ -f "lib/code-notify/utils/detect.sh" ]] && \
   [[ -f "lib/code-notify/core/config.sh" ]]; then
    test_pass
else
    test_fail "missing library files"
fi

# Test 5: Command routing (cn alias simulation)
test_start "cn command routing"
if CN_TEST=1 ./bin/code-notify help 2>&1 | grep -q "Code-Notify"; then
    test_pass
else
    test_fail "command routing failed"
fi

# Test 6: Check syntax of all shell scripts
test_start "shell script syntax"
SYNTAX_ERROR=0
for script in bin/code-notify lib/code-notify/**/*.sh; do
    if [[ -f "$script" ]]; then
        if ! bash -n "$script" 2>/dev/null; then
            SYNTAX_ERROR=1
            echo -e "\n  ${YELLOW}Syntax error in: $script${RESET}"
        fi
    fi
done
if [[ $SYNTAX_ERROR -eq 0 ]]; then
    test_pass
else
    test_fail "syntax errors found"
fi

# Summary
echo ""
echo "Test Summary:"
echo "============="
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${RESET}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${RESET}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${RESET}"
    exit 0
else
    echo -e "\n${RED}Some tests failed!${RESET}"
    exit 1
fi