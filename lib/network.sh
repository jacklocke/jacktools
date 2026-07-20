#!/usr/bin/env bash
set -Eeuo pipefail

list_physical_interfaces() {
    local path name
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        name=${path##*/}
        [[ "$name" == lo || "$name" == docker* || "$name" == br-* || "$name" == veth* || "$name" == virbr* ]] && continue
        [[ -e "$path/device" ]] || continue
        printf '%s\n' "$name"
    done
}

yaml_list() {
    local input="$1" item first=1
    printf '['
    IFS=, read -r -a yaml_items <<<"$input"
    for item in "${yaml_items[@]}"; do
        item=${item//[[:space:]]/}
        (( first )) || printf ', '
        printf '"%s"' "$item"; first=0
    done
    printf ']'
}

generate_netplan_yaml() {
    local output="$1" interface="$2" mode="$3" cidr="$4" gateway="$5" dns="$6" domains="$7"
    {
        printf 'network:\n  version: 2\n  ethernets:\n    "%s":\n' "$interface"
        case "$mode" in
            dhcp) printf '      dhcp4: true\n' ;;
            dhcp-dns)
                printf '      dhcp4: true\n      dhcp4-overrides:\n        use-dns: false\n'
                printf '      nameservers:\n        addresses: '; yaml_list "$dns"; printf '\n'
                [[ -n "$domains" ]] && { printf '        search: '; yaml_list "$domains"; printf '\n'; }
                ;;
            static)
                printf '      dhcp4: false\n      addresses:\n        - "%s"\n' "$cidr"
                printf '      routes:\n        - to: default\n          via: "%s"\n' "$gateway"
                printf '      nameservers:\n        addresses: '; yaml_list "$dns"; printf '\n'
                [[ -n "$domains" ]] && { printf '        search: '; yaml_list "$domains"; printf '\n'; }
                ;;
        esac
    } >"$output"
}

restore_netplan_backup() {
    local backup_dir="$1" netplan_dir
    netplan_dir=$(root_path /etc/netplan)
    find "$netplan_dir" -mindepth 1 -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -delete
    if compgen -G "$backup_dir/*" >/dev/null; then cp -a -- "$backup_dir"/. "$netplan_dir"/; fi
    if ! run_cmd netplan generate || ! run_cmd netplan apply; then
        error "ripristino Netplan non riuscito; usare la console e il backup $backup_dir."
        return 1
    fi
    # shellcheck disable=SC2034 # Letta da print_summary nel modulo common.sh.
    NETWORK_RESTORED=1
}

record_netplan_rollback() {
    local backup_dir="$1"
    if restore_netplan_backup "$backup_dir"; then
        set_status 'Configurazione rete' RIPRISTINATO
    else
        set_status 'Configurazione rete' FALLITO
    fi
}

verify_network_configuration() {
    local interface="$1" mode="$2" cidr="$3" gateway="$4" dns="$5" domains="$6" ip_only item
    run_cmd ip link show dev "$interface" >/dev/null || return 1
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then return 0; fi
    if [[ "$mode" == static ]]; then
        ip_only=${cidr%/*}
        ip -4 -o addr show dev "$interface" | awk '{print $4}' | grep -Fxq "$cidr" || return 1
        ip -4 route show default dev "$interface" | grep -Fq "via $gateway" || return 1
        ip -4 addr show dev "$interface" | grep -Fq "$ip_only" || return 1
    else
        ip -4 -o addr show dev "$interface" | grep -q 'inet ' || return 1
        ip -4 route show default dev "$interface" | grep -q '^default' || return 1
    fi
    if [[ "$mode" != dhcp ]]; then
        command_exists resolvectl || return 1
        IFS=, read -r -a verify_dns_items <<<"$dns"
        for item in "${verify_dns_items[@]}"; do
            item=${item//[[:space:]]/}
            resolvectl dns "$interface" | grep -Fwq "$item" || return 1
        done
        if [[ -n "$domains" ]]; then
            IFS=, read -r -a verify_domain_items <<<"$domains"
            for item in "${verify_domain_items[@]}"; do
                item=${item//[[:space:]]/}
                resolvectl domain "$interface" | grep -Fwq "$item" || return 1
            done
        fi
    fi
}

valid_ping_target() {
    local target="$1" label
    valid_ipv4 "$target" && return 0
    (( ${#target} >= 1 && ${#target} <= 253 )) || return 1
    IFS=. read -r -a target_labels <<<"$target"
    for label in "${target_labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

ping_three_times() {
    local target="$1" line
    printf '\n%sVerifica con 3 ping verso %s:%s\n' "$BOLD" "$target" "$RESET"
    if run_cmd ping -c 3 -W 3 -- "$target" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
        printf '  %s\n' "$line"
    done; then
        info "ping verso $target riuscito."
    else
        warn "ping verso $target non riuscito; verificare comunque la connettivita desiderata."
    fi
    printf '\n'
}

confirm_network_connectivity() {
    local answer target
    ping_three_times 8.8.8.8
    while true; do
        IFS= read -r -p "La connettivita funziona correttamente? [y/n/check] (vuoto per ripristinare la rete precedente): " answer || return 1
        case "$answer" in
            y|Y) return 0 ;;
            n|N|'') return 1 ;;
            check|CHECK|Check)
                while true; do
                    read -r -p "IP o nome da verificare (vuoto per tornare indietro): " target
                    [[ -n "$target" ]] || break
                    if valid_ping_target "$target"; then ping_three_times "$target"; break; fi
                    warn "IP o nome non valido; riprovare."
                done
                ;;
            *) warn "risposta non valida: usare y, n oppure check." ;;
        esac
    done
}

configure_network() {
    local -a interfaces=()
    local interface mode_choice mode cidr='' gateway='' dns='' domains='' timeout
    local netplan_dir backup_dir stamp candidate managed_file
    mapfile -t interfaces < <(list_physical_interfaces)
    ((${#interfaces[@]})) || { error "nessuna interfaccia fisica idonea rilevata."; set_status 'Configurazione rete' FALLITO; return 1; }
    printf 'Interfacce disponibili:\n'; printf '  %s\n' "${interfaces[@]}"
    if ((${#interfaces[@]} == 1)); then interface=${interfaces[0]}; else
        read -r -p "Interfaccia da configurare (vuoto per annullare): " interface
        [[ -n "$interface" ]] || { set_status 'Configurazione rete' ANNULLATO; return 0; }
        printf '%s\n' "${interfaces[@]}" | grep -Fxq "$interface" || { error "interfaccia non valida."; set_status 'Configurazione rete' FALLITO; return 1; }
    fi
    printf '1. DHCP IPv4\n2. DHCP IPv4 con DNS personalizzati\n3. IPv4 statico\n'
    read -r -p "Modalita (vuoto per annullare): " mode_choice
    case "$mode_choice" in 1) mode=dhcp ;; 2) mode=dhcp-dns ;; 3) mode=static ;; *) set_status 'Configurazione rete' ANNULLATO; return 0 ;; esac
    if [[ "$mode" == static ]]; then
        while true; do
            read -r -p "Indirizzo IPv4 (es. 192.168.1.x/24, vuoto per annullare): " cidr
            [[ -n "$cidr" ]] || { set_status 'Configurazione rete' ANNULLATO; return 0; }
            valid_cidr "$cidr" && break
            warn "indirizzo IPv4 non valido: usare il formato 192.168.1.x/24 e riprovare."
        done
        while true; do
            read -r -p "Gateway IPv4 (vuoto per annullare): " gateway
            [[ -n "$gateway" ]] || { set_status 'Configurazione rete' ANNULLATO; return 0; }
            valid_ipv4 "$gateway" && break
            warn "gateway IPv4 non valido; riprovare."
        done
    fi
    if [[ "$mode" != dhcp ]]; then
        command_exists resolvectl || { error "resolvectl non disponibile: impossibile verificare DNS e domini di ricerca."; set_status 'Configurazione rete' FALLITO; return 1; }
        read -r -p "Server DNS separati da virgola (vuoto per annullare): " dns
        [[ -n "$dns" ]] || { set_status 'Configurazione rete' ANNULLATO; return 0; }
        valid_dns_list "$dns" || { error "lista DNS non valida."; set_status 'Configurazione rete' FALLITO; return 1; }
        read -r -p "Domini di ricerca separati da virgola (vuoto per non impostarli): " domains; valid_search_domains "$domains" || { error "domini di ricerca non validi."; set_status 'Configurazione rete' FALLITO; return 1; }
    fi
    timeout=${JACKTOOLS_NETPLAN_TIMEOUT:-30}; [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=30
    candidate=$(mktemp); generate_netplan_yaml "$candidate" "$interface" "$mode" "$cidr" "$gateway" "$dns" "$domains"
    printf '\nConfigurazione candidata:\n'; sed 's/^/  /' "$candidate"
    if is_ssh_session; then
        printf '%s%sATTENZIONE: rischio di perdita della sessione SSH.%s\n' "$RED" "$BOLD" "$RESET"
    fi
    confirm_yes "Creare il backup e provare questa configurazione?" || { rm -f -- "$candidate"; set_status 'Configurazione rete' ANNULLATO; return 0; }

    netplan_dir=$(root_path /etc/netplan); stamp=$(date '+%Y%m%d-%H%M%S-%N'); backup_dir="$JACKTOOLS_BACKUP_ROOT/netplan-$stamp"
    install -d -m 0700 "$backup_dir"
    if ! cp -a -- "$netplan_dir"/. "$backup_dir"/; then
        error "backup Netplan fallito; nessuna modifica applicata."
        rm -f -- "$candidate"
        set_status 'Configurazione rete' FALLITO
        return 1
    fi
    managed_file="$netplan_dir/99-jacktools-${interface}.yaml"
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -- "$candidate" "$managed_file"; chmod 0600 "$managed_file"; else atomic_install "$candidate" "$managed_file" 0600; fi
    rm -f -- "$candidate"
    if ! run_cmd netplan generate; then record_netplan_rollback "$backup_dir"; return 1; fi
    printf 'La configurazione verra ora applicata temporaneamente. Il rollback automatico scattera dopo %s secondi se non viene confermata.\n' "$timeout"
    if ! run_cmd netplan try --timeout "$timeout"; then record_netplan_rollback "$backup_dir"; return 1; fi
    if ! confirm_network_connectivity; then record_netplan_rollback "$backup_dir"; return 1; fi
    if ! run_cmd netplan apply || ! verify_network_configuration "$interface" "$mode" "$cidr" "$gateway" "$dns" "$domains"; then
        error "verifica di rete fallita; ripristino in corso."
        record_netplan_rollback "$backup_dir"; return 1
    fi
    set_status 'Configurazione rete' OK
}
