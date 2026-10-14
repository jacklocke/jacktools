#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_security

mkdir -p "$JACKTOOLS_ROOT/etc"
printf '/bin/bash\n' >"$JACKTOOLS_ROOT/etc/shells"
add_user jack 1000 /bin/bash sudo
add_user alice 1001 /bin/bash
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting jack@pc'
printf 'port 22\npasswordauthentication yes\npermitrootlogin without-password\n' >"$WORK/sshd_T"
APT_UPDATED=1

# ---- ssh: no admin with a key, so password login stays.
assert_false 'no key admin yet' ssh_key_admin_available
ssh_collect >"$WORK/out" 2>&1 <<<$'\n\n'
assert_contains 'warns that passwords stay on' 'resta attivo per non chiuderti fuori' "$(cat "$WORK/out")"
assert_eq 'password auth kept' keep "${CFG[SSH_PASSWORD_AUTH]}"
assert_eq 'root login default no' no "${CFG[SSH_ROOT_LOGIN]}"
assert_eq 'port kept' 22 "${CFG[SSH_PORT]}"

account_install_key jack "$key"
assert_true 'key admin available' ssh_key_admin_available
ssh_collect >/dev/null 2>&1 <<<$'y\n2\n99999\n2222'
assert_eq 'password auth disabled' no "${CFG[SSH_PASSWORD_AUTH]}"
assert_eq 'root key only' prohibit-password "${CFG[SSH_ROOT_LOGIN]}"
assert_eq 'port validated' 2222 "${CFG[SSH_PORT]}"
expected=$'# Managed by JackTools.\nPort 2222\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password'
assert_eq 'hardening file' "$expected" "$(ssh_render_hardening)"
assert_contains 'plan shows port' '2222' "$(ssh_plan)"

# Port change with UFW active: the new port is opened before sshd is reloaded.
printf 'Status: active\n\n22/tcp ALLOW Anywhere\n' >"$WORK/ufw_status"
reset_commands
ssh_apply >/dev/null 2>&1 <<<'y'
cmds=$(commands_run)
assert_contains 'new port allowed in ufw' 'RUN: ufw allow 2222/tcp' "$cmds"
assert_true 'ufw rule precedes reload' bash -c "grep -n 'ufw allow 2222' <<<'$cmds' | cut -d: -f1 | { read a; [[ \$a == 1 ]]; }"
assert_contains 'sshd reloaded' 'RUN: systemctl reload' "$cmds"
assert_eq 'file installed' "$expected" "$(cat "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/00-jacktools-hardening.conf")"
printf 'port 2222\npasswordauthentication no\npermitrootlogin prohibit-password\n' >"$WORK/sshd_T"
assert_true 'verify reads effective config' ssh_verify
assert_contains 'compliant plan' 'già conforme' "$(ssh_plan)"

# Socket activation: a port change regenerates ssh.socket.
printf 'port 2222\npasswordauthentication no\npermitrootlogin prohibit-password\n' >"$WORK/sshd_T"
CFG[SSH_PORT]=2200
FAKE_SOCKET=1
reset_commands
ssh_apply >/dev/null 2>&1 <<<'y'
assert_contains 'socket restarted on port change' $'RUN: systemctl daemon-reload\nRUN: systemctl restart ssh.socket' "$(commands_run)"
FAKE_SOCKET=0

# Not confirming the new login restores the previous file.
cp "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/00-jacktools-hardening.conf" "$WORK/prev"
CFG[SSH_PORT]=2300
rc=0; ssh_apply >/dev/null 2>&1 <<<'n' || rc=$?
assert_eq 'unconfirmed login is RESTORED' 3 "$rc"
assert_true 'previous file back' cmp -s "$WORK/prev" "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/00-jacktools-hardening.conf"
# Invalid sshd configuration is rolled back.
FAKE_SSHD_INVALID=1
rc=0; ssh_apply >/dev/null 2>&1 <<<'y' || rc=$?
assert_eq 'invalid config fails' 1 "$rc"
assert_true 'previous file back after invalid config' cmp -s "$WORK/prev" "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/00-jacktools-hardening.conf"
FAKE_SSHD_INVALID=0
# Key removed after collect: password login is not disabled.
rm "$WORK/home/jack/.ssh/authorized_keys"
CFG[SSH_PASSWORD_AUTH]=no CFG[ADMIN_KEY]=''
printf 'port 22\npasswordauthentication yes\n' >"$WORK/sshd_T"
assert_rc 'refused without key admin at apply time' 1 quiet ssh_apply <<<'y'
account_install_key jack "$key"

# ---- ufw
for rule in 22 22/tcp 51820/udp 65535; do assert_true "ufw rule $rule" valid_ufw_rule "$rule"; done
for rule in 0 65536 22/icmp tcp '22 tcp'; do assert_false "ufw rule $rule" valid_ufw_rule "$rule"; done
CFG[SSH_PORT]=2222
ufw_collect >/dev/null 2>&1 <<<$'2 3\n\n8080/tcp, bad\n8080/tcp, 51820/udp'
assert_eq 'ssh port first, then extras' '2222/tcp 443/tcp 8080/tcp 51820/udp' "${CFG[UFW_ALLOW]}"
printf 'Status: inactive\n' >"$WORK/ufw_status"
reset_commands
ufw_apply
cmds=$(commands_run)
assert_contains 'defaults set' $'RUN: ufw default deny incoming\nRUN: ufw default allow outgoing\nRUN: ufw allow 2222/tcp' "$cmds"
assert_contains 'enabled last' 'RUN: ufw --force enable' "$(tail -1 <<<"$cmds")"
printf 'Status: active\n\n2222/tcp ALLOW Anywhere\n443/tcp ALLOW Anywhere\n8080/tcp ALLOW Anywhere\n51820/udp ALLOW Anywhere\n' >"$WORK/ufw_status"
assert_true 'ufw verify' ufw_verify
reset_commands
ufw_apply
assert_eq 'compliant ufw runs nothing' '' "$(commands_run)"
FAKE_UFW=0
reset_commands
ufw_apply 2>/dev/null || true
assert_contains 'ufw installed when missing' 'install -- ufw' "$(commands_run)"
FAKE_UFW=1

# ---- fail2ban
for ip in 1.2.3.4 10.0.0.0/8 2001:db8::1 2001:db8::/32 ::1; do assert_true "ip $ip" valid_ip_or_cidr "$ip"; done
for ip in 1.2.3 host.example 10.0.0.0/33 '1.2.3.4;x'; do assert_false "ip $ip" valid_ip_or_cidr "$ip"; done
ENV_SSH_CLIENT_IP=192.168.1.50
fail2ban_collect >/dev/null 2>&1 <<<$'0\n3\nforever\n\n2d\ny\n10.0.0.0/8, nope\n10.0.0.0/8'
assert_eq 'maxretry validated' 3 "${CFG[F2B_MAXRETRY]}"
assert_eq 'findtime default' 10m "${CFG[F2B_FINDTIME]}"
assert_eq 'bantime' 2d "${CFG[F2B_BANTIME]}"
assert_eq 'whitelist has own ip first' '192.168.1.50 10.0.0.0/8' "${CFG[F2B_IGNOREIP]}"
expected=$'# Managed by JackTools.\n[DEFAULT]\nbantime = 2d\nfindtime = 10m\nmaxretry = 3\nignoreip = 127.0.0.1/8 ::1 192.168.1.50 10.0.0.0/8\n\n[sshd]\nenabled = true\nport = 2222'
assert_eq 'jail file' "$expected" "$(fail2ban_render)"
FAKE_INSTALLED=''
apt_is_installed() { [[ " $FAKE_INSTALLED " == *" $1 "* ]]; }
reset_commands
fail2ban_apply
assert_contains 'fail2ban installed' 'install -- fail2ban' "$(commands_run)"
assert_contains 'service restarted' 'RUN: systemctl restart fail2ban' "$(commands_run)"
assert_eq 'jail written' "$expected" "$(cat "$JACKTOOLS_ROOT/etc/fail2ban/jail.d/jacktools.local")"
FAKE_F2B_RUNNING=1 FAKE_INSTALLED=fail2ban
assert_true 'fail2ban verify' fail2ban_verify
CFG[F2B_BANTIME]=1h FAKE_F2B_INVALID=1
assert_rc 'invalid jail refused' 1 quiet fail2ban_apply
assert_eq 'previous jail restored' "$expected" "$(cat "$JACKTOOLS_ROOT/etc/fail2ban/jail.d/jacktools.local")"
FAKE_F2B_INVALID=0
ENV_SSH_CLIENT_IP=''
fail2ban_collect >/dev/null 2>&1 <<<$'\n\n\n\n'
assert_eq 'no own ip without ssh session' '' "${CFG[F2B_IGNOREIP]}"
finish_tests
