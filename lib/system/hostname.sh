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

# hosts_render SOURCE NAME: SOURCE with 127.0.1.1 pointing to NAME (added when missing).
hosts_render() {
    awk -v name="$2" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == "127.0.1.1" { if (!done) printf "127.0.1.1\t%s\n", name; done = 1; next }
        { print }
        END { if (!done) printf "127.0.1.1\t%s\n", name }
    ' "$1"
}

hostname_collect() {
    msg hostname.current "$(hostname_current)"
    [[ "$ENV_VIRT_KIND" == container ]] && ui_warn hostname.container_warning
    ui_ask 'CFG[HOSTNAME]' valid_hostname hostname.invalid hostname.prompt
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
# hostname_write NAME: /etc/hostname and the running hostname.
hostname_write() {
    local candidate
    fs_mktemp candidate
    printf '%s\n' "$1" >"$candidate" || return 1
    atomic_install "$candidate" "$(root_path /etc/hostname)" 0644 || return 1
    run hostnamectl set-hostname "$1"
}

hostname_apply() {
    local hosts old
    old=$(hostname_current)
    hosts=$(root_path /etc/hosts)
    if [[ "$old" != "${CFG[HOSTNAME]}" ]]; then
        backup_file "$(root_path /etc/hostname)" hostname >/dev/null || return 1
        hostname_write "${CFG[HOSTNAME]}" || return 1
    fi
    # atomic_install leaves /etc/hosts untouched on failure: only the hostname is put back.
    if ! fs_write_managed "$hosts" hosts 0644 hosts_render "$(fs_source "$hosts")" "${CFG[HOSTNAME]}"; then
        ui_error hostname.hosts_failed
        [[ "$old" != "${CFG[HOSTNAME]}" ]] || return 1
        hostname_write "$old" || true
        return "$STEP_RC_RESTORED"
    fi
    return 0
}

hostname_verify() { [[ "$(hostname_current)" == "${CFG[HOSTNAME]}" ]] && hostname_hosts_ok; }

step_register hostname step.hostname system 1
