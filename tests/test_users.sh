#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_users

mkdir -p "$JACKTOOLS_ROOT/etc"
printf '/bin/sh\n/bin/bash\n/usr/bin/zsh\n' >"$JACKTOOLS_ROOT/etc/shells"
printf 'UID_MIN 1000\nUID_MAX 60000\n' >"$JACKTOOLS_ROOT/etc/login.defs"
printf 'root:x:0:0::/root:/bin/bash\n' >>"$WORK/passwd"
add_user daemon 1 /usr/sbin/nologin
add_user jack 1000 /bin/bash sudo
add_user bob 1001 /usr/sbin/nologin
add_user svc 999 /bin/bash
add_user alice 1002 /usr/bin/zsh
add_user nobody 65534 /bin/bash
add_user ubuntu 1003 /bin/bash sudo adm

# ---- discovery and lookups
assert_eq 'human users with login shell' 'jack alice ubuntu' "$(users_discover | xargs)"
assert_eq 'home lookup' "$WORK/home/jack" "$(user_home jack)"
assert_eq 'groups' 'ubuntu sudo adm' "$(user_groups ubuntu)"
assert_true 'in sudo group' user_in_group jack sudo
assert_false 'not in sudo group' user_in_group alice sudo

# ---- SSH policy
assert_true 'no policy permits everybody' ssh_user_permitted alice
printf 'allowusers jack ubu*\n' >"$WORK/sshd_T"
assert_true 'allowusers match' ssh_user_permitted jack
assert_true 'allowusers wildcard' ssh_user_permitted ubuntu
assert_false 'allowusers excludes others' ssh_user_permitted alice
printf 'denygroups adm\n' >"$WORK/sshd_T"
assert_false 'denygroups excludes member' ssh_user_permitted ubuntu
assert_true 'denygroups lets others in' ssh_user_permitted jack
: >"$WORK/sshd_T"

# ---- account helpers
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting jack@pc'
account_install_key alice "$key"; account_install_key alice "$key"
assert_eq 'key added once' 1 "$(grep -cFx "$key" "$WORK/home/alice/.ssh/authorized_keys")"
assert_eq '.ssh mode' 700 "$(stat -c %a "$WORK/home/alice/.ssh")"
assert_eq 'authorized_keys mode' 600 "$(stat -c %a "$WORK/home/alice/.ssh/authorized_keys")"
reset_commands
account_set_sudo jack nopasswd
assert_eq 'nopasswd fragment' 'jack ALL=(ALL:ALL) NOPASSWD: ALL' "$(cat "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-jack")"
assert_eq 'fragment mode 440' 440 "$(stat -c %a "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-jack")"
assert_eq 'already in sudo: no usermod' '' "$(commands_run)"
assert_eq 'sudo mode nopasswd' nopasswd "$(account_sudo_mode jack)"
account_set_sudo jack password
assert_false 'fragment removed for password mode' test -e "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-jack"
account_set_sudo alice password
assert_contains 'usermod adds sudo group' 'RUN: usermod -aG sudo alice' "$(commands_run)"

# ---- admin step
admin_collect >/dev/null 2>&1 <<EOF2
Bad Name
root
jack
Jack Locke
secret1
secret2
s3cret
s3cret
not-a-key
$key
2
EOF2
assert_eq 'admin name validated' jack "${CFG[ADMIN_USER]}"
assert_eq 'password confirmed' s3cret "${CFG[ADMIN_PASSWORD]}"
assert_eq 'key validated' "$key" "${CFG[ADMIN_KEY]}"
assert_eq 'sudo mode' nopasswd "${CFG[ADMIN_SUDO]}"
assert_contains 'plan update' "aggiornamento dell'utente esistente jack" "$(admin_plan)"
reset_commands
admin_apply
assert_contains 'existing user updated' 'RUN: usermod --shell /bin/bash jack' "$(commands_run)"
assert_contains 'chpasswd used' 'RUN: chpasswd' "$(commands_run)"
assert_false 'password never in command log' grep -q s3cret "$JACKTOOLS_COMMAND_LOG"
assert_false 'password never in log' grep -q s3cret "$JACKTOOLS_TEST_LOG"
assert_true 'admin verify' admin_verify

CFG[ADMIN_USER]=newadmin CFG[ADMIN_PASSWORD]='' CFG[ADMIN_KEY]='' CFG[ADMIN_SUDO]=password CFG[ADMIN_FULLNAME]='New Admin'
reset_commands
admin_apply 2>/dev/null || true
assert_contains 'new user created with sudo group' "RUN: useradd --create-home --shell /bin/bash --comment New\\ Admin --groups sudo newadmin" "$(commands_run)"

# AllowUsers policy: the admin is added to the managed list and SSH reloaded.
printf 'allowusers ubuntu\n' >"$WORK/sshd_T"
sshd_effective_config() { cat "$WORK/sshd_T"; awk '/^AllowUsers/ { $1 = "allowusers"; print }' "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf" 2>/dev/null; }
reset_commands
ssh_allow_user jack
assert_contains 'managed AllowUsers' 'AllowUsers jack' "$(cat "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf")"
assert_contains 'ssh reloaded' 'RUN: systemctl reload' "$(commands_run)"
FAKE_SSHD_INVALID=1
assert_rc 'invalid sshd config rolled back' 1 quiet ssh_allow_user alice
assert_false 'rolled back file keeps previous list' grep -q alice "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf"
FAKE_SSHD_INVALID=0
: >"$WORK/sshd_T"
sshd_effective_config() { cat "$WORK/sshd_T"; }
rm -f "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf"

# ---- remove ubuntu
CFG=()
ENV_OPERATOR=jack
FAKE_PW_STATE=L
rm -f "$WORK/home/jack/.ssh/authorized_keys"
assert_rc 'removal refused without verified admin' 1 quiet remove_ubuntu_collect <<<''
account_install_key jack "$key"
assert_eq 'safe admin found' jack "$(remove_safe_admin)"
assert_rc 'wrong phrase cancels' 1 quiet remove_ubuntu_collect <<<'elimina ubuntu'
remove_ubuntu_collect >/dev/null 2>&1 <<<$'ELIMINA ubuntu\ny\nn'
assert_eq 'home removal requested' yes "${CFG[REMOVE_HOME]}"
reset_commands
remove_ubuntu_apply 2>/dev/null
assert_contains 'userdel with home' 'RUN: userdel --remove ubuntu' "$(commands_run)"
ENV_OPERATOR=ubuntu
assert_rc 'own session refused' 1 quiet remove_ubuntu_collect <<<''
ENV_OPERATOR=jack
printf 'denyusers jack\n' >"$WORK/sshd_T"
assert_rc 'admin excluded by SSH is not safe' 1 quiet remove_safe_admin
finish_tests
