#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

zoneinfo="$JACKTOOLS_ROOT/usr/share/zoneinfo"
mkdir -p "$zoneinfo/Europe" "$zoneinfo/Etc" "$JACKTOOLS_ROOT/etc"
touch "$zoneinfo/Europe/Rome" "$zoneinfo/Etc/UTC"
ln -s /usr/share/zoneinfo/Etc/UTC "$JACKTOOLS_ROOT/etc/localtime"
time_ntp_enabled() { [[ ${FAKE_NTP:-no} == yes ]]; }

assert_eq 'current zone from /etc/localtime' Etc/UTC "$(time_current_zone)"
time_collect >/dev/null 2>&1 <<<$'Mars/Base\nEurope/Rome\ny'
assert_eq 'zone validated' Europe/Rome "${CFG[TIMEZONE]}"
assert_eq 'ntp requested' on "${CFG[NTP]}"
time_collect >/dev/null <<<$'\nn'
assert_eq 'empty keeps current zone' Etc/UTC "${CFG[TIMEZONE]}"
assert_eq 'ntp declined keeps setting' keep "${CFG[NTP]}"

ENV_VIRT_KIND=container
time_collect >/dev/null <<<''
assert_eq 'ntp untouched in container' keep "${CFG[NTP]}"
ENV_VIRT_KIND=bare

CFG[TIMEZONE]=Europe/Rome CFG[NTP]=on
plan=$(time_plan)
assert_contains 'plan zone' 'Etc/UTC → Europe/Rome' "$plan"
assert_contains 'plan ntp' 'NTP' "$plan"
time_apply
assert_contains 'timezone set' 'RUN: timedatectl set-timezone Europe/Rome' "$(commands_run)"
assert_contains 'ntp enabled' 'RUN: timedatectl set-ntp true' "$(commands_run)"

reset_commands
CFG[TIMEZONE]=Etc/UTC
FAKE_NTP=yes time_apply
assert_eq 'compliant apply runs nothing' '' "$(commands_run)"
FAKE_NTP=yes
assert_true 'verify compliant' time_verify
finish_tests
