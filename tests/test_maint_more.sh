#!/usr/bin/env bash
# Maintenance additions: firewall, SSH settings, user list and passwords, fail2ban extras.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_maint

mkdir -p "$JACKTOOLS_ROOT/etc"
printf '/bin/bash\n' >"$JACKTOOLS_ROOT/etc/shells"
add_user jack 1000 /bin/bash sudo
add_user alice 1001 /bin/bash
add_user daemon 1 /usr/sbin/nologin
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting jack@pc'
account_install_key jack "$key"
printf 'port 2222\nclientaliveinterval 0\nclientalivecountmax 3\nlogingracetime 120\nmaxauthtries 6\nmaxsessions 10\nx11forwarding yes\nallowtcpforwarding yes\nallowagentforwarding yes\n' >"$WORK/sshd_T"

# ---- firewall
printf 'Status: active\n\n     To                         Action      From\n     --                         ------      ----\n[ 1] 2222/tcp                   ALLOW IN    Anywhere\n[ 2] 443/tcp                    ALLOW IN    Anywhere\n[ 3] 2222/tcp (v6)              ALLOW IN    Anywhere (v6)\n' >"$WORK/ufw_numbered"
printf 'Status: active\n' >"$WORK/ufw_status"
assert_eq 'numbered rules parsed' $'1|2222/tcp  ALLOW IN  Anywhere\n2|443/tcp  ALLOW IN  Anywhere\n3|2222/tcp (v6)  ALLOW IN  Anywhere (v6)' "$(fw_rules)"
reset_commands
maint_fw_delete >/dev/null 2>&1 <<<'1'
assert_eq 'ssh rule protected' '' "$(commands_run)"
maint_fw_delete >/dev/null 2>&1 <<<'3'
assert_eq 'ssh v6 rule protected too' '' "$(commands_run)"
maint_fw_delete >/dev/null 2>&1 <<<$'2\ny'
assert_contains 'other rule deleted by number' 'RUN: ufw --force delete 2' "$(commands_run)"
reset_commands
maint_fw_add >/dev/null 2>&1 <<<$'8080/tcp\n\n1\ny'
assert_contains 'allow rule added' 'RUN: ufw allow 8080/tcp' "$(commands_run)"
reset_commands
maint_fw_add >/dev/null 2>&1 <<<$'bad\n5432/tcp\nnope\n10.0.0.0/8\n1\ny'
assert_contains 'rule restricted to a source network' 'RUN: ufw allow from 10.0.0.0/8 to any port 5432 proto tcp' "$(commands_run)"
reset_commands
maint_fw_add >/dev/null 2>&1 <<<$'2222/tcp\n\n2\ny'
assert_contains 'limit rule' 'RUN: ufw limit 2222/tcp' "$(commands_run)"
reset_commands
maint_fw_toggle >/dev/null 2>&1 <<<'y'
assert_contains 'disable after confirmation' 'RUN: ufw disable' "$(commands_run)"
printf 'Status: inactive\n' >"$WORK/ufw_status"
reset_commands
maint_fw_toggle >/dev/null 2>&1 <<<'y'
assert_eq 'enable allows ssh port first' $'RUN: ufw allow 2222/tcp\nRUN: ufw --force enable' "$(commands_run)"
assert_contains 'iptables shown read-only' 'DOCKER-USER' "$(maint_fw_iptables)"

# ---- SSH settings
out=$(maint_ssh_show)
assert_contains 'effective settings shown' 'MaxAuthTries                   6' "$out"
for v in 0 300 3600; do assert_true "alive interval $v" valid_ssh_alive_interval "$v"; done
for v in -1 3601 x; do assert_false "alive interval $v" valid_ssh_alive_interval "$v"; done
assert_false 'auth tries below 3 refused' valid_ssh_auth_tries 2
assert_false 'grace below 10 refused' valid_ssh_grace 5
reset_commands
# interval 300, count 2 (after one invalid), keep the rest; confirm write, confirm new login.
maint_ssh_session >/dev/null 2>&1 <<<$'300\n99\n2\n\n\n\ny\ny'
session="$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/01-jacktools-session.conf"
assert_eq 'session drop-in' $'# Managed by JackTools (Manutenzione → SSH).\nClientAliveCountMax 2\nClientAliveInterval 300' "$(cat "$session")"
assert_contains 'ssh reloaded' 'RUN: systemctl reload' "$(commands_run)"
# Forwarding: turn X11 off; previous session values are kept.
maint_ssh_forwarding >/dev/null 2>&1 <<<$'1\n\ny\ny'
assert_contains 'x11 disabled' 'X11Forwarding no' "$(cat "$session")"
assert_contains 'tcp kept allowed' 'AllowTcpForwarding yes' "$(cat "$session")"
assert_contains 'earlier values kept' 'ClientAliveInterval 300' "$(cat "$session")"
cp "$session" "$WORK/session.prev"
maint_ssh_session >/dev/null 2>&1 <<<$'60\n\n\n\n\ny\nn'
assert_true 'unconfirmed login restores the file' cmp -s "$WORK/session.prev" "$session"
FAKE_SSHD_INVALID=1
maint_ssh_session >/dev/null 2>&1 <<<$'90\n\n\n\n\ny'
assert_true 'invalid sshd config restores the file' cmp -s "$WORK/session.prev" "$session"
FAKE_SSHD_INVALID=0

# ---- users
user_password_state() { case "$1" in jack) printf P ;; *) printf L ;; esac; }
out=$(maint_users_list <<<'1')
assert_contains 'real users listed' 'jack' "$out"
assert_false 'system account hidden' grep -q daemon <<<"$out"
assert_contains 'key count and password' 'impostata' "$(grep '^jack' <<<"$out")"
assert_contains 'sudo mode shown' 'password' "$(grep '^jack' <<<"$out")"
out=$(maint_users_list <<<'2')
assert_contains 'all accounts include system ones' 'daemon' "$out"
reset_commands
maint_user_password alice >/dev/null 2>&1 <<<$'one\ntwo\nS3cret!\nS3cret!\ny\ny'
assert_contains 'password set' 'RUN: chpasswd' "$(commands_run)"
assert_contains 'expiry requested' 'RUN: passwd -e alice' "$(commands_run)"
assert_false 'password not logged' grep -q 'S3cret' "$JACKTOOLS_COMMAND_LOG" "$JACKTOOLS_TEST_LOG"
reset_commands
maint_user_password alice >/dev/null 2>&1 <<<$'x\nx\nn'
assert_eq 'declined reset runs nothing' '' "$(commands_run)"

# ---- fail2ban extras
printf '1.2.3.4\n' >"$WORK/f2b/sshd"
assert_contains 'search finds banned ip' '1.2.3.4 è bloccato nella jail sshd' "$(maint_f2b_search <<<'1.2.3.4')"
assert_contains 'search free ip' 'non è bloccato' "$(maint_f2b_search <<<'9.9.9.9')"
ENV_SSH_CLIENT_IP=192.168.1.50
reset_commands
maint_f2b_ban >/dev/null 2>&1 <<<'192.168.1.50'
assert_eq 'own address never banned' '' "$(commands_run)"
maint_f2b_ban >/dev/null 2>&1 <<<'127.0.0.1'
assert_eq 'loopback never banned' '' "$(commands_run)"
maint_f2b_ban >/dev/null 2>&1 <<<$'bad\n203.0.113.9\ny'
assert_contains 'manual ban' 'RUN: fail2ban-client set sshd banip 203.0.113.9' "$(commands_run)"
printf '2026-10-10 10:00:00 fail2ban.actions [1]: NOTICE [sshd] Ban 1.2.3.4\n' >"$WORK/f2b.log"
assert_contains 'log events shown' 'Ban 1.2.3.4' "$(maint_f2b_log)"
: >"$WORK/f2b.log"
assert_contains 'empty log' 'nessun blocco' "$(maint_f2b_log 2>&1)"
assert_contains 'jail status' 'Banned IP list' "$(maint_f2b_status)"
# ---- regressions found in review
# A failing command inside a menu action goes back to the menu instead of quitting.
printf 'Status: active\n' >"$WORK/ufw_status"
out=$(JACKTOOLS_TEST_RUN_RC=1 maint_fw_menu 2>&1 <<<$'2\n8080/tcp\n\n1\ny\n0') && rc=0 || rc=$?
assert_eq 'failed action returns to the menu' 0 "$rc"
assert_contains 'failure reported' 'operazione non completata' "$out"
out=$(JACKTOOLS_TEST_RUN_RC=1 maintenance_menu 2>&1 <<<$'2\n0') && rc=0 || rc=$?
assert_eq 'failed upgrade keeps maintenance open' 0 "$rc"
# Blocking the SSH port is refused.
reset_commands
maint_fw_add >/dev/null 2>&1 <<<$'2222/tcp\n\n3\ny'
assert_eq 'deny on ssh port refused' '' "$(commands_run)"
maint_fw_add >/dev/null 2>&1 <<<$'2222/tcp\n203.0.113.0/24\n3\ny'
assert_eq 'deny on ssh port refused also per source' '' "$(commands_run)"
maint_fw_add >/dev/null 2>&1 <<<$'25/tcp\n\n3\ny'
assert_contains 'deny on other ports allowed' 'RUN: ufw deny 25/tcp' "$(commands_run)"
# A value overridden elsewhere is reported after saving.
rm -f "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/01-jacktools-session.conf"
out=$(maint_ssh_session 2>&1 <<<$'\n\n\n4\n\ny\ny')
assert_contains 'override detected through sshd -T' 'MaxAuthTries risulta ancora 6' "$out"
# Dry-run: maintenance never writes files.
rm -rf "$WORK/home/alice/.ssh"
JACKTOOLS_DRY_RUN=1 maint_user_add_key alice >/dev/null 2>&1 <<<"$key"
assert_false 'dry-run adds no key' test -e "$WORK/home/alice/.ssh/authorized_keys"
account_set_sudo alice nopasswd
JACKTOOLS_DRY_RUN=1 account_set_sudo alice password >/dev/null 2>&1
assert_true 'dry-run keeps sudoers fragment' test -e "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-alice"
# A ban covering the operator's own address is refused.
assert_true '192.168.1.50 in 192.168.1.0/24' ipv4_in_cidr 192.168.1.50 192.168.1.0/24
assert_true 'any address in 0.0.0.0/0' ipv4_in_cidr 192.168.1.50 0.0.0.0/0
assert_false '192.168.1.50 not in 192.168.2.0/24' ipv4_in_cidr 192.168.1.50 192.168.2.0/24
assert_true 'plain ip counts as /32' ipv4_in_cidr 10.0.0.1 10.0.0.1
ENV_SSH_CLIENT_IP=192.168.1.50
reset_commands
maint_f2b_ban >/dev/null 2>&1 <<<$'192.168.1.0/24\ny'
assert_eq 'network containing own ip refused' '' "$(commands_run)"
finish_tests
