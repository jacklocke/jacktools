#!/usr/bin/env bash
# Maintenance: fail2ban banned addresses, unban, and the JackTools whitelist.
set -Eeuo pipefail

# fail2ban-client wrapper for read-only queries (replaced in tests).
f2b_client() { fail2ban-client "$@" 2>/dev/null; }

# Jails and banned addresses, space separated. Both return 1 when fail2ban-client does not
# answer (service starting, no permission): callers test it in a condition, so the failure
# is handled instead of reaching the ERR trap.
f2b_jails() {
    local out
    out=$(f2b_client status) || return 1
    sed -n 's/.*Jail list:[[:space:]]*//p' <<<"$out" | tr ',' ' ' | xargs
}

f2b_banned() {
    local out
    out=$(f2b_client status "$1") || return 1
    sed -n 's/.*Banned IP list:[[:space:]]*//p' <<<"$out" | xargs
}

# f2b_available: fail2ban answers and has jails; F2B_JAILS holds them for the caller.
F2B_JAILS=''
f2b_available() {
    F2B_JAILS=''
    if command_exists fail2ban-client && F2B_JAILS=$(f2b_jails) && [[ -n "$F2B_JAILS" ]]; then return 0; fi
    ui_warn maint.f2b.unavailable
    return 1
}

maint_f2b_list() {
    local jail ips
    f2b_available || return 0
    ui_title maint.f2b.list_title
    for jail in $F2B_JAILS; do
        ips=$(f2b_banned "$jail") || ips=''
        msg maint.f2b.jail "$jail" "${ips:-$(msg_get maint.f2b.none)}"
    done
}

maint_f2b_unban_one() {
    local jail ip choice banned
    local -a labels=() jails=() ips=()
    f2b_available || return 0
    for jail in $F2B_JAILS; do
        banned=$(f2b_banned "$jail") || banned=''
        for ip in $banned; do labels+=("$ip ($jail)"); jails+=("$jail"); ips+=("$ip"); done
    done
    if (( ${#labels[@]} == 0 )); then ui_info maint.f2b.nothing_banned; return 0; fi
    ui_menu choice maint.f2b.unban_title labels || return 0
    ui_confirm maint.f2b.confirm_unban "${ips[$choice]}" "${jails[$choice]}" || return 0
    run fail2ban-client set "${jails[$choice]}" unbanip "${ips[$choice]}" >/dev/null && ui_info maint.f2b.unbanned "${ips[$choice]}"
}

maint_f2b_unban_all() {
    f2b_available || return 0
    ui_confirm maint.f2b.confirm_unban_all || return 0
    run fail2ban-client unban --all >/dev/null && ui_info maint.f2b.unbanned_all
}

# Load the JackTools jail file into CFG; 1 when JackTools did not configure fail2ban.
maint_f2b_load() {
    local file key value
    file=$(root_path "$F2B_JAIL_FILE")
    [[ -r "$file" ]] || { ui_warn maint.f2b.no_jail_file; return 1; }
    while IFS='=' read -r key value; do
        key=$(xargs <<<"$key"); value=$(xargs <<<"$value")
        case "$key" in
            bantime) CFG[F2B_BANTIME]="$value" ;;
            findtime) CFG[F2B_FINDTIME]="$value" ;;
            maxretry) CFG[F2B_MAXRETRY]="$value" ;;
            ignoreip) value=" $value "; value=${value/ 127.0.0.1\/8 / }; value=${value/ ::1 / }; CFG[F2B_IGNOREIP]=$(xargs <<<"$value") ;;
            port) CFG[SSH_PORT]="$value" ;;
        esac
    done <"$file"
}

maint_f2b_whitelist() {
    local choice answer item
    local -a actions entries
    maint_f2b_load || return 0
    actions=("$(msg_get maint.f2b.wl_add)" "$(msg_get maint.f2b.wl_remove)")
    while true; do
        msg maint.f2b.wl_current "127.0.0.1/8 ::1 ${CFG[F2B_IGNOREIP]}"
        ui_menu choice maint.f2b.wl_title actions || return 0
        if (( choice == 0 )); then
            ui_prompt answer maint.f2b.wl_prompt || continue
            [[ -n "$answer" ]] || continue
            if ! valid_ip_or_cidr "$answer"; then ui_warn fail2ban.invalid_ip "$answer"; continue; fi
            words_add 'CFG[F2B_IGNOREIP]' "$answer"
        else
            read -r -a entries <<<"${CFG[F2B_IGNOREIP]}"
            if (( ${#entries[@]} == 0 )); then ui_info maint.f2b.wl_empty; continue; fi
            ui_menu choice maint.f2b.wl_remove_title entries || continue
            CFG[F2B_IGNOREIP]=$(for item in "${entries[@]}"; do [[ "$item" == "${entries[$choice]}" ]] || printf '%s ' "$item"; done | xargs)
        fi
        if fail2ban_apply; then ui_info maint.f2b.wl_saved; else ui_error maint.f2b.wl_failed; fi
    done
}

# Recent ban/unban events: the fail2ban log file, or journald when there is none
# (replaced in tests).
f2b_log_events() {
    local file
    file=$(root_path /var/log/fail2ban.log)
    if [[ -r "$file" ]]; then
        grep -hE ' (Ban|Unban) ' "$file" | tail -n 200 || true
    else
        journalctl -u fail2ban --no-pager -n 2000 2>/dev/null | grep -E ' (Ban|Unban) ' | tail -n 200 || true
    fi
}

maint_f2b_status() {
    local jail
    f2b_available || return 0
    { for jail in $F2B_JAILS; do printf '\n== %s ==\n' "$jail"; f2b_client status "$jail" || true; done; } | ui_pager
}

maint_f2b_search() {
    local ip jail banned found=0
    f2b_available || return 0
    ui_prompt ip maint.f2b.search_prompt || return 0
    [[ -n "$ip" ]] || return 0
    for jail in $F2B_JAILS; do
        banned=$(f2b_banned "$jail") || banned=''
        if [[ " $banned " == *" $ip "* ]]; then msg maint.f2b.search_banned "$ip" "$jail"; found=1; fi
    done
    (( found )) || msg maint.f2b.search_free "$ip"
}

# Manual ban; the operator's own address and whitelisted entries are refused.
maint_f2b_ban() {
    local ip jail choice
    local -a jails
    f2b_available || return 0
    read -r -a jails <<<"$F2B_JAILS"
    ui_ask ip valid_ip_or_cidr fail2ban.invalid_ip maint.f2b.ban_prompt || return 0
    if [[ "$ip" == "$ENV_SSH_CLIENT_IP" ]] || { [[ -n "$ENV_SSH_CLIENT_IP" ]] && ipv4_in_cidr "$ENV_SSH_CLIENT_IP" "$ip"; }; then
        ui_error maint.f2b.ban_self
        return 0
    fi
    maint_f2b_load >/dev/null 2>&1 || true
    if [[ " ${CFG[F2B_IGNOREIP]:-} 127.0.0.1 ::1 " == *" $ip "* ]]; then ui_error maint.f2b.ban_whitelisted "$ip"; return 0; fi
    jail=${jails[0]}
    if (( ${#jails[@]} > 1 )); then
        ui_menu choice maint.f2b.jail_title jails || return 0
        jail=${jails[$choice]}
    fi
    ui_confirm maint.f2b.confirm_ban "$ip" "$jail" || return 0
    run fail2ban-client set "$jail" banip "$ip" >/dev/null && ui_info maint.f2b.banned "$ip"
}

maint_f2b_log() {
    local events
    events=$(f2b_log_events)
    if [[ -z "$events" ]]; then ui_info maint.f2b.log_empty; return 0; fi
    printf '%s\n' "$events" | ui_pager
}

maint_f2b_menu() {
    local choice
    local -a items=(
        "$(msg_get maint.f2b.status)" "$(msg_get maint.f2b.list)" "$(msg_get maint.f2b.search)" "$(msg_get maint.f2b.ban)"
        "$(msg_get maint.f2b.unban)" "$(msg_get maint.f2b.unban_all)" "$(msg_get maint.f2b.whitelist)"
        "$(msg_get maint.f2b.log)" "$(msg_get maint.f2b.params)"
    )
    while ui_menu choice maint.f2b.title items; do
        case "$choice" in
            0) maint_do maint_f2b_status ;;
            1) maint_do maint_f2b_list ;;
            2) maint_do maint_f2b_search ;;
            3) maint_do maint_f2b_ban ;;
            4) maint_do maint_f2b_unban_one ;;
            5) maint_do maint_f2b_unban_all ;;
            6) maint_do maint_f2b_whitelist ;;
            7) maint_do maint_f2b_log ;;
            8) maint_do run_single_step fail2ban ;;
        esac
    done
    return 0
}
