#!/bin/bash
# Verification gate — run before committing or releasing.
# Usage: scripts/verify.sh [--quick]
#   --quick  skips the full build, only runs tests

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "${GREEN}✓${RESET} $1"; }
fail() { echo -e "${RED}✗${RESET} $1"; exit 1; }

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

echo -e "${BOLD}OpenPlaudit verification${RESET}"
echo "────────────────────────"

# 1. Build
if [[ "$QUICK" == false ]]; then
    echo -n "Building... "
    if swift build 2>&1 | tail -1; then
        pass "Build succeeded"
    else
        fail "Build failed"
    fi
fi

# 2. Tests
echo -n "Testing... "
if swift test 2>&1 | tail -5; then
    pass "All tests passed"
else
    fail "Tests failed"
fi

# 3. Forbidden patterns in source files
echo -n "Checking forbidden patterns... "
VIOLATIONS=0

# No hardcoded absolute paths to user home directories
if grep -r --include='*.swift' -n "$HOME" Sources/ 2>/dev/null | grep -v '// allow-path' | head -5; then
    echo "  ^ Hardcoded home directory path"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# No print() in production code (use os_log or Logger)
if grep -rn --include='*.swift' '^\s*print(' Sources/ 2>/dev/null | grep -v '// allow-print' | head -5; then
    echo "  ^ Use os_log/Logger instead of print() in production code"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# No secrets or tokens in source (case-sensitive to avoid matching Swift's `private` keyword)
if grep -rn --include='*.swift' 'PRIVATE_KEY\|SECRET_KEY\|API_KEY\|PASSW0RD\|hardcoded.*token\|= "sk-' Sources/ 2>/dev/null | grep -v '// allow-keyword' | head -5; then
    echo "  ^ Possible hardcoded secret"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

if [[ $VIOLATIONS -eq 0 ]]; then
    pass "No forbidden patterns"
else
    fail "$VIOLATIONS forbidden pattern violation(s)"
fi

# 4. Check for accidentally staged sensitive files
echo -n "Checking staged files... "
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
BLOCKED=false
for pattern in ".env" "credentials" ".p12" ".cer" ".key" "secret"; do
    if echo "$STAGED" | grep -qi "$pattern"; then
        echo "  Sensitive file staged: $(echo "$STAGED" | grep -i "$pattern")"
        BLOCKED=true
    fi
done
if [[ "$BLOCKED" == true ]]; then
    fail "Sensitive files in staging area"
else
    pass "No sensitive files staged"
fi

echo "────────────────────────"
echo -e "${GREEN}${BOLD}All checks passed${RESET}"
