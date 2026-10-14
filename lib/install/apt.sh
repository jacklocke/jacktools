#!/usr/bin/env bash
# APT helpers and the steps "upgrade" (system update) and "packages" (assets/packages.txt).
set -Eeuo pipefail

APT_UPDATED=0
declare -ga PACKAGE_NAMES=() PACKAGE_DEFAULTS=()

# apt_get ARGS...: non-interactive apt-get that keeps locally modified config files.
apt_get() {
    run env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold "$@"
}

apt_is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fq 'install ok installed'; }

# apt_update_once: refresh the indexes once per run; nothing is installed if this fails.
apt_update_once() {
    (( APT_UPDATED )) && return 0
    if apt_locked; then ui_error apt.locked; return 1; fi
    if ! run apt-get update; then ui_error apt.update_failed; return 1; fi
    APT_UPDATED=1
}

apt_reboot_required() { [[ -e "$(root_path /var/run/reboot-required)" ]]; }

# packages.txt: comments, blank lines and "name [default]" lines; anything else is refused.
parse_packages_file() {
    local file="$1" line name flag extra line_number=0
    PACKAGE_NAMES=(); PACKAGE_DEFAULTS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line=${line%%#*}
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        name='' flag='' extra=''
        read -r name flag extra <<<"$line"
        valid_package_name "$name" || { ui_error apt.packages_invalid_name "$line_number"; return 1; }
        [[ -z "$extra" ]] || { ui_error apt.packages_too_many_fields "$line_number"; return 1; }
        [[ -z "$flag" || "$flag" == default ]] || { ui_error apt.packages_unknown_flag "$line_number"; return 1; }
        PACKAGE_NAMES+=("$name")
        if [[ "$flag" == default ]]; then PACKAGE_DEFAULTS+=(1); else PACKAGE_DEFAULTS+=(0); fi
    done <"$file"
}

# ---- Step "upgrade"

upgrade_collect() {
    msg upgrade.os "${ENV_OS_PRETTY:-Ubuntu $ENV_OS_VERSION_ID}"
    CFG[UPGRADE]=yes
}

upgrade_plan() { msg upgrade.plan; }

upgrade_apply() {
    apt_update_once || return 1
    apt_get upgrade || return 1
    apt_reboot_required && state_flag REBOOT
    return 0
}

# ---- Step "packages"

packages_collect() {
    local -a labels=() selected=() chosen=()
    local i name
    parse_packages_file "$JACKTOOLS_DIR/assets/packages.txt" || return 1
    if [[ "$ENV_VIRT_KIND" == vm && " ${PACKAGE_NAMES[*]} " != *" qemu-guest-agent "* ]]; then
        PACKAGE_NAMES+=(qemu-guest-agent); PACKAGE_DEFAULTS+=(1)
    fi
    for i in "${!PACKAGE_NAMES[@]}"; do
        name=${PACKAGE_NAMES[$i]}
        if apt_is_installed "$name"; then
            labels+=("$(msg_get packages.label_installed "$name")")
        elif [[ "$name" == qemu-guest-agent && "$ENV_VIRT_KIND" == vm ]]; then
            labels+=("$(msg_get packages.label_vm "$name")")
        else
            labels+=("$name")
        fi
        selected+=("${PACKAGE_DEFAULTS[$i]}")
    done
    ui_checklist packages.title labels selected || return 1
    for i in "${!PACKAGE_NAMES[@]}"; do
        [[ ${selected[$i]} == 1 ]] && chosen+=("${PACKAGE_NAMES[$i]}")
    done
    (( ${#chosen[@]} > 0 )) || return 1
    CFG[PACKAGES]="${chosen[*]}"
}

# Selected packages that are not installed yet.
packages_missing() {
    local name
    for name in ${CFG[PACKAGES]}; do apt_is_installed "$name" || printf '%s\n' "$name"; done
    return 0
}

packages_plan() {
    local missing
    missing=$(packages_missing | xargs)
    if [[ -z "$missing" ]]; then msg steps.plan.compliant; else msg packages.plan "$missing"; fi
}

# One package at a time, so a single failure does not hide which packages are missing.
packages_apply() {
    local name failed=''
    local -a missing
    mapfile -t missing < <(packages_missing)
    (( ${#missing[@]} > 0 )) || return 0
    apt_update_once || return 1
    for name in "${missing[@]}"; do
        if apt_get install -- "$name"; then
            log_write INFO "package installed: $name"
        else
            ui_error packages.install_failed "$name"
            failed+=" $name"
        fi
    done
    [[ -z "$failed" ]]
}

packages_verify() { [[ -z "$(packages_missing)" ]]; }

step_register upgrade step.upgrade install 1
step_register packages step.packages install 1
