#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_system

net="$JACKTOOLS_ROOT/sys/class/net"
mkdir -p "$net/eth0/device" "$net/lo" "$net/docker0" "$net/veth1/device" "$JACKTOOLS_ROOT/etc/netplan"
printf 'network: {version: 2}\n' >"$JACKTOOLS_ROOT/etc/netplan/50-cloud-init.yaml"
assert_eq 'only physical interfaces listed' eth0 "$(network_interfaces)"

# No physical NIC (main interface is a bridge or bond): the virtual ones are offered.
net2="$WORK/root2/sys/class/net"
mkdir -p "$net2/vmbr0" "$net2/bond0" "$net2/lo" "$net2/docker0" "$net2/veth9" "$net2/br-abc"
touch "$net2/bonding_masters"
assert_eq 'fallback to bridge and bond' 'bond0 vmbr0' "$(JACKTOOLS_ROOT="$WORK/root2" network_interfaces | xargs)"
out=$(JACKTOOLS_ROOT="$WORK/root2" network_collect 2>&1 <<<'0' || true)
assert_contains 'virtual interfaces announced' 'nessuna interfaccia fisica trovata' "$out"
mkdir -p "$WORK/root3/sys/class/net/lo" "$WORK/root3/sys/class/net/docker0"
out=$(JACKTOOLS_ROOT="$WORK/root3" network_collect 2>&1 </dev/null || true)
assert_contains 'error lists what was found' 'Interfacce presenti: docker0 lo' "$out"

network_collect >/dev/null 2>&1 <<<$'3\n10.0.0.5\n10.0.0.5/24\n10.0.0.1\n1.1.1.1, 9.9.9.9\nlan.example.com'
assert_eq 'interface auto-selected' eth0 "${CFG[NET_IFACE]}"
assert_eq 'static mode' static "${CFG[NET_MODE]}"
assert_eq 'cidr re-asked until valid' 10.0.0.5/24 "${CFG[NET_CIDR]}"
assert_eq 'dns list' '1.1.1.1, 9.9.9.9' "${CFG[NET_DNS]}"
expected='network:
  version: 2
  ethernets:
    "eth0":
      dhcp4: false
      addresses:
        - "10.0.0.5/24"
      routes:
        - to: default
          via: "10.0.0.1"
      nameservers:
        addresses: ["1.1.1.1", "9.9.9.9"]
        search: ["lan.example.com"]'
assert_eq 'static yaml' "$expected" "$(network_render)"
assert_rc 'cancel at mode menu' 1 quiet network_collect <<<'0'

network_collect >/dev/null <<<'1'
assert_eq 'dhcp yaml' $'network:\n  version: 2\n  ethernets:\n    "eth0":\n      dhcp4: true' "$(network_render)"

# Successful apply: generate, try, connectivity confirmed, apply.
network_apply >/dev/null 2>&1 <<<'y'
managed="$JACKTOOLS_ROOT/etc/netplan/99-jacktools-eth0.yaml"
assert_eq 'managed file written' "$(network_render)" "$(cat "$managed")"
assert_eq 'managed file mode 600' 600 "$(stat -c %a "$managed")"
assert_contains 'netplan sequence' $'RUN: netplan generate\nRUN: netplan try --timeout 30\nRUN: ping -c 3 -W 3 -- 8.8.8.8\nRUN: netplan apply' "$(commands_run)"
assert_true 'verify' network_verify
assert_contains 'compliant plan' 'già conforme' "$(network_plan)"

# Rejected connectivity: previous files restored, rc 3.
reset_commands
network_collect >/dev/null <<<'2
8.8.4.4
'
rc=0; network_apply >/dev/null 2>&1 <<<'n' || rc=$?
assert_eq 'rollback returns RESTORED' 3 "$rc"
assert_eq 'previous managed file restored' $'network:\n  version: 2\n  ethernets:\n    "eth0":\n      dhcp4: true' "$(cat "$managed")"
assert_true 'unrelated file kept' test -f "$JACKTOOLS_ROOT/etc/netplan/50-cloud-init.yaml"
assert_true 'network restored flag' test -n "${STATE_FLAGS[NETWORK_RESTORED]:-}"

# The "check" answer pings another host before asking again.
reset_commands
network_apply >/dev/null 2>&1 <<<$'check\n192.168.1.1\ny'
assert_contains 'check pings the requested host' 'RUN: ping -c 3 -W 3 -- 192.168.1.1' "$(commands_run)"
finish_tests
