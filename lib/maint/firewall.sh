#!/usr/bin/env bash
# Maintenance: firewall. UFW rules can be read and changed; iptables is shown read-only,
# because rules written there directly would fight with UFW and Docker.
set -Eeuo pipefail

# Read-only queries (replaced in tests).
fw_ufw_verbose() { ufw status verbose 2>/dev/null; }
fw_ufw_numbered() { ufw status numbered 2>/dev/null; }
fw_iptables_list() { iptables -L -n -v --line-numbers 2>&1; }

fw_ufw_available() {
    command_exists ufw && return 0
    ui_warn maint.fw.no_ufw
    return 1
}

# Numbered rules as "N|text" lines, from "[ 1] 22/tcp   ALLOW IN   Anywhere".
fw_rules() {
    fw_ufw_numbered | sed -n 's/^\[ *\([0-9][0-9]*\)\] *\(.*[^ ]\) *$/\1|\2/p' | sed 's/   */  /g'
}

# A rule for the current SSH port must not be removed from here.
fw_rule_is_ssh() {
    local target port
    port=$(ssh_current_port)
    target=$(awk '{ print $1 }' <<<"$1")
    [[ "$target" == "$port" || "$target" == "$port/tcp" || "$target" == OpenSSH ]]
}

maint_fw_show() {
    fw_ufw_available || return 0
    { msg maint.fw.ufw_title; fw_ufw_verbose; } | ui_pager
}

maint_fw_add() {
    local rule source choice
    local -a actions=("$(msg_get maint.fw.allow)" "$(msg_get maint.fw.limit)" "$(msg_get maint.fw.deny)")
    local -a verbs=(allow limit deny)
    local -a command
    fw_ufw_available || return 0
    while true; do
        ui_prompt rule ufw.prompt.other || return 0
        [[ -n "$rule" ]] || return 0
        valid_ufw_rule "$rule" && break
        ui_warn ufw.invalid_rule "$rule"
    done
    while true; do
        ui_prompt source maint.fw.prompt_source || return 0
        [[ -z "$source" ]] || valid_ip_or_cidr "$source" && break
        ui_warn fail2ban.invalid_ip "$source"
    done
    ui_menu choice maint.fw.action_title actions || return 0
    if [[ "${verbs[$choice]}" == deny && "${rule%%/*}" == "$(ssh_current_port)" ]]; then
        ui_error maint.fw.deny_ssh
        return 0
    fi
    if [[ -z "$source" ]]; then
        command=(ufw "${verbs[$choice]}" "$rule")
    else
        command=(ufw "${verbs[$choice]}" from "$source" to any port "${rule%%/*}")
        [[ "$rule" != */* ]] || command+=(proto "${rule#*/}")
    fi
    ui_confirm maint.fw.confirm "${command[*]}" || return 0
    run "${command[@]}" && ui_info maint.fw.done
}

maint_fw_delete() {
    local -a numbers=() texts=()
    local line choice
    fw_ufw_available || return 0
    while IFS= read -r line; do numbers+=("${line%%|*}"); texts+=("${line#*|}"); done < <(fw_rules)
    if (( ${#texts[@]} == 0 )); then ui_info maint.fw.no_rules; return 0; fi
    ui_menu choice maint.fw.delete_title texts || return 0
    if fw_rule_is_ssh "${texts[$choice]}"; then ui_error maint.fw.ssh_protected; return 0; fi
    ui_confirm maint.fw.confirm_delete "${texts[$choice]}" || return 0
    run ufw --force delete "${numbers[$choice]}" >/dev/null && ui_info maint.fw.done
}

# Enabling always allows the SSH port first; disabling asks twice.
maint_fw_toggle() {
    local port
    fw_ufw_available || return 0
    if ufw_active; then
        ui_warn maint.fw.disable_warning
        ui_confirm maint.fw.confirm_disable || return 0
        run ufw disable >/dev/null && ui_info maint.fw.disabled
    else
        port=$(ssh_current_port)
        ui_confirm maint.fw.confirm_enable "$port" || return 0
        run ufw allow "$port/tcp" >/dev/null && run ufw --force enable >/dev/null && ui_info maint.fw.enabled
    fi
}

maint_fw_iptables() {
    { msg maint.fw.iptables_note; fw_iptables_list; } | ui_pager
}

maint_fw_menu() {
    local choice
    local -a items=(
        "$(msg_get maint.fw.show)" "$(msg_get maint.fw.add)" "$(msg_get maint.fw.delete)"
        "$(msg_get maint.fw.toggle)" "$(msg_get maint.fw.iptables)"
    )
    while ui_menu choice maint.fw.title items; do
        case "$choice" in
            0) maint_do maint_fw_show ;;
            1) maint_do maint_fw_add ;;
            2) maint_do maint_fw_delete ;;
            3) maint_do maint_fw_toggle ;;
            4) maint_do maint_fw_iptables ;;
        esac
    done
    return 0
}
