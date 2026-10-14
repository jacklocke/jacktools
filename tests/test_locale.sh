#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

mkdir -p "$JACKTOOLS_ROOT/etc/default"
printf '# generated\nLANG=C\nLC_TIME=it_IT.UTF-8\n' >"$JACKTOOLS_ROOT/etc/default/locale"
assert_eq 'current locale' C "$(locale_current)"
assert_eq 'normalize' 'it_it.utf8' "$(locale_normalize it_IT.UTF-8)"

locale_collect >/dev/null <<<'1'
assert_eq 'menu choice C.UTF-8' C.UTF-8 "${CFG[LOCALE]}"
locale_collect >/dev/null 2>&1 <<<$'4\nbad\nde_DE.UTF-8'
assert_eq 'custom locale validated' de_DE.UTF-8 "${CFG[LOCALE]}"
assert_rc 'menu cancel' 1 quiet locale_collect <<<'0'

CFG[LOCALE]=C.UTF-8
assert_contains 'plan shows change' 'LANG C → C.UTF-8' "$(locale_plan)"
locale_apply
assert_eq 'LANG replaced, other lines kept' $'# generated\nLANG=C.UTF-8\nLC_TIME=it_IT.UTF-8' "$(cat "$JACKTOOLS_ROOT/etc/default/locale")"
assert_false 'C.UTF-8 needs no locale-gen' grep -q locale-gen <<<"$(commands_run)"
assert_true 'verify passes' locale_verify
assert_true 'new shell flagged' test -n "${STATE_FLAGS[NEW_SHELL]:-}"

printf 'LANG="C.UTF-8"\n' >"$JACKTOOLS_ROOT/etc/default/locale"
assert_eq 'quoted LANG parsed' C.UTF-8 "$(locale_current)"
assert_contains 'quoted value compliant' 'già conforme' "$(locale_plan)"

rm "$JACKTOOLS_ROOT/etc/default/locale"
CFG[LOCALE]=zz_ZZ.UTF-8
if command -v locale-gen >/dev/null; then
    locale_apply
    assert_contains 'missing locale generated' 'RUN: locale-gen zz_ZZ.UTF-8' "$(commands_run)"
    assert_eq 'file created when missing' 'LANG=zz_ZZ.UTF-8' "$(cat "$JACKTOOLS_ROOT/etc/default/locale")"
else
    assert_rc 'missing locale-gen fails' 1 quiet locale_apply
fi
finish_tests
