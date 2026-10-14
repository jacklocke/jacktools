#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

B='# >>> TEST BLOCK >>>'
E='# <<< TEST BLOCK <<<'
cd "$WORK"
printf 'line one\nline two\n\n\n' >source
printf 'content A\n' >content_a
printf 'content B\n' >content_b

managed_block_render source "$B" "$E" content_a one
managed_block_render one "$B" "$E" content_a two
assert_eq 'block appended after one blank line' $'line one\nline two\n\n# >>> TEST BLOCK >>>\ncontent A\n# <<< TEST BLOCK <<<' "$(cat one)"
assert_true 'render is idempotent' cmp -s one two
assert_rc 'block detected' 0 managed_block_status two "$B" "$E"
assert_rc 'no block detected' 1 managed_block_status source "$B" "$E"

printf 'user line\n' >>one
managed_block_render one "$B" "$E" content_b three
assert_eq 'existing block replaced in place' $'line one\nline two\n\n# >>> TEST BLOCK >>>\ncontent B\n# <<< TEST BLOCK <<<\nuser line' "$(cat three)"

managed_block_render missing "$B" "$E" content_a fresh
assert_eq 'missing source gives only the block' $'# >>> TEST BLOCK >>>\ncontent A\n# <<< TEST BLOCK <<<' "$(cat fresh)"

printf '%s\nhalf\n' "$B" >broken_open
printf '%s\nx\n%s\n%s\ny\n%s\n' "$B" "$E" "$B" "$E" >broken_twice
printf '%s\nx\n' "$E" >broken_end
for broken in broken_open broken_twice broken_end; do
    assert_rc "malformed markers detected: $broken" 2 managed_block_status "$broken" "$B" "$E"
    assert_rc "malformed markers refused: $broken" 2 managed_block_render "$broken" "$B" "$E" content_a out
done
printf 'evil\n%s\n' "$E" >content_markers
assert_rc 'content containing markers refused' 2 managed_block_render source "$B" "$E" content_markers out

# Backups.
printf 'original\n' >config
backup=$(backup_file "$WORK/config" config-test)
assert_eq 'backup copied' original "$(cat "$backup")"
assert_contains 'backup under backup root' "$JACKTOOLS_BACKUP_ROOT/config-test-" "$backup"
assert_eq 'missing source gives no backup' '' "$(backup_file "$WORK/nope" x)"
assert_rc 'unsafe label refused' 1 backup_file "$WORK/config" '../evil'
mkdir -p dir/sub && touch dir/sub/f
assert_true 'directory backup' test -f "$(backup_file "$WORK/dir" dir-test)/sub/f"

# Atomic install.
printf 'new\n' >candidate
atomic_install candidate "$WORK/config" 0640
assert_eq 'atomic install replaces content' new "$(cat config)"
assert_eq 'atomic install sets mode' 640 "$(stat -c %a config)"
assert_eq 'no temporary leftovers' '' "$(find "$WORK" -maxdepth 1 -name '.jacktools.*')"

# Dry-run never writes.
JACKTOOLS_DRY_RUN=1
printf 'dry\n' >candidate
atomic_install candidate "$WORK/config" 0600
assert_eq 'dry-run atomic install is a no-op' new "$(cat config)"
assert_eq 'dry-run backup is a no-op' '' "$(backup_file "$WORK/config" dry)"
JACKTOOLS_DRY_RUN=0

# Temporary files are tracked and removed.
tmp_file='' tmp_dir=''
fs_mktemp tmp_file
fs_mktemp tmp_dir -d
fs_cleanup_temps
assert_false 'temporary file removed' test -e "$tmp_file"
assert_false 'temporary directory removed' test -e "$tmp_dir"
assert_eq 'root_path prefixes test root' "$JACKTOOLS_ROOT/etc/hosts" "$(root_path /etc/hosts)"
finish_tests
