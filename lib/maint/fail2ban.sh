#!/usr/bin/env bash
# Maintenance: fail2ban banned addresses, unban, and the JackTools whitelist.
set -Eeuo pipefail

# fail2ban-client wrapper for read-only queries (replaced in tests).
f2b_client() { fail2ban-client "$@" 2>/dev/null; }

f2b_jails() { f2b_client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ' | xargs; }
f2b_banned() { f2b_client status "$1" | sed -n 's/.*Banned IP list:[[:space:]]*//p' | xargs; }

f2b_available() {
    command_exists fail2ban-client && [[ -n "$(f2b_jails)" ]] && return 0
    ui_warn maint.f2b.unavailable
    return 1
}

maint_f2b_list() {
    local jail ips
    f2b_available || return 0
    ui_title maint.f2b.list_title
    for jail in $(f2b_jails); do
        ips=$(f2b_banned "$jail")
        msg maint.f2b.jail "$jail" "${ips:-$(msg_get maint.f2b.none)}"
    done
}

maint_f2b_unban_one() {
    local jail ip choice
    local -a labels=() jails=() ips=()
    f2b_available || return 0
    for jail in $(f2b_jails); do
        for ip in $(f2b_banned "$jail"); do labels+=("$ip ($jail)"); jails+=("$jail"); ips+=("$ip"); done
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
            [[ " ${CFG[F2B_IGNOREIP]} " == *" $answer "* ]] || CFG[F2B_IGNOREIP]=$(xargs <<<"${CFG[F2B_IGNOREIP]} $answer")
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

# ipv4_in_cidr IP CIDR: IPv4 address inside the network (a plain IP counts as /32).
ipv4_to_int() { local a b c d; IFS=. read -r a b c d <<<"$1"; printf '%s' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"; }
ipv4_in_cidr() {
    local ip="$1" net="${2%/*}" prefix="${2#*/}" mask
    valid_ipv4 "$ip" && valid_ipv4 "$net" || return 1
    [[ "$2" == */* ]] || prefix=32
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( ($(ipv4_to_int "$ip") & mask) == ($(ipv4_to_int "$net") & mask) ))
}

maint_f2b_status() {
    local jail
    f2b_available || return 0
    { for jail in $(f2b_jails); do printf '\n== %s ==\n' "$jail"; f2b_client status "$jail"; done; } | ui_pager
}

maint_f2b_search() {
    local ip jail found=0
    f2b_available || return 0
    ui_prompt ip maint.f2b.search_prompt || return 0
    [[ -n "$ip" ]] || return 0
    for jail in $(f2b_jails); do
        if [[ " $(f2b_banned "$jail") " == *" $ip "* ]]; then msg maint.f2b.search_banned "$ip" "$jail"; found=1; fi
    done
    (( found )) || msg maint.f2b.search_free "$ip"
}

# Manual ban; the operator's own address and whitelisted entries are refused.
maint_f2b_ban() {
    local ip jail choice
    local -a jails
    f2b_available || return 0
    read -r -a jails <<<"$(f2b_jails)"
    while true; do
        ui_prompt ip maint.f2b.ban_prompt || return 0
        [[ -n "$ip" ]] || return 0
        valid_ip_or_cidr "$ip" && break
        ui_warn fail2ban.invalid_ip "$ip"
    done
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
