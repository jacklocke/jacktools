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

unattended_files_ok() {
    fs_file_matches "$(root_path "$UNATTENDED_PERIODIC")" unattended_render_periodic &&
        fs_file_matches "$(root_path "$UNATTENDED_JACKTOOLS")" unattended_render_jacktools
}

unattended_compliant() { apt_is_installed unattended-upgrades && unattended_files_ok; }

unattended_collect() {
    ui_confirm unattended.confirm || return 1
    CFG[UNATTENDED_REBOOT]=no
    if ui_confirm unattended.reboot_confirm; then
        ui_ask 'CFG[UNATTENDED_REBOOT]' --default "$UNATTENDED_DEFAULT_TIME" valid_reboot_time unattended.invalid_time unattended.reboot_time "$UNATTENDED_DEFAULT_TIME" || return 1
    fi
    return 0
}

unattended_plan() {
    if unattended_compliant; then msg steps.plan.compliant; return 0; fi
    apt_is_installed unattended-upgrades || msg unattended.plan_install
    msg unattended.plan_files "$UNATTENDED_PERIODIC" "$UNATTENDED_JACKTOOLS"
    if [[ "${CFG[UNATTENDED_REBOOT]}" == no ]]; then msg unattended.plan_no_reboot; else msg unattended.plan_reboot "${CFG[UNATTENDED_REBOOT]}"; fi
}

unattended_apply() {
    if ! apt_is_installed unattended-upgrades; then
        apt_update_once || return 1
        apt_get install -- unattended-upgrades || return 1
    fi
    fs_write_managed "$(root_path "$UNATTENDED_PERIODIC")" apt-20auto-upgrades 0644 unattended_render_periodic || return 1
    fs_write_managed "$(root_path "$UNATTENDED_JACKTOOLS")" apt-52jacktools 0644 unattended_render_jacktools || return 1
    run systemctl enable --now unattended-upgrades >/dev/null 2>&1 || ui_warn unattended.service_failed
    return 0
}

unattended_verify() {
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    unattended_files_ok
}

step_register unattended step.unattended install 1
