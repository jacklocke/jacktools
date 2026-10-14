#!/usr/bin/env bash
# Step "hostname": static hostname and the 127.0.1.1 entry in /etc/hosts.
set -Eeuo pipefail

hostname_current() {
    local file name=''
    file=$(root_path /etc/hostname)
    [[ -r "$file" ]] && IFS= read -r name <"$file"
    [[ -n "$name" ]] || name=$(hostname 2>/dev/null || true)
    printf '%s' "${name%%.*}"
}

# hosts_render SOURCE OUTPUT NAME: 127.0.1.1 points to NAME (added when missing).
hosts_render() {
    awk -v name="$3" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == "127.0.1.1" { if (!done) printf "127.0.1.1\t%s\n", name; done = 1; next }
        { print }
        END { if (!done) printf "127.0.1.1\t%s\n", name }
    ' "$1" >"$2"
}

hostname_collect() {
    local current answer
    current=$(hostname_current)
    msg hostname.current "$current"
    [[ "$ENV_VIRT_KIND" == container ]] && ui_warn hostname.container_warning
    while true; do
        ui_prompt answer hostname.prompt || return 1
        [[ -n "$answer" ]] || return 1
        if valid_hostname "$answer"; then
            CFG[HOSTNAME]="$answer"
            return 0
        fi
        ui_warn hostname.invalid
    done
}

hostname_plan() {
    local current
    current=$(hostname_current)
    if [[ "$current" == "${CFG[HOSTNAME]}" ]] && hostname_hosts_ok; then
        msg steps.plan.compliant
    else
        msg hostname.plan "$current" "${CFG[HOSTNAME]}"
    fi
}

hostname_hosts_ok() {
    awk -v name="${CFG[HOSTNAME]}" '$1 == "127.0.1.1" && $2 == name { found = 1 } END { exit !found }' \
        "$(root_path /etc/hosts)" 2>/dev/null
}

# /etc/hostname is written directly (what hostnamectl does for the static name), then
# hostnamectl updates the running hostname.
hostname_apply() {
    local hosts hostname_file candidate name_candidate backup old
    old=$(hostname_current)
    hosts=$(root_path /etc/hosts)
    hostname_file=$(root_path /etc/hostname)
    [[ -e "$hosts" ]] || touch "$hosts" || return 1
    fs_mktemp candidate
    hosts_render "$hosts" "$candidate" "${CFG[HOSTNAME]}" || return 1
    backup=$(backup_file "$hosts" hosts) || return 1
    if [[ "$old" != "${CFG[HOSTNAME]}" ]]; then
        fs_mktemp name_candidate
        printf '%s\n' "${CFG[HOSTNAME]}" >"$name_candidate" || return 1
        backup_file "$hostname_file" hostname >/dev/null || return 1
        atomic_install "$name_candidate" "$hostname_file" 0644 || return 1
        run hostnamectl set-hostname "${CFG[HOSTNAME]}" || return 1
    fi
    if ! cmp -s "$candidate" "$hosts" && ! atomic_install "$candidate" "$hosts" 0644; then
        ui_error hostname.hosts_failed
        printf '%s\n' "$old" >"$name_candidate" && atomic_install "$name_candidate" "$hostname_file" 0644
        run hostnamectl set-hostname "$old" || true
        [[ -n "$backup" ]] && cp -a -- "$backup" "$hosts"
        return "$STEP_RC_RESTORED"
    fi
    return 0
}

hostname_verify() { [[ "$(hostname_current)" == "${CFG[HOSTNAME]}" ]] && hostname_hosts_ok; }

step_register hostname step.hostname system 1
