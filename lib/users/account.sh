#!/usr/bin/env bash
# User database lookups and account changes (SSH key, sudo, groups).
# Lookups go through users_passwd / users_groupdb so tests can use fake databases.
set -Eeuo pipefail

# Account databases (cached for the run, refreshed after useradd/usermod/userdel/gpasswd).
users_passwd() { cache_get passwd getent passwd; }
users_groupdb() { cache_get group getent group; }

user_field() { users_passwd | awk -F: -v n="$1" -v f="$2" '$1 == n { print $f; exit }'; }
user_exists() { [[ -n "$(user_field "$1" 1)" ]]; }
user_home() { user_field "$1" 6; }
user_shell() { user_field "$1" 7; }
user_uid() { user_field "$1" 3; }

user_primary_group() {
    local gid
    gid=$(user_field "$1" 4)
    users_groupdb | awk -F: -v g="$gid" '$3 == g { print $1; exit }'
}

group_exists() { users_groupdb | awk -F: -v g="$1" '$1 == g { found = 1 } END { exit !found }'; }

# Primary group plus supplementary groups, space separated.
user_groups() {
    local user="$1"
    {
        user_primary_group "$user"
        users_groupdb | awk -F: -v u="$user" '{ n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }'
    } | awk 'NF && !seen[$0]++' | xargs
}

user_in_group() { [[ " $(user_groups "$1") " == *" $2 "* ]]; }

# "P" when the account has a usable password (replaced in tests).
user_password_state() { passwd -S "$1" 2>/dev/null | awk '{ print $2 }'; }

user_has_key() { [[ -s "$(user_home "$1")/.ssh/authorized_keys" ]]; }

sudoers_file() { root_path "/etc/sudoers.d/90-jacktools-$1"; }

# Syntax check of a sudoers fragment (replaced in tests).
sudoers_valid() { visudo -cf "$1" >/dev/null 2>&1; }

account_sudo_mode() {
    if ! user_in_group "$1" sudo; then printf none
    elif [[ -f "$(sudoers_file "$1")" ]]; then printf nopasswd
    else printf password; fi
}

# account_install_key USER KEY: ~/.ssh 0700, authorized_keys 0600, key added once.
account_install_key() {
    local user="$1" key="$2" home group dir file
    home=$(user_home "$user"); group=$(user_primary_group "$user")
    [[ -n "$home" && -d "$home" ]] || { ui_error account.no_home "$user"; return 1; }
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then msg account.dry_run_key "$home/.ssh/authorized_keys"; return 0; fi
    dir="$home/.ssh"; file="$dir/authorized_keys"
    mkdir -p -- "$dir" && chmod 0700 "$dir" && fs_chown "$user:$group" "$dir" || return 1
    [[ -e "$file" ]] || { touch "$file" || return 1; }
    grep -Fqx -- "$key" "$file" || printf '%s\n' "$key" >>"$file" || return 1
    chmod 0600 "$file" && fs_chown "$user:$group" "$file"
}

# account_set_sudo USER password|nopasswd: sudo group membership, plus a validated
# NOPASSWD fragment only for nopasswd (removed, with backup, otherwise).
account_set_sudo() {
    local user="$1" mode="$2" file candidate
    file=$(sudoers_file "$user")
    if ! user_in_group "$user" sudo; then run usermod -aG sudo "$user" || return 1; fi
    if [[ "$mode" == nopasswd ]]; then
        fs_mktemp candidate
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" >"$candidate" && chmod 0440 "$candidate" || return 1
        sudoers_valid "$candidate" || { ui_error account.sudoers_invalid; return 1; }
        [[ -f "$file" ]] && cmp -s "$candidate" "$file" && return 0
        mkdir -p -- "$(dirname -- "$file")" || return 1
        backup_file "$file" "sudoers-$user" >/dev/null || return 1
        atomic_install "$candidate" "$file" 0440
    elif [[ -f "$file" ]]; then
        [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
        backup_file "$file" "sudoers-$user" >/dev/null || return 1
        rm -f -- "$file"
    fi
}

# account_ask_sudo RESULT_VAR: password|nopasswd chosen from a menu; 1 when cancelled.
account_ask_sudo() {
    local -n account_ask_sudo_result="$1"
    local account_ask_sudo_choice
    local -a account_ask_sudo_modes=("$(msg_get admin.sudo.password)" "$(msg_get admin.sudo.nopasswd)")
    ui_menu account_ask_sudo_choice admin.sudo.title account_ask_sudo_modes ui.menu.cancel || return 1
    if (( account_ask_sudo_choice == 0 )); then account_ask_sudo_result=password; else account_ask_sudo_result=nopasswd; fi
}

login_defs_value() {
    local value
    value=$(awk -v k="$1" '$1 == k { print $2; exit }' "$(root_path /etc/login.defs)" 2>/dev/null)
    if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s' "$value"; else printf '%s' "$2"; fi
}

login_shell_valid() {
    case "$1" in */nologin|*/false|'') return 1 ;; esac
    grep -Fqx -- "$1" "$(root_path /etc/shells)" 2>/dev/null
}

# Human accounts: UID_MIN..UID_MAX with a real login shell, in passwd order.
users_discover() {
    local min max name uid shell
    min=$(login_defs_value UID_MIN 1000)
    max=$(login_defs_value UID_MAX 60000)
    while IFS=: read -r name _ uid _ _ _ shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= min && uid <= max )) || continue
        login_shell_valid "$shell" && printf '%s\n' "$name"
    done < <(users_passwd)
    return 0
}

account_add_group() {
    user_in_group "$1" "$2" && return 0
    run usermod -aG "$2" "$1"
}
