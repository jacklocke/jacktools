#!/usr/bin/env bash
# OpenSSH: effective access policy, the JackTools drop-ins, safe reload and the
# "ssh" hardening step of the security phase.
set -Eeuo pipefail

SSH_MANAGED_FILE="/etc/ssh/sshd_config.d/99-jacktools.conf"
# OpenSSH keeps the first value it reads and Ubuntu includes sshd_config.d/*.conf in
# alphabetical order: hardening must sort before 50-cloud-init.conf to take effect.
SSH_HARDEN_FILE="/etc/ssh/sshd_config.d/00-jacktools-hardening.conf"

sshd_binary() {
    local candidate
    for candidate in /usr/sbin/sshd /sbin/sshd; do [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }; done
    command -v sshd 2>/dev/null
}

ssh_service_name() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf ssh; else printf sshd; fi
}

# Lowercase "keyword values" lines of the effective configuration (replaced in tests).
sshd_effective_config() {
    local binary
    binary=$(sshd_binary) || return 1
    "$binary" -T 2>/dev/null
}

sshd_config_test() {
    local binary
    binary=$(sshd_binary) || return 1
    "$binary" -t
}

ssh_policy_values() { sshd_effective_config | awk -v k="$1" 'tolower($1) == k { $1 = ""; sub(/^ /, ""); print }' | xargs; }

ssh_value_matches_patterns() {
    local value="$1" pattern
    for pattern in $2; do
        # shellcheck disable=SC2053 # OpenSSH patterns keep their wildcards.
        [[ "$value" == $pattern ]] && return 0
    done
    return 1
}

# ssh_user_permitted USER: AllowUsers/DenyUsers/AllowGroups/DenyGroups would let USER in.
ssh_user_permitted() {
    local user="$1" allow deny allow_groups deny_groups group groups allowed
    allow=$(ssh_policy_values allowusers | xargs -n1 2>/dev/null | sed 's/@.*$//' | xargs)
    deny=$(ssh_policy_values denyusers | xargs -n1 2>/dev/null | sed 's/@.*$//' | xargs)
    allow_groups=$(ssh_policy_values allowgroups)
    deny_groups=$(ssh_policy_values denygroups)
    groups=$(user_groups "$user")
    [[ -z "$allow" ]] || ssh_value_matches_patterns "$user" "$allow" || return 1
    [[ -z "$deny" ]] || ! ssh_value_matches_patterns "$user" "$deny" || return 1
    if [[ -n "$allow_groups" ]]; then
        allowed=0
        for group in $groups; do ssh_value_matches_patterns "$group" "$allow_groups" && allowed=1; done
        (( allowed )) || return 1
    fi
    for group in $groups; do
        [[ -n "$deny_groups" ]] && ssh_value_matches_patterns "$group" "$deny_groups" && return 1
    done
    return 0
}

ssh_managed_allow_users() {
    local file
    file=$(root_path "$SSH_MANAGED_FILE")
    [[ -r "$file" ]] || return 0
    awk '/^# >>> JACKTOOLS USERS >>>$/ { on = 1; next } /^# <<< JACKTOOLS USERS <<<$/ { on = 0 }
         on && /^AllowUsers / { $1 = ""; sub(/^ /, ""); print }' "$file"
}

# ssh_install_managed CANDIDATE [REQUIRED_USERS]: install the drop-in, test, reload;
# on any failure the previous drop-in is restored.
ssh_install_managed() {
    local candidate="$1" required="${2:-}" file backup user ok=1
    file=$(root_path "$SSH_MANAGED_FILE")
    mkdir -p -- "$(dirname -- "$file")" || return 1
    backup=$(backup_file "$file" sshd-jacktools) || return 1
    atomic_install "$candidate" "$file" 0600 || return 1
    sshd_config_test >/dev/null 2>&1 || ok=0
    if (( ok )); then
        for user in $required; do
            ssh_user_permitted "$user" || { ui_error ssh.user_excluded "$user"; ok=0; }
        done
    fi
    if (( ok )) && ssh_reload; then return 0; fi
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$file"; else rm -f -- "$file"; fi
    ui_error ssh.config_restored
    return 1
}

# When an AllowUsers policy exists, add USER to the JackTools-managed list.
ssh_allow_user() {
    local user="$1" file source candidate current updated
    [[ -n "$(ssh_policy_values allowusers)" ]] || return 0
    current=$(ssh_managed_allow_users)
    [[ " $current " == *" $user "* ]] && return 0
    updated=$(printf '%s\n%s\n' "$current" "$user" | xargs -n1 | sort -u | xargs)
    file=$(root_path "$SSH_MANAGED_FILE")
    source=/dev/null
    [[ -e "$file" ]] && source="$file"
    fs_mktemp candidate
    {
        awk '/^# >>> JACKTOOLS USERS >>>$/ { skip = 1; next } /^# <<< JACKTOOLS USERS <<<$/ { skip = 0; next } !skip' "$source"
        printf '# >>> JACKTOOLS USERS >>>\nAllowUsers %s\n# <<< JACKTOOLS USERS <<<\n' "$updated"
    } >"$candidate" || return 1
    ssh_install_managed "$candidate" "$updated"
}

# Socket activation (Ubuntu 22.10+): ssh.socket owns the listening port (replaced in tests).
ssh_socket_active() { systemctl is-active --quiet ssh.socket 2>/dev/null; }
ssh_service_active() { systemctl is-active --quiet "$(ssh_service_name)" 2>/dev/null; }

# ssh_reload [port_changed]: apply the configuration without dropping open sessions.
ssh_reload() {
    if ssh_socket_active; then
        if [[ "${1:-}" == port_changed ]]; then
            run systemctl daemon-reload && run systemctl restart ssh.socket || return 1
        fi
        if ssh_service_active; then run systemctl reload "$(ssh_service_name)" || return 1; fi
        return 0
    fi
    run systemctl reload "$(ssh_service_name)"
}

ssh_current_port() {
    local port
    port=$(ssh_policy_values port | awk '{ print $1 }')
    printf '%s' "${port:-22}"
}

# A sudo user with an authorized key who is allowed by the SSH policy (the admin being
# created in this run counts when it has a key).
ssh_key_admin_available() {
    local user
    [[ -n "${CFG[ADMIN_KEY]:-}" ]] && return 0
    while IFS= read -r user; do
        user_in_group "$user" sudo && user_has_key "$user" && ssh_user_permitted "$user" && return 0
    done < <(users_discover)
    return 1
}

ssh_render_hardening() {
    printf '# Managed by JackTools.\nPort %s\n' "${CFG[SSH_PORT]}"
    if [[ "${CFG[SSH_PASSWORD_AUTH]}" == no ]]; then
        printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
    fi
    [[ "${CFG[SSH_ROOT_LOGIN]}" == keep ]] || printf 'PermitRootLogin %s\n' "${CFG[SSH_ROOT_LOGIN]}"
    return 0
}

ssh_hardening_compliant() {
    [[ "$(ssh_current_port)" == "${CFG[SSH_PORT]}" ]] || return 1
    [[ "${CFG[SSH_PASSWORD_AUTH]}" != no || "$(ssh_policy_values passwordauthentication)" == no ]] || return 1
    [[ "${CFG[SSH_ROOT_LOGIN]}" == keep || "$(ssh_policy_values permitrootlogin)" == "${CFG[SSH_ROOT_LOGIN]}" ]]
}

ssh_collect() {
    local port answer choice
    local -a root_modes
    port=$(ssh_current_port)
    msg ssh.current "$port" "$(ssh_policy_values passwordauthentication)" "$(ssh_policy_values permitrootlogin)"
    CFG[SSH_PASSWORD_AUTH]=keep
    if ssh_key_admin_available; then
        ui_confirm ssh.confirm_disable_password && CFG[SSH_PASSWORD_AUTH]=no
    else
        ui_warn ssh.no_key_admin
    fi
    root_modes=("$(msg_get ssh.root.no)" "$(msg_get ssh.root.key_only)" "$(msg_get ssh.root.keep)")
    ui_menu choice ssh.root.title root_modes ui.menu.cancel 0 || return 1
    case "$choice" in
        0) CFG[SSH_ROOT_LOGIN]=no ;;
        1) CFG[SSH_ROOT_LOGIN]=prohibit-password ;;
        *) CFG[SSH_ROOT_LOGIN]=keep ;;
    esac
    while true; do
        ui_prompt answer ssh.prompt.port "$port" || return 1
        answer=${answer:-$port}
        if valid_port "$answer"; then CFG[SSH_PORT]="$answer"; break; fi
        ui_warn ssh.invalid_port
    done
    [[ "${CFG[SSH_PORT]}" == "$port" ]] || ui_warn ssh.port_change_warning "${CFG[SSH_PORT]}"
    return 0
}

ssh_plan() {
    if ssh_hardening_compliant; then msg steps.plan.compliant; return 0; fi
    msg ssh.plan_file "$SSH_HARDEN_FILE"
    ssh_render_hardening | sed '1d; s/^/  /'
    [[ "$(ssh_current_port)" == "${CFG[SSH_PORT]}" ]] || msg ssh.plan_port "${CFG[SSH_PORT]}"
    msg ssh.plan_confirm
}

ssh_restore_hardening() {
    local file="$1" backup="$2" port_changed="$3"
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$file"; else rm -f -- "$file"; fi
    ssh_reload "$port_changed" || true
}

ssh_apply() {
    local file candidate backup port_changed=''
    ssh_hardening_compliant && return 0
    if [[ "${CFG[SSH_PASSWORD_AUTH]}" == no ]] && ! ssh_key_admin_available; then ui_error ssh.no_key_admin; return 1; fi
    [[ "$(ssh_current_port)" == "${CFG[SSH_PORT]}" ]] || port_changed=port_changed
    # A new port must be reachable before sshd moves to it.
    if [[ -n "$port_changed" ]] && command_exists ufw && ufw_active; then
        run ufw allow "${CFG[SSH_PORT]}/tcp" || return 1
    fi
    file=$(root_path "$SSH_HARDEN_FILE")
    mkdir -p -- "$(dirname -- "$file")" || return 1
    fs_mktemp candidate
    ssh_render_hardening >"$candidate" || return 1
    backup=$(backup_file "$file" sshd-hardening) || return 1
    atomic_install "$candidate" "$file" 0644 || return 1
    if ! sshd_config_test >/dev/null 2>&1; then
        ssh_restore_hardening "$file" "$backup" ''
        ui_error ssh.config_restored
        return 1
    fi
    ssh_reload "$port_changed" || { ssh_restore_hardening "$file" "$backup" "$port_changed"; ui_error ssh.config_restored; return "$STEP_RC_RESTORED"; }
    # Like netplan try: keep the change only once a new login has been tested.
    if [[ "$JT_ASSUME_YES" == 1 ]]; then
        ui_warn ssh.assume_yes "${CFG[SSH_PORT]}"
        return 0
    fi
    msg ssh.test_new_session "${CFG[SSH_PORT]}"
    if ! ui_confirm ssh.confirm_new_session; then
        ssh_restore_hardening "$file" "$backup" "$port_changed"
        ui_warn ssh.config_restored
        return "$STEP_RC_RESTORED"
    fi
    return 0
}

ssh_verify() { ssh_hardening_compliant; }

step_register ssh step.ssh security 1
