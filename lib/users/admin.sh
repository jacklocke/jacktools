#!/usr/bin/env bash
# Step "admin": create (or update) an administrator with password, SSH key and sudo.
# The password lives only in CFG for this run: never logged, exported or passed as argument.
set -Eeuo pipefail

ADMIN_SHELL="/bin/bash"

admin_collect() {
    local name answer password confirm choice
    local -a sudo_modes
    while true; do
        ui_prompt name admin.prompt.name || return 1
        [[ -n "$name" ]] || return 1
        if valid_username "$name" && [[ "$name" != root ]]; then break; fi
        ui_warn admin.invalid_name
    done
    CFG[ADMIN_USER]="$name"
    user_exists "$name" && ui_info admin.exists "$name"
    ui_prompt answer admin.prompt.fullname || return 1
    [[ "$answer" != *:* ]] || { ui_warn admin.invalid_fullname; answer=${answer//:/}; }
    CFG[ADMIN_FULLNAME]="$answer"
    CFG[ADMIN_PASSWORD]=''
    while true; do
        ui_prompt_secret password admin.prompt.password || return 1
        [[ -n "$password" ]] || break
        ui_prompt_secret confirm admin.prompt.password_confirm || return 1
        if [[ "$password" == "$confirm" ]]; then CFG[ADMIN_PASSWORD]="$password"; break; fi
        ui_warn admin.password_mismatch
    done
    CFG[ADMIN_KEY]=''
    while true; do
        ui_prompt answer admin.prompt.key || return 1
        [[ -n "$answer" ]] || break
        if valid_ssh_public_key "$answer"; then CFG[ADMIN_KEY]="$answer"; break; fi
        ui_warn admin.invalid_key
    done
    if [[ -z "${CFG[ADMIN_PASSWORD]}" && -z "${CFG[ADMIN_KEY]}" ]] && ! user_exists "$name"; then
        ui_warn admin.no_authentication
    fi
    sudo_modes=("$(msg_get admin.sudo.password)" "$(msg_get admin.sudo.nopasswd)")
    ui_menu choice admin.sudo.title sudo_modes ui.menu.cancel || return 1
    if (( choice == 0 )); then CFG[ADMIN_SUDO]=password; else CFG[ADMIN_SUDO]=nopasswd; fi
    return 0
}

admin_plan() {
    local user="${CFG[ADMIN_USER]}"
    if user_exists "$user"; then msg admin.plan_update "$user"; else msg admin.plan_create "$user" "$ADMIN_SHELL"; fi
    [[ -z "${CFG[ADMIN_PASSWORD]}" ]] || msg admin.plan_password
    [[ -z "${CFG[ADMIN_KEY]}" ]] || msg admin.plan_key
    msg "admin.plan_sudo_${CFG[ADMIN_SUDO]}"
    # msg-keys: admin.plan_sudo_password admin.plan_sudo_nopasswd
    [[ -z "$(ssh_policy_values allowusers 2>/dev/null)" ]] || msg admin.plan_allowusers
    return 0
}

admin_apply() {
    local user="${CFG[ADMIN_USER]}"
    if user_exists "$user"; then
        run usermod --shell "$ADMIN_SHELL" "$user" || return 1
    else
        run useradd --create-home --shell "$ADMIN_SHELL" --comment "${CFG[ADMIN_FULLNAME]}" --groups sudo "$user" || return 1
    fi
    if [[ -n "${CFG[ADMIN_PASSWORD]}" ]]; then
        # Here-string, not a pipe: the secret never appears in arguments or process lists.
        run chpasswd <<<"$user:${CFG[ADMIN_PASSWORD]}" || { ui_error admin.password_failed; return 1; }
        log_write INFO "password set for $user"
    fi
    if [[ -n "${CFG[ADMIN_KEY]}" ]]; then account_install_key "$user" "${CFG[ADMIN_KEY]}" || return 1; fi
    account_set_sudo "$user" "${CFG[ADMIN_SUDO]}" || return 1
    ssh_allow_user "$user" || return 1
    return 0
}

admin_verify() {
    local user="${CFG[ADMIN_USER]}"
    user_exists "$user" || return 1
    [[ "$(account_sudo_mode "$user")" == "${CFG[ADMIN_SUDO]}" ]] || return 1
    [[ -z "${CFG[ADMIN_KEY]}" ]] || grep -Fqx -- "${CFG[ADMIN_KEY]}" "$(user_home "$user")/.ssh/authorized_keys" || return 1
    ssh_user_permitted "$user" || { ui_error ssh.user_excluded "$user"; return 1; }
}

step_register admin step.admin users 1
