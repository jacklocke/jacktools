#!/usr/bin/env bash
# Step "network": Netplan DHCP / DHCP with custom DNS / static IPv4 on one interface.
# Applied with `netplan try` (automatic rollback on timeout), a connectivity check and,
# on any failure, restoration of the whole previous /etc/netplan directory.
set -Eeuo pipefail

NETWORK_MODES=(dhcp dhcp-dns static)
NETWORK_PING_DEFAULT="8.8.8.8"

# Interfaces that can carry the server address: physical ones first; when there is none
# (main interface is a bridge or bond, unusual virtual NIC) the remaining non-loopback
# interfaces, except those created by Docker, libvirt, veth pairs and tunnels.
network_iface_ignored() {
    case "$1" in lo|docker*|br-*|veth*|virbr*|tap*|tun*|wg*|bonding_masters) return 0 ;; esac
    return 1
}

network_interfaces() {
    local path name found=0
    for path in "$(root_path /sys/class/net)"/*; do
        [[ -d "$path" ]] || continue
        name=${path##*/}
        network_iface_ignored "$name" && continue
        [[ -e "$path/device" ]] || continue
        printf '%s\n' "$name"
        found=1
    done
    (( found )) && return 0
    for path in "$(root_path /sys/class/net)"/*; do
        [[ -d "$path" ]] || continue
        name=${path##*/}
        network_iface_ignored "$name" || printf '%s\n' "$name"
    done
    return 0
}

network_iface_is_physical() { [[ -e "$(root_path /sys/class/net)/$1/device" ]]; }

# Everything in /sys/class/net, for the error message.
network_all_interfaces() {
    local path
    for path in "$(root_path /sys/class/net)"/*; do [[ -d "$path" ]] && printf '%s ' "${path##*/}"; done
    return 0
}

network_managed_file() { printf '%s' "$(root_path /etc/netplan)/99-jacktools-${CFG[NET_IFACE]}.yaml"; }

# network_yaml_list "a, b": ["a", "b"]
network_yaml_list() {
    local item first=1
    local -a items
    IFS=, read -r -a items <<<"$1"
    printf '['
    for item in "${items[@]}"; do
        (( first )) || printf ', '
        printf '"%s"' "${item//[[:space:]]/}"
        first=0
    done
    printf ']'
}

network_render() {
    printf 'network:\n  version: 2\n  ethernets:\n    "%s":\n' "${CFG[NET_IFACE]}"
    case "${CFG[NET_MODE]}" in
        dhcp) printf '      dhcp4: true\n' ;;
        dhcp-dns) printf '      dhcp4: true\n      dhcp4-overrides:\n        use-dns: false\n' ;;
        static)
            printf '      dhcp4: false\n      addresses:\n        - "%s"\n' "${CFG[NET_CIDR]}"
            printf '      routes:\n        - to: default\n          via: "%s"\n' "${CFG[NET_GATEWAY]}"
            ;;
    esac
    if [[ "${CFG[NET_MODE]}" != dhcp ]]; then
        printf '      nameservers:\n        addresses: %s\n' "$(network_yaml_list "${CFG[NET_DNS]}")"
        [[ -z "${CFG[NET_SEARCH]:-}" ]] || printf '        search: %s\n' "$(network_yaml_list "${CFG[NET_SEARCH]}")"
    fi
    return 0
}

# network_ask RESULT_VAR KEY VALIDATOR: repeat until valid; empty input cancels.
network_ask() {
    local -n network_ask_result="$1"
    local network_ask_key="$2" network_ask_validator="$3" network_ask_answer
    while true; do
        ui_prompt network_ask_answer "$network_ask_key" || return 1
        [[ -n "$network_ask_answer" ]] || return 1
        if "$network_ask_validator" "$network_ask_answer"; then
            network_ask_result="$network_ask_answer"
            return 0
        fi
        ui_warn network.invalid_value
    done
}

network_collect() {
    local -a interfaces modes
    local choice value=''
    mapfile -t interfaces < <(network_interfaces)
    if (( ${#interfaces[@]} == 0 )); then ui_error network.no_interfaces "$(network_all_interfaces)"; return 1; fi
    network_iface_is_physical "${interfaces[0]}" || ui_warn network.virtual_interfaces
    if (( ${#interfaces[@]} == 1 )); then
        CFG[NET_IFACE]="${interfaces[0]}"
        msg network.single_interface "${CFG[NET_IFACE]}"
    else
        ui_menu choice network.interface.title interfaces ui.menu.cancel || return 1
        CFG[NET_IFACE]="${interfaces[$choice]}"
    fi
    modes=("$(msg_get network.mode.dhcp)" "$(msg_get network.mode.dhcp_dns)" "$(msg_get network.mode.static)")
    ui_menu choice network.mode.title modes ui.menu.cancel || return 1
    CFG[NET_MODE]="${NETWORK_MODES[$choice]}"
    CFG[NET_CIDR]=''; CFG[NET_GATEWAY]=''; CFG[NET_DNS]=''; CFG[NET_SEARCH]=''
    if [[ "${CFG[NET_MODE]}" == static ]]; then
        network_ask value network.prompt.cidr valid_cidr || return 1
        CFG[NET_CIDR]="$value"
        network_ask value network.prompt.gateway valid_ipv4 || return 1
        CFG[NET_GATEWAY]="$value"
    fi
    if [[ "${CFG[NET_MODE]}" != dhcp ]]; then
        network_ask value network.prompt.dns valid_ipv4_list || return 1
        CFG[NET_DNS]="$value"
        while true; do
            ui_prompt value network.prompt.search || return 1
            if valid_domain_list "$value"; then CFG[NET_SEARCH]="$value"; break; fi
            ui_warn network.invalid_value
        done
    fi
    return 0
}

network_plan() {
    local file
    file=$(network_managed_file)
    if [[ -f "$file" ]] && cmp -s <(network_render) "$file"; then
        msg steps.plan.compliant
        return 0
    fi
    msg network.plan_file "$file"
    network_render | sed 's/^/  /'
    msg network.plan_try "${JACKTOOLS_NETPLAN_TIMEOUT:-30}"
    env_is_ssh_session && msg network.plan_ssh_risk
    return 0
}

# Restore every YAML file from the backup directory, then regenerate and apply.
network_restore() {
    local backup_dir="$1" netplan_dir
    netplan_dir=$(root_path /etc/netplan)
    find "$netplan_dir" -mindepth 1 -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -delete
    if compgen -G "$backup_dir/*" >/dev/null; then cp -a -- "$backup_dir"/. "$netplan_dir"/; fi
    if run netplan generate && run netplan apply; then
        state_flag NETWORK_RESTORED
        ui_warn network.restored "$backup_dir"
        return "$STEP_RC_RESTORED"
    fi
    ui_error network.restore_failed "$backup_dir"
    return "$STEP_RC_FAILED"
}

network_ping() {
    local target="$1"
    msg network.ping "$target"
    if run ping -c 3 -W 3 -- "$target"; then ui_info network.ping_ok "$target"; return 0; fi
    ui_warn network.ping_failed "$target"
    return 1
}

# Interactive confirmation after `netplan try`: y keeps, n/empty restores, check pings more.
network_confirm_connectivity() {
    local answer target
    network_ping "$NETWORK_PING_DEFAULT" || true
    while true; do
        ui_prompt answer network.connectivity_prompt || return 1
        case "$answer" in
            y|Y) return 0 ;;
            n|N|'') return 1 ;;
            check|CHECK)
                while true; do
                    ui_prompt target network.check_prompt || break
                    [[ -n "$target" ]] || break
                    if valid_host_target "$target"; then network_ping "$target" || true; break; fi
                    ui_warn network.invalid_value
                done
                ;;
            *) ui_warn network.connectivity_invalid ;;
        esac
    done
}

network_apply() {
    local netplan_dir backup_dir file candidate timeout
    netplan_dir=$(root_path /etc/netplan)
    file=$(network_managed_file)
    fs_mktemp candidate
    network_render >"$candidate" || return 1
    [[ -f "$file" ]] && cmp -s "$candidate" "$file" && return 0
    timeout=${JACKTOOLS_NETPLAN_TIMEOUT:-30}
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=30

    mkdir -p -- "$netplan_dir" || return 1
    backup_dir=$(backup_file "$netplan_dir" netplan) || { ui_error network.backup_failed; return 1; }
    atomic_install "$candidate" "$file" 0600 || return 1
    run netplan generate || { network_restore "$backup_dir"; return; }
    if [[ "$JT_CONFIG_MODE" == 1 ]]; then
        # Nobody to answer netplan try: apply, then keep it only if the gateway world answers.
        run netplan apply || { network_restore "$backup_dir"; return; }
        network_ping "$NETWORK_PING_DEFAULT" || { network_restore "$backup_dir"; return; }
    else
        msg network.try_notice "$timeout"
        run netplan try --timeout "$timeout" || { network_restore "$backup_dir"; return; }
        network_confirm_connectivity || { network_restore "$backup_dir"; return; }
        run netplan apply || { network_restore "$backup_dir"; return; }
    fi
    if [[ "$JACKTOOLS_TEST_MODE" != 1 ]] && ! network_verify_live; then
        ui_error network.verify_failed
        network_restore "$backup_dir"
        return
    fi
    return 0
}

# Live state check: address, default route and resolver settings on the interface.
network_verify_live() {
    local iface="${CFG[NET_IFACE]}" item
    local -a items
    ip link show dev "$iface" >/dev/null 2>&1 || return 1
    if [[ "${CFG[NET_MODE]}" == static ]]; then
        ip -4 -o addr show dev "$iface" | awk '{print $4}' | grep -Fxq -- "${CFG[NET_CIDR]}" || return 1
        ip -4 route show default dev "$iface" | grep -Fq -- "via ${CFG[NET_GATEWAY]}" || return 1
    else
        ip -4 -o addr show dev "$iface" | grep -q 'inet ' || return 1
        ip -4 route show default dev "$iface" | grep -q '^default' || return 1
    fi
    [[ "${CFG[NET_MODE]}" == dhcp ]] && return 0
    command_exists resolvectl || return 0
    IFS=, read -r -a items <<<"${CFG[NET_DNS]}"
    for item in "${items[@]}"; do resolvectl dns "$iface" | grep -Fwq -- "${item//[[:space:]]/}" || return 1; done
    return 0
}

network_verify() { [[ -f "$(network_managed_file)" ]] && cmp -s <(network_render) "$(network_managed_file)"; }

step_register network step.network system 0 container
