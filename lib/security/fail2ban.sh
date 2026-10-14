#!/usr/bin/env bash
# Step "fail2ban": SSH jail with ban parameters and a whitelist that, by default, holds
# the address of the current SSH client so the operator cannot ban themselves.
set -Eeuo pipefail

F2B_JAIL_FILE="/etc/fail2ban/jail.d/jacktools.local"
F2B_DEFAULT_BANTIME="1h"
F2B_DEFAULT_FINDTIME="10m"
F2B_DEFAULT_MAXRETRY="5"

valid_duration() { [[ "$1" =~ ^[1-9][0-9]{0,5}[smhdw]$ ]]; }
valid_maxretry() { [[ "$1" =~ ^[1-9][0-9]?$ ]]; }

# IPv4, IPv4/prefix, or IPv6 with optional prefix.
valid_ip_or_cidr() {
    valid_ipv4 "$1" || valid_cidr "$1" || [[ "$1" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]
}

# Configuration test and service state (replaced in tests).
f2b_config_test() { fail2ban-client -t >/dev/null 2>&1; }
f2b_running() { systemctl is-active --quiet fail2ban 2>/dev/null; }

# f2b_ask RESULT_VAR KEY DEFAULT VALIDATOR
f2b_ask() {
    local -n f2b_ask_result="$1"
    local f2b_ask_key="$2" f2b_ask_default="$3" f2b_ask_validator="$4" f2b_ask_answer
    while true; do
        ui_prompt f2b_ask_answer "$f2b_ask_key" "$f2b_ask_default" || return 1
        f2b_ask_answer=${f2b_ask_answer:-$f2b_ask_default}
        if "$f2b_ask_validator" "$f2b_ask_answer"; then f2b_ask_result="$f2b_ask_answer"; return 0; fi
        ui_warn fail2ban.invalid_value
    done
}

fail2ban_collect() {
    local value item
    local -a items
    f2b_ask value fail2ban.prompt.maxretry "$F2B_DEFAULT_MAXRETRY" valid_maxretry || return 1
    CFG[F2B_MAXRETRY]="$value"
    f2b_ask value fail2ban.prompt.findtime "$F2B_DEFAULT_FINDTIME" valid_duration || return 1
    CFG[F2B_FINDTIME]="$value"
    f2b_ask value fail2ban.prompt.bantime "$F2B_DEFAULT_BANTIME" valid_duration || return 1
    CFG[F2B_BANTIME]="$value"
    CFG[F2B_IGNOREIP]=''
    if [[ -n "$ENV_SSH_CLIENT_IP" ]]; then
        ui_confirm fail2ban.confirm_own_ip "$ENV_SSH_CLIENT_IP" && CFG[F2B_IGNOREIP]="$ENV_SSH_CLIENT_IP"
    fi
    while true; do
        ui_prompt value fail2ban.prompt.whitelist || return 1
        IFS=', ' read -r -a items <<<"$value"
        for item in "${items[@]}"; do valid_ip_or_cidr "$item" || { ui_warn fail2ban.invalid_ip "$item"; continue 2; }; done
        for item in "${items[@]}"; do [[ " ${CFG[F2B_IGNOREIP]} " == *" $item "* ]] || CFG[F2B_IGNOREIP]+=" $item"; done
        break
    done
    CFG[F2B_IGNOREIP]=$(xargs <<<"${CFG[F2B_IGNOREIP]}")
    return 0
}

fail2ban_render() {
    printf '# Managed by JackTools.\n[DEFAULT]\nbantime = %s\nfindtime = %s\nmaxretry = %s\n' \
        "${CFG[F2B_BANTIME]}" "${CFG[F2B_FINDTIME]}" "${CFG[F2B_MAXRETRY]}"
    printf 'ignoreip = 127.0.0.1/8 ::1%s\n' "${CFG[F2B_IGNOREIP]:+ ${CFG[F2B_IGNOREIP]}}"
    printf '\n[sshd]\nenabled = true\nport = %s\n' "${CFG[SSH_PORT]:-$(ssh_current_port)}"
}

fail2ban_file_ok() { [[ -f "$(root_path "$F2B_JAIL_FILE")" ]] && cmp -s <(fail2ban_render) "$(root_path "$F2B_JAIL_FILE")"; }

fail2ban_plan() {
    if apt_is_installed fail2ban && fail2ban_file_ok && f2b_running; then msg steps.plan.compliant; return 0; fi
    apt_is_installed fail2ban || msg fail2ban.plan_install
    msg fail2ban.plan_jail "${CFG[F2B_MAXRETRY]}" "${CFG[F2B_FINDTIME]}" "${CFG[F2B_BANTIME]}"
    msg fail2ban.plan_whitelist "127.0.0.1 ::1 ${CFG[F2B_IGNOREIP]}"
}

fail2ban_apply() {
    local file candidate backup
    if ! apt_is_installed fail2ban; then
        apt_update_once || return 1
        apt_get install -- fail2ban || return 1
    fi
    file=$(root_path "$F2B_JAIL_FILE")
    if ! fail2ban_file_ok; then
        mkdir -p -- "$(dirname -- "$file")" || return 1
        fs_mktemp candidate
        fail2ban_render >"$candidate" || return 1
        backup=$(backup_file "$file" fail2ban-jail) || return 1
        atomic_install "$candidate" "$file" 0644 || return 1
        if ! f2b_config_test; then
            if [[ -n "$backup" ]]; then cp -a -- "$backup" "$file"; else rm -f -- "$file"; fi
            ui_error fail2ban.config_invalid
            return 1
        fi
    fi
    run systemctl enable fail2ban >/dev/null 2>&1 || return 1
    run systemctl restart fail2ban || return 1
}

fail2ban_verify() { fail2ban_file_ok && f2b_running; }

step_register fail2ban step.fail2ban security 1
