#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

mkdir -p "$JACKTOOLS_ROOT/proc" "$JACKTOOLS_ROOT/etc"
printf 'MemTotal:        2048000 kB\n' >"$JACKTOOLS_ROOT/proc/meminfo"
printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$JACKTOOLS_ROOT/proc/swaps"
printf 'UUID=abc / ext4 defaults 0 1\n' >"$JACKTOOLS_ROOT/etc/fstab"
swap_free_mib() { printf 100000; }

assert_eq 'size 2G in MiB' 2048 "$(swap_size_mib 2G)"
assert_eq 'suggested for small RAM' 2G "$(swap_suggested)"
for value in 512M 2G 0; do assert_true "valid size $value" valid_swap_size "$value"; done
for value in 2 2T -1G 02G; do assert_false "invalid size $value" valid_swap_size "$value"; done

swap_collect >/dev/null 2>&1 <<<$'big\n1g'
assert_eq 'size uppercased and validated' 1G "${CFG[SWAP_SIZE]}"
assert_contains 'plan create' '/swapfile creato' "$(swap_plan)"

swap_apply
cmds=$(commands_run)
assert_contains 'swapfile allocated' "RUN: fallocate -l 1024M $JACKTOOLS_ROOT/swapfile" "$cmds"
assert_contains 'swap enabled' "RUN: swapon $JACKTOOLS_ROOT/swapfile" "$cmds"
assert_eq 'fstab entry added once' 1 "$(grep -c '^/swapfile none swap sw 0 0$' "$JACKTOOLS_ROOT/etc/fstab")"
assert_contains 'other fstab lines kept' 'UUID=abc / ext4' "$(cat "$JACKTOOLS_ROOT/etc/fstab")"

printf '/swapfile\tfile\t1048572\t0\t-2\n' >>"$JACKTOOLS_ROOT/proc/swaps"
assert_true 'compliant when active with fstab entry' swap_compliant
reset_commands
swap_apply
assert_eq 'compliant apply runs nothing' '' "$(commands_run)"

CFG[SWAP_SIZE]=0
swap_apply
assert_contains 'removal turns swap off' "RUN: swapoff $JACKTOOLS_ROOT/swapfile" "$(commands_run)"
assert_eq 'fstab entry removed' 0 "$(grep -c swapfile "$JACKTOOLS_ROOT/etc/fstab" || true)"

swap_free_mib() { printf 1500; }
CFG[SWAP_SIZE]=1G
printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$JACKTOOLS_ROOT/proc/swaps"
assert_rc 'refused without free space' 1 quiet swap_apply
finish_tests
