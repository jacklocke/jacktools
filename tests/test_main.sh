#!/usr/bin/env bash
# Command-line behaviour of jacktools.sh (no root, nothing executed).
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"

jt() { NO_COLOR=1 JACKTOOLS_TEST_MODE=1 bash "$ROOT/jacktools.sh" "$@"; }

assert_contains 'help shows usage' 'Uso: jacktools.sh' "$(jt help)"
assert_contains '--help shows usage' '--dry-run' "$(jt --help)"
assert_contains 'version' 'JackTools 2.0.0-dev' "$(jt version)"
assert_rc 'unknown command fails' 1 quiet jt nope
assert_contains 'unknown command reported' 'comando sconosciuto: nope' "$(jt nope 2>&1 || true)"
assert_rc 'unknown option fails' 1 quiet jt --nope
assert_rc 'two commands fail' 1 quiet jt menu all
assert_rc '--lang without value fails' 1 quiet jt --lang
assert_contains 'unknown language falls back' 'lingua zz non disponibile' "$(jt --lang zz version 2>&1)"
assert_contains '--lang=it accepted' 'JackTools' "$(jt --lang=it version)"
assert_rc '--config not available yet' 1 quiet jt all --config /dev/null

# End to end in a fake root: disclaimer, questions, plan, summary.
WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/root/etc" "$WORK/root/run/systemd/system"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$WORK/root/etc/os-release"
printf 'oldname\n' >"$WORK/root/etc/hostname"
printf '127.0.1.1\toldname\n' >"$WORK/root/etc/hosts"
jtroot() { JACKTOOLS_ROOT="$WORK/root" JACKTOOLS_BACKUP_ROOT="$WORK/backups" JACKTOOLS_TEST_VIRT=none jt "$@"; }

out=$(jtroot hostname --dry-run 2>&1 <<<$' \nnewname')
assert_contains 'dry-run shows plan' 'oldname → newname' "$out"
assert_contains 'dry-run summary' 'NON ESEGUITA' "$out"
assert_eq 'dry-run leaves hosts untouched' $'127.0.1.1\toldname' "$(cat "$WORK/root/etc/hosts")"

out=$(jtroot hostname 2>&1 <<<$' \nnewname\ny') && rc=0 || rc=$?
assert_eq 'hostname command exit code' 0 "$rc"
assert_eq 'hosts updated' $'127.0.1.1\tnewname' "$(cat "$WORK/root/etc/hosts")"
assert_contains 'summary OK' 'OK' "$out"

out=$(jtroot menu 2>&1 <<<$' \n2\n0\n0') && rc=0 || rc=$?
assert_eq 'menu navigation exits cleanly' 0 "$rc"
assert_contains 'system submenu shown' 'Tutta la fase Sistema' "$out"
assert_rc 'disclaimer refused exits 0 without changes' 0 quiet jtroot hostname <<<'x'
# --config with --yes: no question at all (stdin closed), file values applied.
mkdir -p "$WORK/root/etc/default"
printf 'STEPS="hostname locale"\nHOSTNAME=cfgname\nLOCALE="C.UTF-8"\n' >"$WORK/server.conf"
chmod 600 "$WORK/server.conf"
out=$(jtroot all --config "$WORK/server.conf" --yes 2>&1 </dev/null) && rc=0 || rc=$?
assert_eq 'config run exit code' 0 "$rc"
assert_eq 'hostname from config' $'127.0.1.1\tcfgname' "$(cat "$WORK/root/etc/hosts")"
assert_eq 'locale from config' 'LANG=C.UTF-8' "$(cat "$WORK/root/etc/default/locale")"
assert_false 'no disclaimer with --yes' grep -q 'ATTENZIONE' <<<"$out"
assert_rc '--yes without --config refused' 1 quiet jtroot all --yes </dev/null
assert_rc '--config with a single step refused' 1 quiet jtroot hostname --config "$WORK/server.conf" </dev/null
chmod 666 "$WORK/server.conf"
assert_rc 'unsafe config file refused' 1 quiet jtroot all --config "$WORK/server.conf" --yes </dev/null
chmod 600 "$WORK/server.conf"
# Without --yes the disclaimer and the final confirmation are still asked.
out=$(jtroot all --config "$WORK/server.conf" 2>&1 <<<$' \nn') || true
assert_contains 'config run still shows the plan' 'Riepilogo delle modifiche' "$out"
assert_contains 'declined config run is cancelled' 'ANNULLATO' "$out"

# Full configuration, dry-run: one checklist with every phase in order.
out=$(jtroot all --dry-run 2>&1 <<<$' \nq') || true
checklist=$(sed -n '/Seleziona i passi/,/Numeri da attivare/p' <<<"$out")
first=$(grep -n 'Hostname' <<<"$checklist" | head -1 | cut -d: -f1)
last=$(grep -n "Eliminazione dell'utente ubuntu" <<<"$checklist" | cut -d: -f1)
assert_true 'full checklist runs from system to final phase' test "$first" -lt "$last"
assert_contains 'security steps listed' 'Firewall UFW' "$checklist"
finish_tests
