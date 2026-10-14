#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_install

# ---- packages.txt parser
printf '# c\n\ncurl default\nvim\n  htop   default  # comment\n' >"$WORK/ok.txt"
parse_packages_file "$WORK/ok.txt"
assert_eq 'parsed names' 'curl vim htop' "${PACKAGE_NAMES[*]}"
assert_eq 'parsed defaults' '1 0 1' "${PACKAGE_DEFAULTS[*]}"
# shellcheck disable=SC2016 # Malicious input must stay literal.
for bad in 'curl; rm -rf /' 'curl yes' 'curl default extra' '-o curl' 'Curl' '$(id)'; do
    printf '%s\n' "$bad" >"$WORK/bad.txt"
    assert_rc "parser refuses: $bad" 1 quiet parse_packages_file "$WORK/bad.txt"
done
assert_true 'shipped packages.txt is valid' parse_packages_file "$ROOT/assets/packages.txt"
assert_false 'docker not listed as a package' grep -qw docker <<<"${PACKAGE_NAMES[*]}"
assert_true 'powerline preselected' bash -c "grep -Eq '^powerline default$' '$ROOT/assets/packages.txt'"

# ---- apt helpers
APT_UPDATED=0
apt_update_once; apt_update_once
assert_eq 'apt-get update runs once' 1 "$(grep -c 'RUN: apt-get update' "$JACKTOOLS_COMMAND_LOG")"
APT_UPDATED=0
apt_locked() { return 0; }
assert_rc 'locked apt refused' 1 quiet apt_update_once
apt_locked() { return 1; }
APT_UPDATED=0
reset_commands
JACKTOOLS_TEST_RUN_RC=1
assert_rc 'failed update stops the step' 1 quiet upgrade_apply
assert_false 'no upgrade after failed update' grep -q 'upgrade' <<<"$(commands_run)"
JACKTOOLS_TEST_RUN_RC=0

reset_commands
upgrade_apply
assert_contains 'upgrade keeps local configs' 'RUN: env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold upgrade' "$(commands_run)"
mkdir -p "$JACKTOOLS_ROOT/var/run" && touch "$JACKTOOLS_ROOT/var/run/reboot-required"
upgrade_apply
assert_true 'reboot flagged when required' test -n "${STATE_FLAGS[REBOOT]:-}"

# ---- packages step
FAKE_INSTALLED='curl'
packages_collect >"$WORK/out" 2>&1 <<<''
assert_contains 'installed packages labelled' 'curl (già installato)' "$(cat "$WORK/out")"
assert_eq 'defaults selected' 'zip unzip curl wget nano tmux powerline htop' "${CFG[PACKAGES]}"
assert_contains 'plan lists only missing' 'da installare: zip unzip wget nano tmux powerline htop' "$(packages_plan)"
reset_commands
APT_UPDATED=0
packages_apply
assert_false 'installed package skipped' grep -q 'install -- curl' <<<"$(commands_run)"
assert_contains 'missing package installed' 'install -- powerline' "$(commands_run)"
FAKE_INSTALLED='zip unzip curl wget nano tmux powerline htop'
assert_true 'packages verify' packages_verify
assert_contains 'compliant plan' 'già conforme' "$(packages_plan)"
assert_rc 'nothing selected cancels' 1 quiet packages_collect <<<$'1 2 3 4 5 6 7 9\n'

ENV_VIRT_KIND=vm
packages_collect >"$WORK/out" 2>&1 <<<''
assert_contains 'qemu agent proposed in VM' 'qemu-guest-agent (consigliato' "$(cat "$WORK/out")"
assert_contains 'qemu agent preselected in VM' 'qemu-guest-agent' "${CFG[PACKAGES]}"
ENV_VIRT_KIND=bare

# ---- docker
ENV_OS_VERSION_ID=24.04 ENV_OS_CODENAME=noble
docker_architecture() { printf amd64; }
docker_fetch_key() { printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nTEST\n-----END PGP PUBLIC KEY BLOCK-----\n' >"$1"; }
docker_engine_ok() { true; }
docker_compose_ok() { true; }
FAKE_INSTALLED='docker.io'
docker_collect >/dev/null 2>&1 <<<$'y\ny\ny'
assert_eq 'conflict removal authorised' yes "${CFG[DOCKER_REMOVE_CONFLICTS]}"
assert_eq 'compose requested' yes "${CFG[DOCKER_COMPOSE]}"
assert_contains 'plan lists conflicts' 'docker.io' "$(docker_plan)"
reset_commands
APT_UPDATED=0
docker_apply
cmds=$(commands_run)
assert_contains 'conflicts removed' 'remove -- docker.io' "$cmds"
assert_contains 'engine installed' 'install -- docker-ce docker-ce-cli containerd.io docker-buildx-plugin' "$cmds"
assert_contains 'compose installed' 'install -- docker-compose-plugin' "$cmds"
assert_contains 'service enabled' 'RUN: systemctl enable --now docker' "$cmds"
assert_eq 'deb822 source' $'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc' "$(cat "$JACKTOOLS_ROOT/etc/apt/sources.list.d/docker.sources")"
assert_true 'keyring installed' grep -q 'BEGIN PGP' "$JACKTOOLS_ROOT/etc/apt/keyrings/docker.asc"
assert_rc 'refusing conflict removal cancels' 1 quiet docker_collect <<<$'y\nn'

docker_fetch_key() { printf 'not a key\n' >"$1"; }
rm -f "$JACKTOOLS_ROOT/etc/apt/sources.list.d/docker.sources"
assert_rc 'invalid key refused' 1 quiet docker_setup_repository
assert_false 'no source left after failure' test -e "$JACKTOOLS_ROOT/etc/apt/sources.list.d/docker.sources"
ENV_OS_VERSION_ID=20.04
assert_rc 'unsupported ubuntu refused' 1 quiet docker_collect <<<'y'

# ---- unattended-upgrades
FAKE_INSTALLED=''
unattended_collect >/dev/null 2>&1 <<<$'y\ny\n25:00\n03:30'
assert_eq 'reboot time validated' 03:30 "${CFG[UNATTENDED_REBOOT]}"
reset_commands
APT_UPDATED=0
unattended_apply
assert_contains 'package installed' 'install -- unattended-upgrades' "$(commands_run)"
assert_contains 'periodic file' 'APT::Periodic::Unattended-Upgrade "1";' "$(cat "$JACKTOOLS_ROOT/etc/apt/apt.conf.d/20auto-upgrades")"
assert_contains 'reboot time written' 'Automatic-Reboot-Time "03:30"' "$(cat "$JACKTOOLS_ROOT/etc/apt/apt.conf.d/52jacktools-unattended-upgrades")"
FAKE_INSTALLED='unattended-upgrades'
assert_true 'unattended verify' unattended_verify
assert_contains 'unattended compliant' 'già conforme' "$(unattended_plan)"
unattended_collect >/dev/null <<<$'y\nn'
assert_eq 'no reboot' no "${CFG[UNATTENDED_REBOOT]}"
assert_contains 'plan detects change' 'nessun riavvio automatico' "$(unattended_plan)"
finish_tests
