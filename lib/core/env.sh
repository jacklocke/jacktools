#!/usr/bin/env bash
# Environment detection and base preflight checks.
set -Eeuo pipefail

ENV_OS_ID=""
ENV_OS_VERSION_ID=""
ENV_OS_PRETTY=""
ENV_OS_CODENAME=""
ENV_VIRT="none"
ENV_VIRT_KIND="bare"
ENV_SSH_CLIENT_IP=""
ENV_OPERATOR=""

readonly ENV_MIN_UBUNTU="22.04"
readonly ENV_MIN_FREE_KB=102400

# os-release is parsed, not sourced.
env_read_os_release() {
    local file key value
    file=$(root_path /etc/os-release)
    [[ -r "$file" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        value=${value#\"}; value=${value%\"}
        case "$key" in
            ID) ENV_OS_ID="$value" ;;
            VERSION_ID) ENV_OS_VERSION_ID="$value" ;;
            PRETTY_NAME) ENV_OS_PRETTY="$value" ;;
            UBUNTU_CODENAME) ENV_OS_CODENAME="$value" ;;
            VERSION_CODENAME) ENV_OS_CODENAME="${ENV_OS_CODENAME:-$value}" ;;
        esac
    done <"$file"
}

# version_ge A B: true when dotted numeric version A >= B.
version_ge() {
    local -a left right
    local i a b
    IFS=. read -r -a left <<<"$1"
    IFS=. read -r -a right <<<"$2"
    for ((i = 0; i < ${#left[@]} || i < ${#right[@]}; i++)); do
        a=${left[i]:-0}; b=${right[i]:-0}
        [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
        (( 10#$a > 10#$b )) && return 0
        (( 10#$a < 10#$b )) && return 1
    done
    return 0
}

env_os_supported() { [[ "$ENV_OS_ID" == ubuntu ]] && version_ge "$ENV_OS_VERSION_ID" "$ENV_MIN_UBUNTU"; }

# Virtualization as reported by systemd-detect-virt (overridable in tests).
env_detect_virt() {
    if [[ -n ${JACKTOOLS_TEST_VIRT:-} ]]; then
        ENV_VIRT="$JACKTOOLS_TEST_VIRT"
    elif command_exists systemd-detect-virt; then
        ENV_VIRT=$(systemd-detect-virt 2>/dev/null || true)
    fi
    ENV_VIRT=${ENV_VIRT:-none}
    case "$ENV_VIRT" in
        none) ENV_VIRT_KIND="bare" ;;
        lxc|lxc-libvirt|systemd-nspawn|docker|podman|rkt|wsl|proot|pouch|openvz) ENV_VIRT_KIND="container" ;;
        *) ENV_VIRT_KIND="vm" ;;
    esac
}

# SSH client address: SSH_CONNECTION when sudo kept it, otherwise `who -m`.
env_detect_ssh() {
    local client _rest who_line
    ENV_SSH_CLIENT_IP=""
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r client _rest <<<"$SSH_CONNECTION"
        ENV_SSH_CLIENT_IP="$client"
    elif [[ "$JACKTOOLS_TEST_MODE" != 1 ]] && command_exists who; then
        who_line=$(LC_ALL=C who -m 2>/dev/null || true)
        [[ "$who_line" =~ \(([0-9A-Fa-f.:]+)\)$ ]] && ENV_SSH_CLIENT_IP="${BASH_REMATCH[1]}"
    fi
    return 0
}

env_is_ssh_session() { [[ -n "$ENV_SSH_CLIENT_IP" || -n ${SSH_TTY:-} ]]; }

env_detect() {
    ENV_OPERATOR="${SUDO_USER:-${USER:-root}}"
    env_read_os_release || true
    env_detect_virt
    env_detect_ssh
}

apt_locked() {
    command_exists fuser || return 1
    fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1
}

# preflight_base: checks every command needs; returns 1 after reporting the first problem.
preflight_base() {
    local available_kb
    if [[ "$JACKTOOLS_TEST_MODE" != 1 && ${EUID} -ne 0 ]]; then ui_error env.not_root; return 1; fi
    if [[ -z "$ENV_OS_ID" ]]; then ui_error env.no_os_release; return 1; fi
    if ! env_os_supported; then ui_error env.unsupported_os "${ENV_OS_PRETTY:-$ENV_OS_ID}" "$ENV_MIN_UBUNTU"; return 1; fi
    if [[ ! -d "$(root_path /run/systemd/system)" ]]; then ui_error env.no_systemd; return 1; fi
    if [[ "$JACKTOOLS_TEST_MODE" != 1 ]]; then
        command_exists apt-get || { ui_error env.no_apt; return 1; }
        available_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
        (( available_kb >= ENV_MIN_FREE_KB )) || { ui_error env.low_disk "$((ENV_MIN_FREE_KB / 1024))"; return 1; }
        log_init
        fs_init_backup_root
    fi
    [[ "$ENV_VIRT_KIND" == bare ]] || ui_info env.virt_detected "$ENV_VIRT"
    env_is_ssh_session && ui_warn env.ssh_session "${ENV_SSH_CLIENT_IP:-?}"
    return 0
}
