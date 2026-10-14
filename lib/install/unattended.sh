#!/usr/bin/env bash
# Step "unattended": automatic security updates with unattended-upgrades.
set -Eeuo pipefail

UNATTENDED_PERIODIC="/etc/apt/apt.conf.d/20auto-upgrades"
UNATTENDED_JACKTOOLS="/etc/apt/apt.conf.d/52jacktools-unattended-upgrades"
UNATTENDED_DEFAULT_TIME="04:00"

valid_reboot_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# Same content that `dpkg-reconfigure unattended-upgrades` writes.
unattended_render_periodic() {
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
}

unattended_render_jacktools() {
    printf '// Managed by JackTools.\n'
    printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n'
    if [[ "${CFG[UNATTENDED_REBOOT]}" == no ]]; then
        printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    else
        printf 'Unattended-Upgrade::Automatic-Reboot "true";\n'
        printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "${CFG[UNATTENDED_REBOOT]}"
    fi
}

unattended_file_ok() { [[ -f "$(root_path "$2")" ]] && cmp -s <("$1") "$(root_path "$2")"; }

unattended_compliant() {
    apt_is_installed unattended-upgrades &&
        unattended_file_ok unattended_render_periodic "$UNATTENDED_PERIODIC" &&
        unattended_file_ok unattended_render_jacktools "$UNATTENDED_JACKTOOLS"
}

unattended_collect() {
    local answer
    ui_confirm unattended.confirm || return 1
    CFG[UNATTENDED_REBOOT]=no
    if ui_confirm unattended.reboot_confirm; then
        while true; do
            ui_prompt answer unattended.reboot_time "$UNATTENDED_DEFAULT_TIME" || return 1
            answer=${answer:-$UNATTENDED_DEFAULT_TIME}
            if valid_reboot_time "$answer"; then CFG[UNATTENDED_REBOOT]="$answer"; break; fi
            ui_warn unattended.invalid_time
        done
    fi
    return 0
}

unattended_plan() {
    if unattended_compliant; then msg steps.plan.compliant; return 0; fi
    apt_is_installed unattended-upgrades || msg unattended.plan_install
    msg unattended.plan_files "$UNATTENDED_PERIODIC" "$UNATTENDED_JACKTOOLS"
    if [[ "${CFG[UNATTENDED_REBOOT]}" == no ]]; then msg unattended.plan_no_reboot; else msg unattended.plan_reboot "${CFG[UNATTENDED_REBOOT]}"; fi
}

unattended_write() {
    local renderer="$1" path="$2" label="$3" file candidate
    unattended_file_ok "$renderer" "$path" && return 0
    file=$(root_path "$path")
    mkdir -p -- "$(dirname -- "$file")" || return 1
    fs_mktemp candidate
    "$renderer" >"$candidate" || return 1
    backup_file "$file" "$label" >/dev/null || return 1
    atomic_install "$candidate" "$file" 0644
}

unattended_apply() {
    if ! apt_is_installed unattended-upgrades; then
        apt_update_once || return 1
        apt_get install -- unattended-upgrades || return 1
    fi
    unattended_write unattended_render_periodic "$UNATTENDED_PERIODIC" apt-20auto-upgrades || return 1
    unattended_write unattended_render_jacktools "$UNATTENDED_JACKTOOLS" apt-52jacktools || return 1
    run systemctl enable --now unattended-upgrades >/dev/null 2>&1 || ui_warn unattended.service_failed
    return 0
}

unattended_verify() {
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    unattended_file_ok unattended_render_periodic "$UNATTENDED_PERIODIC" &&
        unattended_file_ok unattended_render_jacktools "$UNATTENDED_JACKTOOLS"
}

step_register unattended step.unattended install 1
