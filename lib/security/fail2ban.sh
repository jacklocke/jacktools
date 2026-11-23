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

# Configuration test and service state (replaced in tests).
f2b_config_test() { fail2ban-client -t >/dev/null 2>&1; }
f2b_running() { systemctl is-active --quiet fail2ban 2>/dev/null; }

fail2ban_collect() {
    local extra
    ui_ask 'CFG[F2B_MAXRETRY]' --default "$F2B_DEFAULT_MAXRETRY" valid_maxretry fail2ban.invalid_value fail2ban.prompt.maxretry "$F2B_DEFAULT_MAXRETRY" || return 1
    ui_ask 'CFG[F2B_FINDTIME]' --default "$F2B_DEFAULT_FINDTIME" valid_duration fail2ban.invalid_value fail2ban.prompt.findtime "$F2B_DEFAULT_FINDTIME" || return 1
    ui_ask 'CFG[F2B_BANTIME]' --default "$F2B_DEFAULT_BANTIME" valid_duration fail2ban.invalid_value fail2ban.prompt.bantime "$F2B_DEFAULT_BANTIME" || return 1
    CFG[F2B_IGNOREIP]=''
    if [[ -n "$ENV_SSH_CLIENT_IP" ]]; then
        ui_confirm fail2ban.confirm_own_ip "$ENV_SSH_CLIENT_IP" && CFG[F2B_IGNOREIP]="$ENV_SSH_CLIENT_IP"
    fi
    ui_ask_list extra valid_ip_or_cidr fail2ban.invalid_ip fail2ban.prompt.whitelist || return 1
    # shellcheck disable=SC2086 # Validated addresses, space separated.
    words_add 'CFG[F2B_IGNOREIP]' $extra
    return 0
}

fail2ban_render() {
    printf '# Managed by JackTools.\n[DEFAULT]\nbantime = %s\nfindtime = %s\nmaxretry = %s\n' \
        "${CFG[F2B_BANTIME]}" "${CFG[F2B_FINDTIME]}" "${CFG[F2B_MAXRETRY]}"
    printf 'ignoreip = 127.0.0.1/8 ::1%s\n' "${CFG[F2B_IGNOREIP]:+ ${CFG[F2B_IGNOREIP]}}"
    printf '\n[sshd]\nenabled = true\nport = %s\n' "${CFG[SSH_PORT]:-$(ssh_current_port)}"
}

fail2ban_file_ok() { fs_file_matches "$(root_path "$F2B_JAIL_FILE")" fail2ban_render; }

fail2ban_plan() {
    if apt_is_installed fail2ban && fail2ban_file_ok && f2b_running; then msg steps.plan.compliant; return 0; fi
    apt_is_installed fail2ban || msg fail2ban.plan_install
    msg fail2ban.plan_jail "${CFG[F2B_MAXRETRY]}" "${CFG[F2B_FINDTIME]}" "${CFG[F2B_BANTIME]}"
    msg fail2ban.plan_whitelist "127.0.0.1 ::1 ${CFG[F2B_IGNOREIP]}"
}

fail2ban_apply() {
    local file
    if ! apt_is_installed fail2ban; then
        apt_update_once || return 1
        apt_get install -- fail2ban || return 1
    fi
    file=$(root_path "$F2B_JAIL_FILE")
    if ! fail2ban_file_ok; then
        fs_write_managed "$file" fail2ban-jail 0644 fail2ban_render || return 1
        if ! f2b_config_test; then
            fs_restore "$FS_UNDO" "$file"
            ui_error fail2ban.config_invalid
            return 1
        fi
    fi
    run systemctl enable fail2ban >/dev/null 2>&1 || return 1
    run systemctl restart fail2ban || return 1
}

fail2ban_verify() { fail2ban_file_ok && f2b_running; }

step_register fail2ban step.fail2ban security 1
