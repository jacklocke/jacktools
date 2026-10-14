#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

os_release() { mkdir -p "$JACKTOOLS_ROOT/etc"; printf '%s\n' "$@" >"$JACKTOOLS_ROOT/etc/os-release"; }

assert_true '24.04 >= 22.04' version_ge 24.04 22.04
assert_true '22.04 >= 22.04' version_ge 22.04 22.04
assert_true '22.10 >= 22.04' version_ge 22.10 22.04
assert_false '20.04 < 22.04' version_ge 20.04 22.04
assert_true '26.04 >= 22.04' version_ge 26.04 22.04
assert_false 'garbage version refused' version_ge 'x.y' 22.04

# shellcheck disable=SC2016 # Malicious input must stay literal.
os_release 'NAME="Ubuntu"' 'VERSION_ID="24.04"' 'ID=ubuntu' 'PRETTY_NAME="Ubuntu 24.04.1 LTS"' 'EVIL=$(touch /tmp/jt-pwned)'
env_detect
assert_eq 'os id parsed' ubuntu "$ENV_OS_ID"
assert_eq 'os version parsed' 24.04 "$ENV_OS_VERSION_ID"
assert_eq 'pretty name parsed' 'Ubuntu 24.04.1 LTS' "$ENV_OS_PRETTY"
assert_true 'ubuntu 24.04 supported' env_os_supported

mkdir -p "$JACKTOOLS_ROOT/run/systemd/system"
assert_rc 'preflight passes on supported system' 0 quiet preflight_base

os_release 'ID=ubuntu' 'VERSION_ID="20.04"'
env_detect
assert_false 'ubuntu 20.04 refused' env_os_supported
assert_contains 'preflight reports old ubuntu' '22.04' "$(preflight_base 2>&1 || true)"
os_release 'ID=debian' 'VERSION_ID="12"'
env_detect
assert_false 'debian refused' env_os_supported
rm -f "$JACKTOOLS_ROOT/etc/os-release"
ENV_OS_ID=''
assert_rc 'missing os-release fails preflight' 1 quiet preflight_base

for case in 'none bare' 'lxc container' 'kvm vm' 'qemu vm' 'systemd-nspawn container'; do
    read -r virt kind <<<"$case"
    JACKTOOLS_TEST_VIRT="$virt" env_detect_virt
    assert_eq "virt $virt is $kind" "$kind" "$ENV_VIRT_KIND"
done

SSH_CONNECTION='192.168.1.50 51234 192.168.1.10 22' env_detect_ssh
assert_eq 'ssh client ip from SSH_CONNECTION' 192.168.1.50 "$ENV_SSH_CLIENT_IP"
SSH_CONNECTION='' env_detect_ssh
assert_eq 'no ssh client without SSH_CONNECTION in tests' '' "$ENV_SSH_CLIENT_IP"
finish_tests
