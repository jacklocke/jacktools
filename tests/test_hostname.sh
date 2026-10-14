#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

mkdir -p "$JACKTOOLS_ROOT/etc"
printf 'oldname\n' >"$JACKTOOLS_ROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\toldname\n# comment\n::1\tip6-localhost\n' >"$JACKTOOLS_ROOT/etc/hosts"

assert_eq 'current hostname read from /etc/hostname' oldname "$(hostname_current)"
hostname_collect >/dev/null 2>&1 <<<$'bad.name\n-x\nnewname'
assert_eq 'collect re-asks until valid' newname "${CFG[HOSTNAME]}"
assert_rc 'empty answer cancels' 1 quiet hostname_collect <<<''
CFG[HOSTNAME]=newname

assert_contains 'plan describes change' 'oldname → newname' "$(hostname_plan)"
hostname_apply
assert_contains 'hostnamectl called' 'RUN: hostnamectl set-hostname newname' "$(commands_run)"
assert_eq 'hosts entry replaced' $'127.0.0.1\tlocalhost\n127.0.1.1\tnewname\n# comment\n::1\tip6-localhost' "$(cat "$JACKTOOLS_ROOT/etc/hosts")"
assert_true 'hosts backup created' quiet compgen -G "$JACKTOOLS_BACKUP_ROOT/hosts-*"

assert_eq '/etc/hostname written' newname "$(cat "$JACKTOOLS_ROOT/etc/hostname")"
assert_true 'verify passes' hostname_verify
assert_contains 'plan compliant after apply' 'già conforme' "$(hostname_plan)"
reset_commands
hostname_apply
assert_eq 'second apply runs no command' '' "$(commands_run)"

printf '127.0.0.1\tlocalhost\n' >"$JACKTOOLS_ROOT/etc/hosts"
hostname_apply
assert_contains 'missing 127.0.1.1 added' $'127.0.1.1\tnewname' "$(cat "$JACKTOOLS_ROOT/etc/hosts")"
finish_tests
