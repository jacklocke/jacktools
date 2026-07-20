#!/usr/bin/env bash
set -Eeuo pipefail

TESTS_RUN=0
TESTS_FAILED=0

pass() { printf 'ok - %s\n' "$1"; TESTS_RUN=$((TESTS_RUN + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); }
assert_true() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
assert_false() { local name="$1"; shift; if "$@"; then fail "$name"; else pass "$name"; fi; }
assert_eq() { local name="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then pass "$name"; else printf '  atteso: %s\n  ottenuto: %s\n' "$expected" "$actual" >&2; fail "$name"; fi; }
finish_tests() { printf '1..%d\n' "$TESTS_RUN"; (( TESTS_FAILED == 0 )); }
