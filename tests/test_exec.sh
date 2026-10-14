#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

run touch "$WORK/created"
assert_false 'test mode does not execute' test -e "$WORK/created"
assert_contains 'test mode records command' "RUN: touch $WORK/created" "$(cat "$JACKTOOLS_COMMAND_LOG")"
assert_rc 'test mode return code configurable' 3 env JACKTOOLS_TEST_RUN_RC=3 bash -c "source '$ROOT/tests/test_helper.sh'; load_core; run true"

out=$(JACKTOOLS_DRY_RUN=1 run touch "$WORK/a file")
assert_false 'dry-run does not execute' test -e "$WORK/a file"
assert_eq 'dry-run prints quoted command' "[dry-run] touch $WORK/a\\ file" "$out"
assert_true 'command_exists finds bash' command_exists bash
assert_false 'command_exists rejects unknown' command_exists jt-no-such-command
finish_tests
