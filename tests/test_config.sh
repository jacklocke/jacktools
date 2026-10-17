#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_maint
# shellcheck source=/dev/null
for library in apt docker unattended; do source "$ROOT/lib/install/$library.sh"; done
apt_is_installed() { [[ " ${FAKE_INSTALLED:-} " == *" $1 "* ]]; }
apt_locked() { return 1; }

conf="$WORK/server.conf"
write_conf() { printf '%s\n' "$@" >"$conf"; chmod 600 "$conf"; }

# ---- parser and validation
mkdir -p "$JACKTOOLS_ROOT/usr/share/zoneinfo/Europe" && touch "$JACKTOOLS_ROOT/usr/share/zoneinfo/Europe/Rome"
write_conf '# comment' '' 'STEPS="hostname locale time"' 'HOSTNAME=srv2' 'LOCALE="it_IT.UTF-8"' 'TIMEZONE="Europe/Rome"' 'NTP=on' \
    'ADMIN_FULLNAME="Jack Locke"' 'CUSTOM_MODULES:jack="locale banner"'
config_load "$conf"
assert_eq 'steps loaded' 'hostname locale time' "${CFG[STEPS]}"
assert_eq 'unquoted value' srv2 "${CFG[HOSTNAME]}"
assert_eq 'quoted value with space' 'Jack Locke' "${CFG[ADMIN_FULLNAME]}"
assert_eq 'per-user key' 'locale banner' "${CFG[CUSTOM_MODULES:jack]}"

# shellcheck disable=SC2016 # Malicious input must stay literal.
for bad in 'HOSTNAME=$(id)' 'HOSTNAME="`id`"' 'HOSTNAME=a;rm' 'HOSTNAME=bad.name' 'UNKNOWN=1' 'ADMIN_PASSWORD="secret"' \
           'PACKAGES="curl -oops"' 'STEPS="hostname nosuchstep"' 'SSH_PORT=99999' 'CUSTOM_SUDO:Bad=password' \
           'NTP=maybe' 'hostname=srv' 'HOSTNAME = srv' 'BANNER=../../etc/passwd' 'UFW_ALLOW="22/tcp 1;2"' 'PL_THEME=nosuch' 'PL_THEME="nord;id"'; do
    write_conf 'STEPS="hostname"' "$bad"
    assert_rc "refused: $bad" 1 quiet config_load "$conf"
done
assert_eq 'refused file leaves CFG untouched' srv2 "${CFG[HOSTNAME]}"
write_conf 'HOSTNAME=srv'
assert_rc 'STEPS required' 1 quiet config_load "$conf"
write_conf 'STEPS="hostname"' 'HOSTNAME=srv'
chmod 666 "$conf"
assert_rc 'world-writable file refused' 1 quiet config_load "$conf"
chmod 600 "$conf"
ln -sf "$conf" "$WORK/link.conf"
assert_rc 'symlink refused' 1 quiet config_load "$WORK/link.conf"

# ---- required keys per step
CFG=([STEPS]=network [NET_IFACE]=eth0 [NET_MODE]=static [NET_DNS]=1.1.1.1)
assert_rc 'static network needs address' 1 quiet config_check_step network
CFG[NET_CIDR]=10.0.0.5/24 CFG[NET_GATEWAY]=10.0.0.1
assert_rc 'static network complete' 0 quiet config_check_step network
CFG=([CUSTOM_USERS]=jack [BANNER]=custom)
assert_rc 'customize needs per-user modules' 1 quiet config_check_step customize
CFG[CUSTOM_MODULES:jack]='locale'
assert_rc 'custom banner needs text' 1 quiet config_check_step customize
CFG[BANNER_TEXT]='Hi'
assert_rc 'customize complete' 0 quiet config_check_step customize
CFG[CUSTOM_MODULES:jack]='powerline powerline-theme'
assert_rc 'powerline theme needs PL_THEME' 1 quiet config_check_step customize
CFG[PL_THEME]=nord
assert_rc 'powerline theme complete' 0 quiet config_check_step customize
CFG[CUSTOM_MODULES:jack]='nosuchmodule'
assert_rc 'unknown module refused' 1 quiet config_check_step customize

# ---- engine in config mode: no questions, all steps checked before applying anything
CALLS=''
for id in cfa cfb; do
    eval "${id}_collect() { CALLS+=' ${id}:collect'; }; ${id}_plan() { :; }; ${id}_apply() { CALLS+=' ${id}:apply'; }"
done
MSG['test.cfa']=A; MSG['test.cfb']=B
step_register cfa test.cfa testphase 1
step_register cfb test.cfb testphase 1
CONFIG_REQUIRED['cfa']=''; CONFIG_REQUIRED['cfb']='HOSTNAME'
JT_CONFIG_MODE=1
CFG=()
ids=(cfa cfb)
assert_rc 'missing key aborts before applying' 1 quiet steps_run ids select </dev/null
assert_eq 'nothing collected or applied' '' "$CALLS"
CFG[HOSTNAME]=x
steps_run ids select >/dev/null 2>&1 <<<'y'
assert_eq 'config mode skips collect' ' cfa:apply cfb:apply' "$CALLS"
CALLS=''; JT_ASSUME_YES=1
steps_run ids select >/dev/null 2>&1 </dev/null
assert_eq '--yes needs no confirmation' ' cfa:apply cfb:apply' "$CALLS"
ordered=()
steps_ordered ordered cfb cfa
assert_eq 'steps_ordered follows registration' 'cfa cfb' "${ordered[*]}"
JT_CONFIG_MODE=0 JT_ASSUME_YES=0

# ---- export from a fake server, then read back
mkdir -p "$JACKTOOLS_ROOT/etc/default" "$JACKTOOLS_ROOT/etc/systemd/journald.conf.d" "$JACKTOOLS_ROOT/etc/fail2ban/jail.d" \
    "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d" "$JACKTOOLS_ROOT/etc/apt/apt.conf.d" "$JACKTOOLS_ROOT/proc" "$JACKTOOLS_ROOT/root"
printf '/bin/bash\n' >"$JACKTOOLS_ROOT/etc/shells"
printf 'srv1\n' >"$JACKTOOLS_ROOT/etc/hostname"
printf 'LANG=C.UTF-8\n' >"$JACKTOOLS_ROOT/etc/default/locale"
ln -sf /usr/share/zoneinfo/Europe/Rome "$JACKTOOLS_ROOT/etc/localtime"
time_ntp_enabled() { true; }
printf '[Journal]\nSystemMaxUse=300M\n' >"$JACKTOOLS_ROOT/etc/systemd/journald.conf.d/99-jacktools.conf"
printf 'compress\n' >"$JACKTOOLS_ROOT/etc/logrotate.conf"
printf 'Filename\tType\tSize\tUsed\tPriority\n/swapfile\tfile\t2097148\t0\t-2\n' >"$JACKTOOLS_ROOT/proc/swaps"
add_user jack 1000 /bin/bash sudo
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting jack@pc'
account_install_key jack "$key"
ENV_OPERATOR=jack
CFG=([BANNER]=TARS [CUSTOM_USERS]=jack [CUSTOM_MODULES:jack]='locale banner powerline-theme tmux-aliases' [CUSTOM_EXTRAS:jack]='tmux' [PL_THEME]=kanagawa)
customize_apply >/dev/null 2>&1
CFG=([UNATTENDED_REBOOT]=03:30)
unattended_render_jacktools >"$JACKTOOLS_ROOT/etc/apt/apt.conf.d/52jacktools-unattended-upgrades"
CFG=([SSH_PORT]=2222 [SSH_PASSWORD_AUTH]=no [SSH_ROOT_LOGIN]=no)
ssh_render_hardening >"$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/00-jacktools-hardening.conf"
printf 'port 2222\npasswordauthentication no\npermitrootlogin no\n' >"$WORK/sshd_T"
CFG=([F2B_BANTIME]=1d [F2B_FINDTIME]=10m [F2B_MAXRETRY]=4 [F2B_IGNOREIP]='10.0.0.0/8' [SSH_PORT]=2222)
fail2ban_render >"$JACKTOOLS_ROOT/etc/fail2ban/jail.d/jacktools.local"
printf 'Status: active\n\n2222/tcp ALLOW Anywhere\n443/tcp ALLOW Anywhere\n2222/tcp (v6) ALLOW Anywhere (v6)\n' >"$WORK/ufw_status"
FAKE_INSTALLED='curl tmux unattended-upgrades docker-ce docker-ce-cli containerd.io docker-buildx-plugin'

export_collect
assert_eq 'exported steps' 'admin customize docker fail2ban journald locale motd packages ssh swap time ufw unattended upgrade' "$(tr ' ' '\n' <<<"${CFG[STEPS]}" | sort | xargs)"
assert_eq 'swap size rounded' 2G "${CFG[SWAP_SIZE]}"
assert_eq 'admin key exported' "$key" "${CFG[ADMIN_KEY]}"
assert_eq 'modules read from block' 'locale banner powerline-theme tmux-aliases' "${CFG[CUSTOM_MODULES:jack]}"
assert_eq 'powerline theme read from config.json' kanagawa "${CFG[PL_THEME]}"
assert_eq 'banner read from block' TARS "${CFG[BANNER]}"
assert_eq 'ufw ssh first, v6 duplicates ignored' '2222/tcp 443/tcp' "${CFG[UFW_ALLOW]}"
assert_eq 'docker compose not installed' no "${CFG[DOCKER_COMPOSE]}"
assert_eq 'reboot time' 03:30 "${CFG[UNATTENDED_REBOOT]}"
assert_false 'no password exported' test -v 'CFG[ADMIN_PASSWORD]'
declare -A exported=()
for k in "${!CFG[@]}"; do exported[$k]=${CFG[$k]}; done

config_write "$WORK/export.conf"
chmod 600 "$WORK/export.conf"
assert_contains 'hostname commented' '# HOSTNAME="srv1"' "$(cat "$WORK/export.conf")"
assert_false 'remove_ubuntu never exported' grep -q remove_ubuntu "$WORK/export.conf"
config_load "$WORK/export.conf"
diff=''
for k in "${!exported[@]}"; do [[ "$k" == HOSTNAME || "${CFG[$k]-<missing>}" == "${exported[$k]}" ]] || diff+=" $k"; done
for k in "${!CFG[@]}"; do [[ -v "exported[$k]" ]] || diff+=" +$k"; done
assert_eq 'export then load gives the same configuration' '' "$diff"
ENV_OS_VERSION_ID=24.04 ENV_OS_CODENAME=noble
docker_architecture() { printf amd64; }
for id in ${CFG[STEPS]}; do assert_rc "exported $id is complete" 0 quiet config_check_step "$id"; done

# export_run writes /root/jacktools-<host>-<date>.conf with mode 600 and prints the command.
out=$(export_run 2>&1 <<<'y')
file=$(ls "$JACKTOOLS_ROOT/root"/jacktools-srv1-*.conf)
assert_eq 'export file mode' 600 "$(stat -c %a "$file")"
assert_contains 'command without bootstrap info' 'all --config /root/jacktools-srv1-' "$out"
out=$(JACKTOOLS_BOOTSTRAP_URL=https://tea.example/raw/bootstrap.sh JACKTOOLS_SOURCE_ARGS='--repo https://tea.example/J/JT --ref main' export_command /root/x.conf)
assert_eq 'command with bootstrap source' 'curl -fsSL https://tea.example/raw/bootstrap.sh -o /tmp/jacktools-bootstrap.sh && sudo bash /tmp/jacktools-bootstrap.sh --repo https://tea.example/J/JT --ref main -- all --config /root/x.conf' "$out"

# ---- network in config mode: no netplan try, automatic ping, rollback when it fails
mkdir -p "$JACKTOOLS_ROOT/sys/class/net/eth0/device" "$JACKTOOLS_ROOT/etc/netplan"
CFG=([NET_IFACE]=eth0 [NET_MODE]=dhcp)
JT_CONFIG_MODE=1
reset_commands
network_apply >/dev/null 2>&1 </dev/null
assert_false 'no netplan try in config mode' grep -q 'netplan try' <<<"$(commands_run)"
assert_contains 'netplan applied' 'RUN: netplan apply' "$(commands_run)"
CFG[NET_MODE]=dhcp-dns CFG[NET_DNS]=1.1.1.1
network_ping() { return 1; }
rc=0; network_apply >/dev/null 2>&1 </dev/null || rc=$?
assert_eq 'failed ping restores network' 3 "$rc"
JT_CONFIG_MODE=0
finish_tests
