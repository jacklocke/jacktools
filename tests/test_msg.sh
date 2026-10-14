#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

assert_eq 'catalog it loaded' it "$JT_MSG_LANG"
assert_eq 'formatted message' 'JackTools 1.2' "$(msg_get main.version 1.2)"
assert_eq 'msg adds newline' $'JackTools 1\n.' "$(msg main.version 1; printf .)"
assert_eq 'missing key shown as [key]' '[no.such.key]' "$(msg_get no.such.key)"
assert_contains 'missing key logged' 'missing message key: no.such.key' "$(cat "$JACKTOOLS_TEST_LOG")"
assert_rc 'invalid language code rejected' 1 msg_load 'it;rm'
assert_rc 'unknown language rejected' 1 msg_load zz

# A malformed catalog must be refused without touching the loaded one.
fake_dir="$WORK/fake"
mkdir -p "$fake_dir/messages"
# shellcheck disable=SC2016 # Malicious input must stay literal.
for bad in 'MSG[a.b]="$(id)"' 'MSG[a.b]="`id`"' 'MSG[a.b]="x" ; rm -rf /' 'echo hi' 'MSG[a.b]=x'; do
    printf '%s\n' "$bad" >"$fake_dir/messages/xx.sh"
    rc=0; JACKTOOLS_DIR="$fake_dir" msg_load xx 2>/dev/null || rc=$?
    assert_eq "malformed line refused: $bad" 2 "$rc"
done
assert_eq 'previous catalog kept after refusal' it "$JT_MSG_LANG"
assert_eq 'previous messages kept after refusal' 'JackTools 1' "$(msg_get main.version 1)"

printf '# comment\n\nMSG[t.one]="uno %%s"\n' >"$fake_dir/messages/xx.sh"
JACKTOOLS_DIR="$fake_dir" msg_load xx
assert_eq 'custom catalog loaded' 'uno 1' "$(msg_get t.one 1)"
finish_tests
