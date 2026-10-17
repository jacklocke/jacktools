#!/usr/bin/env bash
# Minimal TAP-like helpers shared by every test file.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TESTS_RUN=0
TESTS_FAILED=0

pass() { printf 'ok - %s\n' "$1"; TESTS_RUN=$((TESTS_RUN + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); }
assert_true() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
assert_false() { local name="$1"; shift; if "$@"; then fail "$name"; else pass "$name"; fi; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        printf '  expected: %q\n  actual:   %q\n' "$expected" "$actual" >&2
        fail "$name"
    fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else printf '  missing: %q\n' "$needle" >&2; fail "$name"; fi
}
# assert_rc NAME EXPECTED_RC CMD...: exact return code.
assert_rc() {
    local name="$1" expected="$2" rc=0
    shift 2
    "$@" || rc=$?
    assert_eq "$name" "$expected" "$rc"
}
# quiet CMD...: run CMD discarding its output (keeps the assertion output visible).
quiet() { "$@" >/dev/null 2>&1; }
finish_tests() { printf '1..%d\n' "$TESTS_RUN"; (( TESTS_FAILED == 0 )); }

# load_core: source the core libraries against a throw-away root.
load_core() {
    WORK=$(mktemp -d)
    trap 'rm -rf -- "$WORK"' EXIT
    export JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT" NO_COLOR=1
    export JACKTOOLS_ROOT="$WORK/root" JACKTOOLS_BACKUP_ROOT="$WORK/backups"
    export JACKTOOLS_TEST_LOG="$WORK/test.log" JACKTOOLS_COMMAND_LOG="$WORK/commands.log"
    mkdir -p -- "$JACKTOOLS_ROOT"
    local library
    for library in log msg ui exec fs validate state env steps cleanup config; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/core/$library.sh"
    done
    msg_load it
    # Deterministic environment: never inherit the virtualization of the test machine.
    export JACKTOOLS_TEST_VIRT="${JACKTOOLS_TEST_VIRT:-none}"
    env_detect
}

# load_system: core plus every system-phase step.
load_system() {
    load_core
    local library
    for library in hostname locale time network swap journald motd; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/system/$library.sh"
    done
}

# load_install: core plus the installation-phase steps, with a fake package database:
# FAKE_INSTALLED lists the packages dpkg reports as installed.
load_install() {
    load_core
    local library
    for library in apt docker unattended; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/install/$library.sh"
    done
    FAKE_INSTALLED=''
    apt_is_installed() { [[ " $FAKE_INSTALLED " == *" $1 "* ]]; }
    apt_locked() { return 1; }
}

# load_users: system + users phase with fake passwd/group databases and SSH config.
# Files: $WORK/passwd, $WORK/group, $WORK/sshd_T (output of sshd -T).
load_users() {
    load_system
    local library
    for library in install/apt security/ssh users/account users/admin users/powerline_theme users/customize users/remove_ubuntu; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/$library.sh"
    done
    : >"$WORK/passwd"; : >"$WORK/group"; : >"$WORK/sshd_T"
    users_passwd() { cat "$WORK/passwd"; }
    users_groupdb() { cat "$WORK/group"; }
    sshd_effective_config() { cat "$WORK/sshd_T"; }
    sshd_config_test() { [[ ${FAKE_SSHD_INVALID:-0} == 0 ]]; }
    sudoers_valid() { grep -Eq '^[a-z_][a-z0-9_-]* ALL=\(ALL:ALL\) NOPASSWD: ALL$' "$1"; }
    user_password_state() { printf '%s' "${FAKE_PW_STATE:-L}"; }
}

# load_security: users + security phase. Fakes: $WORK/ufw_status, FAKE_UFW (installed),
# FAKE_SOCKET (ssh.socket active), FAKE_F2B_INVALID, FAKE_F2B_RUNNING.
load_security() {
    load_users
    local library
    for library in ufw fail2ban; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/security/$library.sh"
    done
    : >"$WORK/ufw_status"
    ufw_status() { cat "$WORK/ufw_status"; }
    ssh_socket_active() { [[ ${FAKE_SOCKET:-0} == 1 ]]; }
    ssh_service_active() { true; }
    f2b_config_test() { [[ ${FAKE_F2B_INVALID:-0} == 0 ]]; }
    f2b_running() { [[ ${FAKE_F2B_RUNNING:-0} == 1 ]]; }
    command_exists() {
        case "$1" in
            ufw) [[ ${FAKE_UFW:-1} == 1 ]] ;;
            *) command -v "$1" >/dev/null 2>&1 ;;
        esac
    }
}

# load_maint: security + maintenance. Fakes: $WORK/f2b/<jail> (banned IPs, one line),
# $WORK/containers ("name|status" lines), FAKE_DOCKER (installed and responding).
load_maint() {
    load_security
    local library
    for library in status fail2ban users firewall ssh docker export menu; do
        # shellcheck source=/dev/null
        source "$ROOT/lib/maint/$library.sh"
    done
    mkdir -p "$WORK/f2b"
    : >"$WORK/containers"
    f2b_client() {
        if [[ "$1" == status && -z "${2:-}" ]]; then
            # shellcheck disable=SC2016 # Backticks are part of the fail2ban-client output.
            printf 'Status\n|- Number of jail: 1\n`- Jail list:\t%s\n' "$(find "$WORK/f2b" -mindepth 1 -printf '%f\n' | sort | paste -sd, | sed 's/,/, /g')"
        else
            # shellcheck disable=SC2016 # Backticks are part of the fail2ban-client output.
            printf '`- Actions\n   `- Banned IP list:\t%s\n' "$(cat "$WORK/f2b/$2")"
        fi
    }
    docker_query() {
        case "$1 ${2:-}" in
            'info '*) [[ ${FAKE_DOCKER:-1} == 1 ]] ;;
            'system df') printf 'TYPE TOTAL\nImages 3\n' ;;
            'ps -a') if [[ "$4" == '{{.Names}}' ]]; then cut -d'|' -f1 "$WORK/containers"; else sed 's/|/  (/; s/$/)/' "$WORK/containers"; fi ;;
            'logs --tail') printf 'log of %s\n' "${!#}" ;;
        esac
    }
    status_service_state() { printf active; }
    : >"$WORK/ufw_numbered"; : >"$WORK/f2b.log"
    fw_ufw_numbered() { cat "$WORK/ufw_numbered"; }
    fw_ufw_verbose() { cat "$WORK/ufw_status"; }
    fw_iptables_list() { printf 'Chain INPUT (policy DROP)\nChain DOCKER-USER\n'; }
    f2b_log_events() { cat "$WORK/f2b.log"; }
    status_upgradable_count() { printf 7; }
    command_exists() {
        case "$1" in
            ufw) [[ ${FAKE_UFW:-1} == 1 ]] ;;
            docker|fail2ban-client) true ;;
            *) command -v "$1" >/dev/null 2>&1 ;;
        esac
    }
}

# add_user NAME UID SHELL [GROUPS...]: fake account with a real home under $WORK/home.
add_user() {
    local name="$1" uid="$2" shell="$3" group
    mkdir -p "$WORK/home/$name"
    printf '%s:x:%s:%s::%s:%s\n' "$name" "$uid" "$uid" "$WORK/home/$name" "$shell" >>"$WORK/passwd"
    printf '%s:x:%s:\n' "$name" "$uid" >>"$WORK/group"
    shift 3
    for group in "$@"; do
        if grep -q "^$group:" "$WORK/group"; then
            sed -i -E "s/^($group:x:[0-9]+:)(.*)$/\1\2,$name/; s/^($group:x:[0-9]+:),/\1/" "$WORK/group"
        else
            printf '%s:x:%s:%s\n' "$group" "$((RANDOM + 2000))" "$name" >>"$WORK/group"
        fi
    done
}

# commands_run: commands recorded by run() in test mode.
commands_run() { cat "$JACKTOOLS_COMMAND_LOG" 2>/dev/null || true; }
reset_commands() { : >"$JACKTOOLS_COMMAND_LOG"; }
