#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

state_set zeta OK
state_set alpha SKIPPED
state_set middle CANCELLED
state_set alpha OK
assert_eq 'insertion order kept, updates do not reorder' 'zeta alpha middle' "${STATE_ORDER[*]}"
assert_eq 'status updated' OK "$(state_get alpha)"
assert_rc 'unknown status code refused' 1 state_set beta DONE
assert_rc 'no failures yet' 0 quiet print_summary

summary=$(print_summary)
assert_contains 'summary translates status' 'ANNULLATO' "$summary"
first=$(grep -n '^zeta' <<<"$summary" | cut -d: -f1)
last=$(grep -n '^middle' <<<"$summary" | cut -d: -f1)
assert_true 'summary follows execution order' test "$first" -lt "$last"

state_flag REBOOT
assert_rc 'unknown flag refused' 1 state_flag SOMETHING
assert_contains 'flag message shown' 'Riavvio consigliato.' "$(print_summary)"
state_set network FAILED
assert_rc 'failure makes summary return 1' 1 quiet print_summary
finish_tests
