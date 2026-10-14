#!/usr/bin/env bash
# Step "time": timezone and NTP synchronisation (NTP is left to the host in containers).
set -Eeuo pipefail

time_current_zone() {
    local link zone=''
    link=$(readlink -- "$(root_path /etc/localtime)" 2>/dev/null || true)
    if [[ "$link" == */zoneinfo/* ]]; then
        zone=${link##*/zoneinfo/}
    elif [[ -r "$(root_path /etc/timezone)" ]]; then
        IFS= read -r zone <"$(root_path /etc/timezone)" || true
    fi
    printf '%s' "$zone"
}

time_ntp_enabled() {
    [[ "$(timedatectl show -p NTP --value 2>/dev/null || true)" == yes ]]
}

time_ntp_supported() { [[ "$ENV_VIRT_KIND" != container ]]; }

time_collect() {
    local current answer
    current=$(time_current_zone)
    msg time.current "${current:-?}"
    while true; do
        ui_prompt answer time.prompt "${current:-?}" || return 1
        answer="${answer:-$current}"
        [[ -n "$answer" ]] || return 1
        if valid_timezone "$answer"; then CFG[TIMEZONE]="$answer"; break; fi
        ui_warn time.invalid
    done
    CFG[NTP]=keep
    if time_ntp_supported; then
        ui_confirm time.ntp_confirm && CFG[NTP]=on
    else
        msg time.ntp_container
    fi
    return 0
}

time_plan() {
    local current changes=0
    current=$(time_current_zone)
    if [[ "$current" != "${CFG[TIMEZONE]}" ]]; then msg time.plan_zone "${current:-?}" "${CFG[TIMEZONE]}"; changes=1; fi
    if [[ "${CFG[NTP]}" == on ]] && ! time_ntp_enabled; then msg time.plan_ntp; changes=1; fi
    (( changes )) || msg steps.plan.compliant
}

time_apply() {
    if [[ "$(time_current_zone)" != "${CFG[TIMEZONE]}" ]]; then
        run timedatectl set-timezone "${CFG[TIMEZONE]}" || return 1
    fi
    if [[ "${CFG[NTP]}" == on ]] && ! time_ntp_enabled; then
        run timedatectl set-ntp true || return 1
    fi
    return 0
}

time_verify() {
    [[ "$(time_current_zone)" == "${CFG[TIMEZONE]}" ]] || return 1
    [[ "${CFG[NTP]}" != on ]] || time_ntp_enabled
}

step_register time step.time system 1
