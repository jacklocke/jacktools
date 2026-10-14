#!/usr/bin/env bash
# Step results and final summary, kept in execution order.
set -Eeuo pipefail

declare -ga STATE_ORDER=()
declare -gA STATE_STATUS=()
declare -gA STATE_FLAGS=()

# Display keys used dynamically by state_status_label and print_summary:
# msg-keys: state.status.OK state.status.SKIPPED state.status.CANCELLED state.status.FAILED
# msg-keys: state.status.RESTORED state.status.NOT_RUN
# msg-keys: state.flag.REBOOT state.flag.NEW_SHELL state.flag.NETWORK_RESTORED
STATE_CODES=(OK SKIPPED CANCELLED FAILED RESTORED NOT_RUN)
STATE_FLAG_NAMES=(REBOOT NEW_SHELL NETWORK_RESTORED)

state_is_code() {
    local code
    for code in "${STATE_CODES[@]}"; do [[ "$code" == "$1" ]] && return 0; done
    return 1
}

# state_set NAME CODE: NAME is a message key or a literal (e.g. a package name).
state_set() {
    local name="$1" code="$2"
    state_is_code "$code" || return 1
    [[ -v "STATE_STATUS[$name]" ]] || STATE_ORDER+=("$name")
    STATE_STATUS["$name"]="$code"
    log_write INFO "state $name: $code"
}

state_get() { printf '%s' "${STATE_STATUS[$1]:-}"; }

state_flag() {
    local flag="$1" name
    for name in "${STATE_FLAG_NAMES[@]}"; do
        if [[ "$name" == "$flag" ]]; then STATE_FLAGS["$flag"]=1; return 0; fi
    done
    return 1
}

state_has_failures() {
    local name
    for name in "${STATE_ORDER[@]}"; do [[ "${STATE_STATUS[$name]}" == FAILED ]] && return 0; done
    return 1
}

state_label() {
    if [[ -v "MSG[$1]" ]]; then msg_get "$1"; else printf '%s' "$1"; fi
}

# print_summary: returns 1 when any step FAILED.
print_summary() {
    local name flag
    printf '\n%-34s %s\n' "$(msg_get state.summary.step)" "$(msg_get state.summary.status)"
    printf '%-34s %s\n' '----------------------------------' '----------------'
    for name in "${STATE_ORDER[@]}"; do
        printf '%-34s %s\n' "$(state_label "$name")" "$(msg_get "state.status.${STATE_STATUS[$name]}")"
    done
    printf '\n'
    msg state.summary.log "$(log_target)"
    msg state.summary.backup "$JACKTOOLS_BACKUP_ROOT"
    for flag in "${STATE_FLAG_NAMES[@]}"; do
        [[ -v "STATE_FLAGS[$flag]" ]] && msg "state.flag.$flag"
    done
    ! state_has_failures
}
