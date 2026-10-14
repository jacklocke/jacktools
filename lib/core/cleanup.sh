#!/usr/bin/env bash
# Cleanup: temporary copies of JackTools first, then (separate question, default no)
# the backups JackTools created. Applied configurations and the log are never touched.
set -Eeuo pipefail

CLEANUP_TMP_DIR="/tmp/jacktools"
CLEANUP_BOOTSTRAP="/tmp/jacktools-bootstrap.sh"
CLEANUP_BACKUP_DEFAULT="/var/backups/jacktools"

cleanup_tmp_dir() { root_path "$CLEANUP_TMP_DIR"; }
cleanup_bootstrap() { root_path "$CLEANUP_BOOTSTRAP"; }

cleanup_temp_present() {
    local dir bootstrap
    dir=$(cleanup_tmp_dir); bootstrap=$(cleanup_bootstrap)
    [[ -e "$dir" || -L "$dir" || -e "$bootstrap" || -L "$bootstrap" ]]
}

# The backup root may be removed only when it is the expected directory (any path in tests).
cleanup_backup_root_safe() {
    local dir="$JACKTOOLS_BACKUP_ROOT"
    [[ -n "$dir" && "$dir" != / && -d "$dir" && ! -L "$dir" ]] || return 1
    [[ "$JACKTOOLS_TEST_MODE" == 1 || "$dir" == "$CLEANUP_BACKUP_DEFAULT" ]]
}

cleanup_backup_count() { find "$JACKTOOLS_BACKUP_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l; }

cleanup_temp() {
    local dir bootstrap
    dir=$(cleanup_tmp_dir); bootstrap=$(cleanup_bootstrap)
    if ! cleanup_temp_present; then
        ui_info cleanup.temp_absent
        return 0
    fi
    if [[ -L "$dir" ]]; then
        ui_error cleanup.unsafe_path "$dir"
        state_set cleanup.state.temp FAILED
        return 1
    fi
    if ! ui_confirm cleanup.confirm_temp "$CLEANUP_TMP_DIR" "$CLEANUP_BOOTSTRAP"; then
        state_set cleanup.state.temp NOT_RUN
        return 0
    fi
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then
        msg cleanup.dry_run
        state_set cleanup.state.temp NOT_RUN
        return 0
    fi
    rm -rf -- "$dir"
    rm -f -- "$bootstrap"
    if cleanup_temp_present; then
        ui_error cleanup.temp_left
        state_set cleanup.state.temp FAILED
        return 1
    fi
    log_write INFO "temporary copies removed"
    ui_info cleanup.temp_done
    state_set cleanup.state.temp OK
}

cleanup_backups() {
    local count
    [[ -d "$JACKTOOLS_BACKUP_ROOT" ]] || return 0
    count=$(cleanup_backup_count)
    (( count > 0 )) || return 0
    if ! cleanup_backup_root_safe; then
        ui_error cleanup.unsafe_path "$JACKTOOLS_BACKUP_ROOT"
        state_set cleanup.state.backups FAILED
        return 1
    fi
    msg cleanup.backups_found "$count" "$(du -sh -- "$JACKTOOLS_BACKUP_ROOT" 2>/dev/null | cut -f1)" "$JACKTOOLS_BACKUP_ROOT"
    ui_warn cleanup.backups_warning
    if ! ui_confirm cleanup.confirm_backups; then
        state_set cleanup.state.backups NOT_RUN
        return 0
    fi
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then
        msg cleanup.dry_run
        state_set cleanup.state.backups NOT_RUN
        return 0
    fi
    find "$JACKTOOLS_BACKUP_ROOT" -mindepth 1 -delete
    if (( $(cleanup_backup_count) > 0 )); then
        ui_error cleanup.backups_left
        state_set cleanup.state.backups FAILED
        return 1
    fi
    log_write INFO "backups removed from $JACKTOOLS_BACKUP_ROOT"
    ui_info cleanup.backups_done
    state_set cleanup.state.backups OK
}

# cleanup_run: both parts always run; returns 1 when either failed.
cleanup_run() {
    local rc=0
    ui_title cleanup.title
    msg cleanup.kept "$(log_target)"
    cleanup_temp || rc=1
    cleanup_backups || rc=1
    return "$rc"
}
