#!/usr/bin/env bash
# Command execution (real, dry-run, test) and process-wide traps.
set -Eeuo pipefail

: "${JACKTOOLS_TEST_MODE:=0}"
: "${JACKTOOLS_DRY_RUN:=0}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

# run CMD [ARGS...]: every system-changing command goes through here.
# Never pass secrets as arguments: commands are printed in dry-run and logged.
run() {
    local rendered
    printf -v rendered ' %q' "$@"
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then
        printf '%s%s\n' "$(msg_get exec.dry_run_prefix)" "$rendered"
        return 0
    fi
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        printf 'RUN:%s\n' "$rendered" >>"${JACKTOOLS_COMMAND_LOG:-/dev/null}"
        return "${JACKTOOLS_TEST_RUN_RC:-0}"
    fi
    log_write CMD "${rendered# }"
    "$@"
}

core_on_error() {
    local rc="$1" line="$2"
    ui_error exec.unexpected_error "$line" "$rc"
}

core_on_signal() {
    ui_warn exec.interrupted
    exit 130
}

core_on_exit() {
    local rc="$1"
    fs_cleanup_temps
    log_write INFO "exit code $rc"
}

core_install_traps() {
    trap 'core_on_error "$?" "$LINENO"' ERR
    trap 'core_on_signal' INT TERM
    trap 'core_on_exit "$?"' EXIT
}
