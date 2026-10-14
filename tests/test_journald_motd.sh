#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

# journald and logrotate
mkdir -p "$JACKTOOLS_ROOT/etc"
printf 'weekly\nrotate 4\n#compress\ninclude /etc/logrotate.d\n' >"$JACKTOOLS_ROOT/etc/logrotate.conf"
journald_collect >/dev/null 2>&1 <<<$'lots\n\ny'
assert_eq 'default journal size' 200M "${CFG[JOURNAL_MAX]}"
assert_eq 'compress requested' on "${CFG[LOGROTATE_COMPRESS]}"
journald_apply
dropin="$JACKTOOLS_ROOT/etc/systemd/journald.conf.d/99-jacktools.conf"
assert_contains 'drop-in written' 'SystemMaxUse=200M' "$(cat "$dropin")"
assert_contains 'journald restarted' 'RUN: systemctl restart systemd-journald' "$(commands_run)"
assert_eq 'compress uncommented' $'weekly\nrotate 4\ncompress\ninclude /etc/logrotate.d' "$(cat "$JACKTOOLS_ROOT/etc/logrotate.conf")"
assert_true 'journald verify' journald_verify
reset_commands
journald_apply
assert_eq 'second apply runs nothing' '' "$(commands_run)"
printf 'weekly\ninclude /etc/logrotate.d\n' >"$JACKTOOLS_ROOT/etc/logrotate.conf"
journald_apply
assert_eq 'compress added before include' $'weekly\ncompress\ninclude /etc/logrotate.d' "$(cat "$JACKTOOLS_ROOT/etc/logrotate.conf")"

# MOTD
motd_dir="$JACKTOOLS_ROOT/etc/update-motd.d"
mkdir -p "$motd_dir" "$JACKTOOLS_ROOT/etc/default"
for script in 00-header 10-help-text 50-motd-news 91-release-upgrade; do printf '#!/bin/sh\n' >"$motd_dir/$script"; chmod 755 "$motd_dir/$script"; done
printf 'ENABLED=1\nURLS="x"\n' >"$JACKTOOLS_ROOT/etc/default/motd-news"
assert_rc 'motd declined' 1 quiet motd_collect <<<'n'
motd_collect >/dev/null <<<'y'
assert_contains 'plan lists help text' '10-help-text' "$(motd_plan)"
motd_apply
assert_false 'help text disabled' test -x "$motd_dir/10-help-text"
assert_false 'news script disabled' test -x "$motd_dir/50-motd-news"
assert_true 'header kept' test -x "$motd_dir/00-header"
assert_true 'release upgrade notice kept' test -x "$motd_dir/91-release-upgrade"
assert_eq 'news disabled' $'ENABLED=0\nURLS="x"' "$(cat "$JACKTOOLS_ROOT/etc/default/motd-news")"
assert_true 'motd verify' motd_verify
assert_contains 'motd compliant plan' 'già conforme' "$(motd_plan)"
finish_tests
