#!/usr/bin/env bash
# Maintenance: SSH settings. Effective values are read with `sshd -T`; session timeouts,
# limits and forwarding go to their own drop-in, which sorts before 50-cloud-init.conf
# (OpenSSH keeps the first value) and is not touched by the security "ssh" step.
# Port, password login and root login stay with that step, reused from here.
set -Eeuo pipefail

SSH_SESSION_FILE="/etc/ssh/sshd_config.d/01-jacktools-session.conf"
# Setting|validator|message key of the prompt
SSH_SESSION_SETTINGS=(
    "ClientAliveInterval|valid_ssh_alive_interval|maint.ssh.prompt.alive_interval"
    "ClientAliveCountMax|valid_ssh_alive_count|maint.ssh.prompt.alive_count"
    "LoginGraceTime|valid_ssh_grace|maint.ssh.prompt.grace"
    "MaxAuthTries|valid_ssh_auth_tries|maint.ssh.prompt.auth_tries"
    "MaxSessions|valid_ssh_sessions|maint.ssh.prompt.sessions"
)
SSH_FORWARDING_SETTINGS=(X11Forwarding AllowTcpForwarding AllowAgentForwarding)
# msg-keys: maint.ssh.prompt.alive_interval maint.ssh.prompt.alive_count maint.ssh.prompt.grace
# msg-keys: maint.ssh.prompt.auth_tries maint.ssh.prompt.sessions
# msg-keys: maint.ssh.fwd.X11Forwarding maint.ssh.fwd.AllowTcpForwarding maint.ssh.fwd.AllowAgentForwarding

valid_ssh_alive_interval() { [[ "$1" =~ ^(0|[1-9][0-9]{0,3})$ ]] && (( $1 <= 3600 )); }
valid_ssh_alive_count() { [[ "$1" =~ ^[0-9]$|^10$ ]]; }
valid_ssh_grace() { [[ "$1" =~ ^[1-9][0-9]{1,2}$ ]] && (( $1 >= 10 && $1 <= 600 )); }
# Below 3 tries, clients offering several keys can be locked out before the right one.
valid_ssh_auth_tries() { [[ "$1" =~ ^([3-9]|10)$ ]]; }
valid_ssh_sessions() { [[ "$1" =~ ^[1-9][0-9]?$ ]]; }

# Effective value of a setting (sshd -T prints lowercase keys; durations in seconds).
ssh_effective() { ssh_policy_values "${1,,}"; }

maint_ssh_show() {
    local key
    {
        msg maint.ssh.show_title
        for key in Port PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication PubkeyAuthentication \
            ClientAliveInterval ClientAliveCountMax LoginGraceTime MaxAuthTries MaxSessions \
            X11Forwarding AllowTcpForwarding AllowAgentForwarding AllowUsers DenyUsers AllowGroups DenyGroups; do
            printf '  %-30s %s\n' "$key" "$(ssh_effective "$key")"
        done
        printf '\n'
        msg maint.ssh.idle_explained
    } | ui_pager
}

# Settings currently written in the JackTools session drop-in, as "Key value" lines.
ssh_session_current() {
    local file
    file=$(root_path "$SSH_SESSION_FILE")
    [[ -f "$file" ]] && grep -E '^[A-Za-z]+ ' "$file"
    return 0
}

# Warn about settings that sshd -T does not report as written (overridden elsewhere,
# e.g. by an earlier drop-in or a Match block).
ssh_session_check() {
    local -n ssh_session_check_updates="$1"
    local ssh_session_check_line ssh_session_check_key ssh_session_check_value
    for ssh_session_check_line in "${ssh_session_check_updates[@]}"; do
        ssh_session_check_key=${ssh_session_check_line%% *}
        ssh_session_check_value=${ssh_session_check_line#* }
        [[ "$(ssh_effective "$ssh_session_check_key")" == "$ssh_session_check_value" ]] ||
            ui_warn maint.ssh.overridden "$ssh_session_check_key" "$(ssh_effective "$ssh_session_check_key")"
    done
    return 0
}

# ssh_session_write UPDATES_ARRAY: merge "Key value" updates into the drop-in, test, reload,
# and keep it only once a new login has been confirmed.
ssh_session_write() {
    local -n ssh_session_updates="$1"
    local file candidate backup line key
    local -A values=()
    while IFS=' ' read -r key line; do [[ -n "$key" ]] && values["$key"]="$line"; done < <(ssh_session_current)
    for line in "${ssh_session_updates[@]}"; do values["${line%% *}"]="${line#* }"; done
    file=$(root_path "$SSH_SESSION_FILE")
    fs_mktemp candidate
    {
        printf '# Managed by JackTools (Manutenzione → SSH).\n'
        for key in "${!values[@]}"; do printf '%s %s\n' "$key" "${values[$key]}"; done | LC_ALL=C sort
    } >"$candidate"
    if [[ -f "$file" ]] && cmp -s "$candidate" "$file"; then ui_info maint.ssh.unchanged; return 0; fi
    ui_title maint.ssh.new_file
    sed 's/^/  /' "$candidate"
    ui_confirm maint.ssh.confirm_write "$SSH_SESSION_FILE" || return 0
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then msg cleanup.dry_run; return 0; fi
    mkdir -p -- "$(dirname -- "$file")" || return 1
    backup=$(backup_file "$file" sshd-session) || return 1
    atomic_install "$candidate" "$file" 0644 || return 1
    if sshd_config_test >/dev/null 2>&1 && ssh_reload; then
        msg ssh.test_new_session "$(ssh_current_port)"
        if ui_confirm ssh.confirm_new_session; then
            ui_info maint.ssh.saved
            ssh_session_check ssh_session_updates
            return 0
        fi
    fi
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$file"; else rm -f -- "$file"; fi
    ssh_reload || true
    ui_warn ssh.config_restored
    return 1
}

maint_ssh_session() {
    local entry key validator prompt current answer
    local -a updates=()
    msg maint.ssh.session_intro
    for entry in "${SSH_SESSION_SETTINGS[@]}"; do
        IFS='|' read -r key validator prompt <<<"$entry"
        current=$(ssh_effective "$key")
        while true; do
            ui_prompt answer "$prompt" "${current:-?}" || return 0
            [[ -n "$answer" ]] || break
            if "$validator" "$answer"; then updates+=("$key $answer"); break; fi
            ui_warn maint.ssh.invalid_value
        done
    done
    if (( ${#updates[@]} == 0 )); then ui_info maint.ssh.unchanged; return 0; fi
    ssh_session_write updates || true
}

maint_ssh_forwarding() {
    local key i
    local -a labels=() selected=() updates=()
    for key in "${SSH_FORWARDING_SETTINGS[@]}"; do
        labels+=("$(msg_get "maint.ssh.fwd.$key")")
        if [[ "$(ssh_effective "$key")" == no ]]; then selected+=(0); else selected+=(1); fi
    done
    ui_checklist maint.ssh.fwd_title labels selected || return 0
    for i in "${!SSH_FORWARDING_SETTINGS[@]}"; do
        if [[ ${selected[$i]} == 1 ]]; then updates+=("${SSH_FORWARDING_SETTINGS[$i]} yes"); else updates+=("${SSH_FORWARDING_SETTINGS[$i]} no"); fi
    done
    ssh_session_write updates || true
}

maint_ssh_menu() {
    local choice
    local -a items=(
        "$(msg_get maint.ssh.show)" "$(msg_get maint.ssh.session)" "$(msg_get maint.ssh.forwarding)" "$(msg_get maint.ssh.access)"
    )
    while ui_menu choice maint.ssh.title items; do
        case "$choice" in
            0) maint_do maint_ssh_show ;;
            1) maint_do maint_ssh_session ;;
            2) maint_do maint_ssh_forwarding ;;
            3) maint_do run_single_step ssh ;;
        esac
    done
    return 0
}
