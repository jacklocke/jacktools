#!/usr/bin/env bash
# Configuration files for --config and export. They are DATA: parsed line by line with a
# whitelist of keys, every value checked by the same validators as interactive answers.
# Format: comments, blank lines and KEY="value" (or KEY=value); no escapes, no "$`\ inside.
set -Eeuo pipefail

JT_CONFIG_MODE=0
JT_ASSUME_YES=0

# Key -> validator. "list:<fn>" checks every space-separated item; "enum:a|b" fixed values.
declare -gA CONFIG_VALIDATOR=(
    [STEPS]="list:step_exists"
    [HOSTNAME]="valid_hostname"
    [LOCALE]="valid_locale"
    [TIMEZONE]="valid_timezone"
    [NTP]="enum:on|keep"
    [NET_IFACE]="valid_iface"
    [NET_MODE]="enum:dhcp|dhcp-dns|static"
    [NET_CIDR]="valid_cidr"
    [NET_GATEWAY]="valid_ipv4"
    [NET_DNS]="valid_ipv4_list"
    [NET_SEARCH]="valid_domain_list"
    [SWAP_SIZE]="valid_swap_size"
    [JOURNAL_MAX]="valid_journal_size"
    [LOGROTATE_COMPRESS]="enum:on|keep"
    [MOTD_CLEAN]="enum:yes"
    [UPGRADE]="enum:yes"
    [PACKAGES]="list:valid_package_name"
    [DOCKER_COMPOSE]="enum:yes|no"
    [DOCKER_REMOVE_CONFLICTS]="enum:yes|no"
    [UNATTENDED_REBOOT]="valid_unattended_reboot"
    [ADMIN_USER]="valid_admin_name"
    [ADMIN_FULLNAME]="valid_fullname"
    [ADMIN_KEY]="valid_ssh_public_key"
    [ADMIN_SUDO]="enum:password|nopasswd"
    [CUSTOM_USERS]="list:valid_custom_user"
    [CUSTOM_MODULES]="list:valid_module_id"
    [CUSTOM_EXTRAS]="list:valid_extra_id"
    [CUSTOM_KEY]="valid_ssh_public_key"
    [CUSTOM_SUDO]="enum:password|nopasswd"
    [BANNER]="valid_banner_name"
    [BANNER_TEXT]="valid_banner_text"
    [SSH_PASSWORD_AUTH]="enum:no|keep"
    [SSH_ROOT_LOGIN]="enum:no|prohibit-password|keep"
    [SSH_PORT]="valid_port"
    [UFW_ALLOW]="list:valid_ufw_rule"
    [F2B_MAXRETRY]="valid_maxretry"
    [F2B_FINDTIME]="valid_duration"
    [F2B_BANTIME]="valid_duration"
    [F2B_IGNOREIP]="list:valid_ip_or_cidr"
    [REMOVE_HOME]="enum:yes|no"
    [REMOVE_MAIL]="enum:yes|no"
)

# Keys a step needs in --config mode (per-user customize keys are checked separately).
declare -gA CONFIG_REQUIRED=(
    [hostname]="HOSTNAME" [locale]="LOCALE" [time]="TIMEZONE NTP" [network]="NET_IFACE NET_MODE"
    [swap]="SWAP_SIZE" [journald]="JOURNAL_MAX LOGROTATE_COMPRESS" [motd]="MOTD_CLEAN"
    [upgrade]="" [packages]="PACKAGES" [docker]="DOCKER_COMPOSE DOCKER_REMOVE_CONFLICTS"
    [unattended]="UNATTENDED_REBOOT" [admin]="ADMIN_USER ADMIN_SUDO" [customize]="CUSTOM_USERS BANNER"
    [ssh]="SSH_PASSWORD_AUTH SSH_ROOT_LOGIN SSH_PORT" [ufw]="UFW_ALLOW"
    [fail2ban]="F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME" [remove_ubuntu]="REMOVE_HOME REMOVE_MAIL"
)

# Export order: one section per step, in execution order.
CONFIG_KEY_ORDER=(
    HOSTNAME LOCALE TIMEZONE NTP NET_IFACE NET_MODE NET_CIDR NET_GATEWAY NET_DNS NET_SEARCH
    SWAP_SIZE JOURNAL_MAX LOGROTATE_COMPRESS MOTD_CLEAN UPGRADE PACKAGES DOCKER_COMPOSE
    DOCKER_REMOVE_CONFLICTS UNATTENDED_REBOOT ADMIN_USER ADMIN_FULLNAME ADMIN_KEY ADMIN_SUDO
    CUSTOM_USERS BANNER BANNER_TEXT SSH_PASSWORD_AUTH SSH_ROOT_LOGIN SSH_PORT UFW_ALLOW
    F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME F2B_IGNOREIP REMOVE_HOME REMOVE_MAIL
)

valid_iface() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
valid_admin_name() { valid_username "$1" && [[ "$1" != root ]]; }
valid_fullname() { [[ "$1" != *:* && ! "$1" =~ [[:cntrl:]] ]] && (( ${#1} <= 64 )); }
valid_custom_user() { valid_username "$1"; }
valid_module_id() { [[ "$1" =~ ^[a-z0-9-]+$ ]]; }
valid_extra_id() { [[ " ${CUSTOM_EXTRAS[*]} " == *" $1 "* ]]; }
valid_banner_name() { [[ "$1" == none || "$1" == custom ]] || { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ -f "$(banner_file "$1")" ]]; }; }
valid_unattended_reboot() { [[ "$1" == no ]] || valid_reboot_time "$1"; }

# config_validate KEY VALUE (KEY may carry a ":<user>" suffix).
config_validate() {
    local key="${1%%:*}" value="$2" rule item
    rule=${CONFIG_VALIDATOR[$key]:-}
    [[ -n "$rule" ]] || return 1
    if [[ "$1" == *:* ]]; then
        [[ "$key" == CUSTOM_MODULES || "$key" == CUSTOM_EXTRAS || "$key" == CUSTOM_KEY || "$key" == CUSTOM_SUDO ]] || return 1
        valid_username "${1#*:}" || return 1
    fi
    case "$rule" in
        enum:*) [[ "|${rule#enum:}|" == *"|$value|"* ]] ;;
        list:*)
            for item in $value; do "${rule#list:}" "$item" || return 1; done
            return 0
            ;;
        *) [[ -z "$value" && "$key" =~ ^(ADMIN_FULLNAME|ADMIN_KEY|BANNER_TEXT|NET_.*|F2B_IGNOREIP)$ ]] || "$rule" "$value" ;;
    esac
}

# A config file must belong to root (to the current user in tests) and not be writable by others.
config_file_safe() {
    local file="$1" owner mode
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    owner=$(stat -c %u -- "$file"); mode=$(stat -c %a -- "$file")
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then [[ "$owner" == "${EUID}" ]] || return 1; else [[ "$owner" == 0 ]] || return 1; fi
    (( (8#$mode & 8#022) == 0 ))
}

# config_load FILE: fill CFG; any unknown key or invalid value refuses the whole file.
config_load() {
    local file="$1" line key value line_number=0
    # shellcheck disable=SC2016 # $ and backtick are literal: they are the characters refused.
    local re='^([A-Z][A-Z0-9_]*(:[a-z_][a-z0-9_-]*)?)=("([^"`$\\]*)"|([^"`$\\[:space:]]*))$'
    local -A loaded=()
    config_file_safe "$file" || { ui_error config.unsafe_file "$file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ $re ]]; then ui_error config.bad_line "$line_number"; return 1; fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        if ! config_validate "$key" "$value"; then ui_error config.bad_value "$line_number" "$key"; return 1; fi
        loaded["$key"]="$value"
    done <"$file"
    [[ -v "loaded[STEPS]" ]] || { ui_error config.no_steps; return 1; }
    CFG=()
    for key in "${!loaded[@]}"; do CFG["$key"]="${loaded[$key]}"; done
    log_write INFO "configuration loaded from $file"
}

# config_check_step ID: required keys present (and coherent) for a step run from --config.
config_check_step() {
    local id="$1" key user
    for key in ${CONFIG_REQUIRED[$id]:-}; do
        [[ -v "CFG[$key]" ]] || { ui_error config.missing_key "$key" "$(step_label "$id")"; return 1; }
    done
    case "$id" in
        network)
            [[ "${CFG[NET_MODE]}" == dhcp || -n "${CFG[NET_DNS]:-}" ]] || { ui_error config.missing_key NET_DNS "$(step_label "$id")"; return 1; }
            if [[ "${CFG[NET_MODE]}" == static ]]; then
                [[ -n "${CFG[NET_CIDR]:-}" && -n "${CFG[NET_GATEWAY]:-}" ]] || { ui_error config.missing_key NET_CIDR "$(step_label "$id")"; return 1; }
            fi
            ;;
        customize)
            for user in ${CFG[CUSTOM_USERS]}; do
                [[ -v "CFG[CUSTOM_MODULES:$user]" ]] || { ui_error config.missing_key "CUSTOM_MODULES:$user" "$(step_label "$id")"; return 1; }
                [[ " ${CFG["CUSTOM_EXTRAS:$user"]:-} " != *" ssh_key "* || -n "${CFG["CUSTOM_KEY:$user"]:-}" ]] || { ui_error config.missing_key "CUSTOM_KEY:$user" "$(step_label "$id")"; return 1; }
                [[ " ${CFG["CUSTOM_EXTRAS:$user"]:-} " != *" sudo "* || -n "${CFG["CUSTOM_SUDO:$user"]:-}" ]] || { ui_error config.missing_key "CUSTOM_SUDO:$user" "$(step_label "$id")"; return 1; }
            done
            [[ "${CFG[BANNER]}" != custom || -n "${CFG[BANNER_TEXT]:-}" ]] || { ui_error config.missing_key BANNER_TEXT "$(step_label "$id")"; return 1; }
            ;;
    esac
    # Optional values default to empty.
    for key in ADMIN_FULLNAME ADMIN_KEY ADMIN_PASSWORD NET_CIDR NET_GATEWAY NET_DNS NET_SEARCH F2B_IGNOREIP BANNER_TEXT; do
        [[ -v "CFG[$key]" ]] || CFG["$key"]=''
    done
    if declare -F "${id}_config_prepare" >/dev/null; then "${id}_config_prepare" || return 1; fi
    return 0
}

config_quote() { printf '"%s"' "$1"; }

# config_write OUTPUT: STEPS first, then keys in execution order, per-user keys last.
config_write() {
    local output="$1" key user
    {
        printf '# JackTools configuration — %s\n' "$(date '+%Y-%m-%d %H:%M')"
        printf '# Data file: read with a whitelist of keys, never executed.\n'
        [[ -z "${JACKTOOLS_SOURCE:-}" ]] || printf '# Source: %s\n' "$JACKTOOLS_SOURCE"
        printf '\nSTEPS=%s\n' "$(config_quote "${CFG[STEPS]:-}")"
        for key in "${CONFIG_KEY_ORDER[@]}"; do
            [[ -v "CFG[$key]" ]] || continue
            printf '%s%s=%s\n' "${CONFIG_COMMENTED[$key]:+# }" "$key" "$(config_quote "${CFG[$key]}")"
        done
        for user in ${CFG[CUSTOM_USERS]:-}; do
            for key in CUSTOM_MODULES CUSTOM_EXTRAS CUSTOM_KEY CUSTOM_SUDO; do
                [[ -v "CFG[$key:$user]" ]] && printf '%s:%s=%s\n' "$key" "$user" "$(config_quote "${CFG[$key:$user]}")"
            done
        done
        return 0
    } >"$output"
}

declare -gA CONFIG_COMMENTED=()
