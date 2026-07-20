#!/usr/bin/env bash
set -Eeuo pipefail

restore_hostname_backup() {
    local old_hostname="$1" backup="$2" hosts_file="$3" rc=0
    hostnamectl set-hostname "$old_hostname" || rc=1
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$hosts_file" || rc=1; else rc=1; fi
    return "$rc"
}

configure_hostname() {
    local current requested hosts_file backup candidate old_short
    current=$(hostnamectl --static 2>/dev/null || hostname)
    printf '%sHostname corrente: %s%s\n' "$GREEN" "$current" "$RESET"
    read -r -p "Nuovo Hostname (vuoto per annullare): " requested || { set_status Hostname ANNULLATO; return 0; }
    [[ -n "$requested" ]] || { set_status Hostname ANNULLATO; return 0; }
    valid_hostname "$requested" || { error "hostname non valido (usare un singolo nome DNS senza dominio)."; set_status Hostname FALLITO; return 1; }
    [[ "$requested" != "$current" ]] || { info "hostname gia configurato."; set_status Hostname OK; return 0; }
    printf 'Verranno impostati hostname "%s" e la relativa voce in /etc/hosts.\n' "$requested"
    confirm_yes "Confermare la modifica?" || { set_status Hostname ANNULLATO; return 0; }

    hosts_file=$(root_path /etc/hosts)
    backup=$(backup_file "$hosts_file" hosts)
    candidate=$(mktemp)
    old_short=${current%%.*}
    awk -v old="$old_short" -v new="$requested" '
        BEGIN { changed=0 }
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == "127.0.1.1" {
            printf "127.0.1.1\t%s\n", new; changed=1; next
        }
        { print }
        END { if (!changed) printf "127.0.1.1\t%s\n", new }
    ' "$hosts_file" >"$candidate"

    if ! run_cmd hostnamectl set-hostname "$requested"; then
        rm -f -- "$candidate"; set_status Hostname FALLITO; return 1
    fi
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        if ! cp -- "$candidate" "$hosts_file"; then
            rm -f -- "$candidate"; set_status Hostname FALLITO; return 1
        fi
    elif ! atomic_install "$candidate" "$hosts_file" "0644"; then
        rm -f -- "$candidate"
        if restore_hostname_backup "$current" "$backup" "$hosts_file"; then set_status Hostname RIPRISTINATO; else set_status Hostname FALLITO; fi
        return 1
    fi
    rm -f -- "$candidate"
    if [[ "$JACKTOOLS_TEST_MODE" != 1 ]] && { [[ $(hostnamectl --static) != "$requested" ]] || ! awk -v expected="$requested" '$1 == "127.0.1.1" && $2 == expected {found=1} END {exit !found}' "$hosts_file"; }; then
        if restore_hostname_backup "$current" "$backup" "$hosts_file"; then set_status Hostname RIPRISTINATO; else set_status Hostname FALLITO; fi
        return 1
    fi
    set_status Hostname OK
}
