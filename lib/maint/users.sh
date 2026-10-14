#!/usr/bin/env bash
# Maintenance: SSH key, sudo and personalizations for one existing user.
set -Eeuo pipefail

# Another administrator who can still log in when USER loses sudo.
maint_other_admin() {
    local user
    while IFS= read -r user; do
        [[ "$user" != "$1" ]] || continue
        user_in_group "$user" sudo || continue
        { user_has_key "$user" || [[ "$(user_password_state "$user")" == P ]]; } || continue
        ssh_user_permitted "$user" && return 0
    done < <(users_discover)
    return 1
}

maint_user_add_key() {
    local user="$1" key
    while true; do
        ui_prompt key customize.prompt.key "$user" || return 0
        [[ -n "$key" ]] || return 0
        if valid_ssh_public_key "$key"; then break; fi
        ui_warn admin.invalid_key
    done
    account_install_key "$user" "$key" && ui_info maint.users.key_added "$user"
}

maint_user_sudo() {
    local user="$1" choice file
    local -a modes=("$(msg_get admin.sudo.password)" "$(msg_get admin.sudo.nopasswd)" "$(msg_get maint.users.sudo_revoke)")
    msg maint.users.sudo_current "$user" "$(account_sudo_mode "$user")"
    ui_menu choice admin.sudo.title modes || return 0
    case "$choice" in
        0) account_set_sudo "$user" password && ui_info maint.users.sudo_done "$user" ;;
        1) account_set_sudo "$user" nopasswd && ui_info maint.users.sudo_done "$user" ;;
        2)
            if [[ "$user" == "$ENV_OPERATOR" ]]; then ui_error maint.users.revoke_self; return 0; fi
            if ! maint_other_admin "$user"; then ui_error maint.users.revoke_last; return 0; fi
            ui_confirm maint.users.confirm_revoke "$user" || return 0
            if user_in_group "$user" sudo; then run gpasswd -d "$user" sudo >/dev/null || return 0; fi
            file=$(sudoers_file "$user")
            if [[ -f "$file" && "$JACKTOOLS_DRY_RUN" != 1 ]]; then backup_file "$file" "sudoers-$user" >/dev/null && rm -f -- "$file"; fi
            ui_info maint.users.sudo_revoked "$user"
            ;;
    esac
}

# Number of keys in authorized_keys (0 when missing).
user_key_count() {
    local file
    file="$(user_home "$1")/.ssh/authorized_keys"
    [[ -r "$file" ]] || { printf 0; return 0; }
    grep -cE '^(ssh-|ecdsa-|sk-)' "$file" || true
}

# One table row per account: name, uid, shell, sudo mode, SSH keys, password state.
maint_users_table() {
    local name uid shell
    printf '%-20s %6s  %-20s %-9s %5s  %s\n' "$(msg_get maint.users.col_name)" UID Shell sudo "$(msg_get maint.users.col_keys)" "$(msg_get maint.users.col_password)"
    while IFS=: read -r name uid shell; do
        printf '%-20s %6s  %-20s %-9s %5s  %s\n' "$name" "$uid" "$shell" "$(account_sudo_mode "$name")" \
            "$(user_key_count "$name")" "$(maint_password_label "$(user_password_state "$name")")"
    done
}

# passwd -S state: P usable, L locked, NP none.
maint_password_label() {
    case "$1" in
        P) msg_get maint.users.pw_set ;;
        L) msg_get maint.users.pw_locked ;;
        NP) msg_get maint.users.pw_none ;;
        *) printf '?' ;;
    esac
}

maint_users_list() {
    local choice name
    local -a modes=("$(msg_get maint.users.list_real)" "$(msg_get maint.users.list_all)")
    ui_menu choice maint.users.list_title modes || return 0
    if (( choice == 0 )); then
        while IFS= read -r name; do printf '%s:%s:%s\n' "$name" "$(user_uid "$name")" "$(user_shell "$name")"; done < <(users_discover) |
            maint_users_table | ui_pager
    else
        users_passwd | awk -F: '{ print $1 ":" $3 ":" $7 }' | maint_users_table | ui_pager
    fi
}

# New password typed twice; optionally expired so the user must change it at next login.
maint_user_password() {
    local user="$1" password confirm
    [[ "$user" != root ]] || ui_warn maint.users.root_password
    while true; do
        ui_prompt_secret password maint.users.prompt_password "$user" || return 0
        [[ -n "$password" ]] || return 0
        ui_prompt_secret confirm admin.prompt.password_confirm || return 0
        [[ "$password" == "$confirm" ]] && break
        ui_warn admin.password_mismatch
    done
    ui_confirm maint.users.confirm_password "$user" || return 0
    # Here-string, not a pipe: the secret never appears in arguments or process lists.
    run chpasswd <<<"$user:$password" || { ui_error admin.password_failed; return 0; }
    log_write INFO "password reset for $user"
    if ui_confirm maint.users.confirm_expire "$user"; then run passwd -e "$user" >/dev/null || true; fi
    ui_info maint.users.password_done "$user"
}

maint_users_manage() {
    local -a users actions
    local choice action user
    mapfile -t users < <(users_discover)
    users+=(root)
    actions=("$(msg_get maint.users.add_key)" "$(msg_get maint.users.sudo)" "$(msg_get maint.users.password)" "$(msg_get maint.users.reapply)")
    while ui_menu choice maint.users.title users; do
        user=${users[$choice]}
        while ui_menu action maint.users.actions_title actions; do
            case "$action" in
                0) maint_do maint_user_add_key "$user" ;;
                1) maint_do maint_user_sudo "$user" ;;
                2) maint_do maint_user_password "$user" ;;
                3) maint_do run_single_step customize ;;
            esac
        done
    done
    return 0
}

maint_users_menu() {
    local choice
    local -a items=("$(msg_get maint.users.list)" "$(msg_get maint.users.manage)")
    while ui_menu choice maint.users.menu_title items; do
        case "$choice" in
            0) maint_do maint_users_list ;;
            1) maint_do maint_users_manage ;;
        esac
    done
    return 0
}
