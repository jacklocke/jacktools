#!/usr/bin/env bash
# Static analysis: every script must be clean for ShellCheck (settings in .shellcheckrc).
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf '# SKIP shellcheck not installed\n'
    finish_tests
    exit 0
fi
cd "$ROOT"
for script in bootstrap.sh jacktools.sh lib/*/*.sh tests/*.sh tools/*.sh; do
    if out=$(shellcheck -f gcc "$script" 2>&1); then pass "shellcheck: $script"; else printf '%s\n' "$out" >&2; fail "shellcheck: $script"; fi
done
finish_tests
