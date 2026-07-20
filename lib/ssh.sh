#!/usr/bin/env bash
set -Eeuo pipefail

find_sshd_binary() {
    local candidate
    for candidate in /usr/sbin/sshd /sbin/sshd; do [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }; done
    command -v sshd 2>/dev/null
}

ssh_service_name() {
    systemctl list-unit-files ssh.service >/dev/null 2>&1 && { printf ssh; return; }
    printf sshd
}

validate_and_reload_ssh() {
    local required_users="${1:-}" sshd_bin service user
    sshd_bin=$(find_sshd_binary) || return 1
    "$sshd_bin" -t || return 1
    for user in $required_users; do ssh_user_permitted "$user" || return 1; done
    service=$(ssh_service_name)
    run_cmd systemctl reload "$service"
}

write_managed_ssh_file() {
    local candidate="$1" required_users="${2:-}" destination destination_dir backup=''
    destination=$(root_path /etc/ssh/sshd_config.d/99-jacktools.conf)
    destination_dir=$(dirname -- "$destination")
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then mkdir -p -- "$destination_dir"; else install -d -o root -g root -m 0755 "$destination_dir"; fi
    [[ -e "$destination" ]] && backup=$(backup_file "$destination" sshd-config)
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -- "$candidate" "$destination"; else atomic_install "$candidate" "$destination" 0600; fi
    if ! validate_and_reload_ssh "$required_users"; then
        if [[ -n "$backup" ]]; then cp -a -- "$backup" "$destination"; else rm -f -- "$destination"; fi
        find_sshd_binary >/dev/null && "$(find_sshd_binary)" -t || true
        error "validazione o reload SSH fallito: configurazione ripristinata."
        return 1
    fi
}

replace_ssh_section() {
    local source="$1" output="$2" section="$3"
    awk -v begin="# >>> JACKTOOLS $section >>>" -v end="# <<< JACKTOOLS $section <<<" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$source" >"$output"
}

effective_ssh_policies() {
    local sshd_bin
    sshd_bin=$(find_sshd_binary) || return 1
    "$sshd_bin" -T 2>/dev/null | grep -Ei '^(allowusers|denyusers|allowgroups|denygroups) ' || true
}

managed_allow_users() {
    local file
    file=$(root_path /etc/ssh/sshd_config.d/99-jacktools.conf)
    [[ -r "$file" ]] || return 0
    awk '/^# >>> JACKTOOLS USERS >>>$/{on=1;next}/^# <<< JACKTOOLS USERS <<<$/{on=0} on && /^AllowUsers /{$1=""; sub(/^ /,""); print}' "$file"
}

ensure_user_in_managed_allowlist() {
    local username="$1" file source candidate base current updated rc
    file=$(root_path /etc/ssh/sshd_config.d/99-jacktools.conf); candidate=$(mktemp); base=$(mktemp)
    source=/dev/null; [[ -e "$file" ]] && source="$file"
    current=$(managed_allow_users)
    if grep -qw -- "$username" <<<"$current"; then rm -f -- "$candidate" "$base"; return 0; fi
    updated=$(printf '%s\n%s\n' "$current" "$username" | xargs -n1 | sort -u | xargs)
    replace_ssh_section "$source" "$base" USERS
    { cat "$base"; printf '# >>> JACKTOOLS USERS >>>\nAllowUsers %s\n# <<< JACKTOOLS USERS <<<\n' "$updated"; } >"$candidate"
    rc=0; write_managed_ssh_file "$candidate" "$updated" || rc=$?; rm -f -- "$candidate" "$base"; return "$rc"
}
