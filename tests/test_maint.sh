#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_maint

mkdir -p "$JACKTOOLS_ROOT/etc"
printf '/bin/bash\n' >"$JACKTOOLS_ROOT/etc/shells"
printf 'srv1\n' >"$JACKTOOLS_ROOT/etc/hostname"
add_user jack 1000 /bin/bash sudo
add_user alice 1001 /bin/bash sudo
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting jack@pc'
printf '1.2.3.4 5.6.7.8\n' >"$WORK/f2b/sshd"
printf 'Status: active\n' >"$WORK/ufw_status"

# ---- status (read-only, must not fail under errexit)
out=$(set -e; status_report 2>&1)
assert_contains 'status hostname' 'srv1' "$out"
assert_contains 'status services' 'fail2ban: active' "$out"
assert_contains 'status banned count' 'IP bloccati da fail2ban' "$out"
assert_contains 'status upgradable' '7' "$(grep 'aggiornabili' <<<"$out")"
assert_eq 'status runs no command' '' "$(commands_run)"

# ---- fail2ban
assert_eq 'jails parsed' sshd "$(f2b_jails)"
assert_eq 'banned parsed' '1.2.3.4 5.6.7.8' "$(f2b_banned sshd)"
assert_contains 'list shows banned' 'sshd: 1.2.3.4 5.6.7.8' "$(maint_f2b_list)"
maint_f2b_unban_one >/dev/null 2>&1 <<<$'2\ny'
assert_contains 'unban chosen ip' 'RUN: fail2ban-client set sshd unbanip 5.6.7.8' "$(commands_run)"
reset_commands
maint_f2b_unban_one >/dev/null 2>&1 <<<$'1\nn'
assert_eq 'declined unban runs nothing' '' "$(commands_run)"
maint_f2b_unban_all >/dev/null 2>&1 <<<'y'
assert_contains 'unban all' 'RUN: fail2ban-client unban --all' "$(commands_run)"
: >"$WORK/f2b/sshd"
assert_contains 'nothing banned' 'nessun IP bloccato' "$(maint_f2b_unban_one 2>&1 </dev/null)"

# Whitelist: values loaded from the jail file, edited, written back.
assert_rc 'whitelist needs a JackTools jail' 0 quiet maint_f2b_whitelist </dev/null
CFG[F2B_BANTIME]=2d CFG[F2B_FINDTIME]=10m CFG[F2B_MAXRETRY]=3 CFG[F2B_IGNOREIP]='192.168.1.50' CFG[SSH_PORT]=2222
mkdir -p "$JACKTOOLS_ROOT/etc/fail2ban/jail.d"
fail2ban_render >"$JACKTOOLS_ROOT/etc/fail2ban/jail.d/jacktools.local"
CFG=()
apt_is_installed() { true; }
maint_f2b_whitelist >/dev/null 2>&1 <<<$'1\nbad\n1\n10.0.0.0/8\n2\n1\n0'
jail=$(cat "$JACKTOOLS_ROOT/etc/fail2ban/jail.d/jacktools.local")
assert_contains 'whitelist edited (added, first removed)' 'ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8' "$jail"
assert_contains 'other values kept' 'bantime = 2d' "$jail"
assert_contains 'port kept' 'port = 2222' "$jail"

# ---- users
reset_commands
ENV_OPERATOR=jack
maint_user_add_key alice >/dev/null 2>&1 <<<$'nope\n'"$key"
assert_true 'key added' grep -qF "$key" "$WORK/home/alice/.ssh/authorized_keys"
assert_contains 'revoking own sudo refused' 'sessione corrente' "$(maint_user_sudo jack 2>&1 <<<'3')"
assert_contains 'revoking last admin refused' 'nessun altro amministratore' "$(maint_user_sudo alice 2>&1 <<<'3')"
account_install_key jack "$key"
account_set_sudo alice nopasswd
maint_user_sudo alice >/dev/null 2>&1 <<<$'3\ny'
assert_contains 'sudo revoked' 'RUN: gpasswd -d alice sudo' "$(commands_run)"
assert_false 'nopasswd fragment removed' test -e "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-alice"

# ---- docker
printf 'web|Up 2 hours\ndb|Exited (0)\n' >"$WORK/containers"
reset_commands
maint_docker_prune >/dev/null 2>&1 <<<$'2\nn\ny'
assert_contains 'prune all images, no volumes' 'RUN: docker system prune -f -a' "$(commands_run)"
assert_false 'volumes not pruned' grep -q volumes <<<"$(commands_run)"
reset_commands
maint_docker_prune >/dev/null 2>&1 <<<$'1\ny\nn'
assert_eq 'prune cancelled at final confirmation' '' "$(commands_run)"
assert_contains 'logs of chosen container' 'log of db' "$(maint_docker_logs 2>/dev/null <<<'2')"
FAKE_DOCKER=0
assert_contains 'docker unavailable' 'Docker non è installato' "$(maint_docker_logs 2>&1 </dev/null)"
finish_tests
