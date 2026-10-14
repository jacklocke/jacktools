#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

tmpdir="$JACKTOOLS_ROOT/tmp/jacktools"
bootstrap="$JACKTOOLS_ROOT/tmp/jacktools-bootstrap.sh"
setup() {
    STATE_ORDER=(); STATE_STATUS=()
    mkdir -p "$tmpdir/lib" "$JACKTOOLS_BACKUP_ROOT/hosts-1"
    touch "$tmpdir/jacktools.sh" "$bootstrap" "$JACKTOOLS_BACKUP_ROOT/fstab-1"
}

# Temporary copies yes, backups no (the default answer).
setup
cleanup_run >/dev/null 2>&1 <<<$'y\n'
assert_false 'temporary directory removed' test -e "$tmpdir"
assert_false 'bootstrap removed' test -e "$bootstrap"
assert_eq 'temp state OK' OK "$(state_get cleanup.state.temp)"
assert_true 'backups kept by default' test -e "$JACKTOOLS_BACKUP_ROOT/fstab-1"
assert_eq 'backups state not run' NOT_RUN "$(state_get cleanup.state.backups)"

# The backup question is always asked, even when the temporary copies are kept.
setup
cleanup_run >"$WORK/out" 2>&1 <<<$'n\ny'
out=$(cat "$WORK/out")
assert_contains 'backup summary shown' 'Backup creati da JackTools: 2 elementi' "$out"
assert_true 'temporary copies kept when declined' test -e "$tmpdir/jacktools.sh"
assert_eq 'backup directory emptied' 0 "$(find "$JACKTOOLS_BACKUP_ROOT" -mindepth 1 | wc -l)"
assert_true 'backup root itself kept' test -d "$JACKTOOLS_BACKUP_ROOT"
assert_eq 'backups state OK' OK "$(state_get cleanup.state.backups)"

# No backups: only the temporary question.
setup
find "$JACKTOOLS_BACKUP_ROOT" -mindepth 1 -delete
cleanup_run >/dev/null 2>&1 <<<'y'
assert_eq 'no backup question without backups' '' "$(state_get cleanup.state.backups)"

# Dry-run deletes nothing.
setup
JACKTOOLS_DRY_RUN=1 cleanup_run >/dev/null 2>&1 <<<$'y\ny'
assert_true 'dry-run keeps temporary copies' test -e "$tmpdir/jacktools.sh"
assert_true 'dry-run keeps backups' test -e "$JACKTOOLS_BACKUP_ROOT/fstab-1"

# Unsafe paths are refused.
rm -rf "$tmpdir"; ln -s "$WORK" "$tmpdir"
assert_rc 'symlinked temp dir refused' 1 quiet cleanup_temp </dev/null
assert_true 'symlink target untouched' test -d "$WORK"
rm -f "$tmpdir"
JACKTOOLS_TEST_MODE=0 JACKTOOLS_BACKUP_ROOT="$WORK/backups"
assert_false 'unexpected backup root refused outside tests' cleanup_backup_root_safe
JACKTOOLS_TEST_MODE=1
JACKTOOLS_BACKUP_ROOT=/
assert_false 'root directory never a backup root' cleanup_backup_root_safe
finish_tests
