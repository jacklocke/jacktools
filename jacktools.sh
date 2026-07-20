#!/usr/bin/env bash
set -Eeuo pipefail

readonly JACKTOOLS_VERSION="1.0.0"
JACKTOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly JACKTOOLS_DIR

for library in common hostname network ssh users customization packages cleanup; do
    # shellcheck source=/dev/null
    source "$JACKTOOLS_DIR/lib/$library.sh"
done

install_traps

usage() {
    cat <<'EOF'
Uso: jacktools.sh [comando]

Comandi:
  menu                  Mostra il menu interattivo
  all                   Esegue la configurazione completa
  hostname              Configura l'hostname
  network               Configura la rete con Netplan
  admin-user            Crea o verifica un amministratore
  remove-ubuntu-user    Elimina in sicurezza l'utente ubuntu
  bashrc                Applica la personalizzazione Bash
  packages              Aggiorna il sistema e installa programmi
  cleanup               Elimina i file temporanei JackTools
  help, --help           Mostra questo aiuto
  version               Mostra la versione
EOF
}

run_mutating_command() {
    local command_name="$1" command_rc=0
    require_disclaimer || return "$?"
    preflight_for "$command_name"
    case "$command_name" in
        all) run_all ;;
        hostname) configure_hostname ;;
        network) configure_network ;;
        admin-user) create_admin_user ;;
        remove-ubuntu-user) remove_ubuntu_user ;;
        bashrc) customize_bashrc ;;
        packages)
            manage_packages || command_rc=$?
            offer_cleanup "$command_rc"
            return "$command_rc"
            ;;
        cleanup) cleanup_jacktools ;;
        *) die "comando sconosciuto: $command_name" ;;
    esac
}

run_all() {
    local phase rc=0
    for phase in hostname network admin-user bashrc packages remove-ubuntu-user; do
        case "$phase" in
            hostname) configure_hostname || rc=1 ;;
            network) configure_network || rc=1 ;;
            admin-user) create_admin_user || rc=1 ;;
            bashrc) customize_bashrc || rc=1 ;;
            packages) manage_packages || rc=1 ;;
            remove-ubuntu-user) remove_ubuntu_user || rc=1 ;;
        esac
        print_section_separator
    done
    print_summary
    offer_cleanup "$rc"
    return "$rc"
}

main_menu() {
    local choice
    while true; do
        print_header
        printf '\n%s%s1. Esegui configurazione completa%s\n\n' "$GREEN" "$BOLD" "$RESET"
        printf '%s' "$GREEN"
        cat <<'EOF'
2. Configura hostname
3. Configura rete
4. Crea utente amministrativo
5. Elimina utente ubuntu
6. Applica personalizzazione Bash
7. Installa o aggiorna programmi
8. Pulizia file temporanei
0. Esci
EOF
        printf '%s' "$RESET"
        read -r -p "Scelta (vuoto per uscire): " choice || return 0
        case "$choice" in
            1) run_mutating_command all || true ;;
            2) run_mutating_command hostname || true ;;
            3) run_mutating_command network || true ;;
            4) run_mutating_command admin-user || true ;;
            5) run_mutating_command remove-ubuntu-user || true ;;
            6) run_mutating_command bashrc || true ;;
            7) run_mutating_command packages || true ;;
            8) run_mutating_command cleanup || true; return 0 ;;
            0) return 0 ;;
            '') return 0 ;;
            *) warn "scelta non valida." ;;
        esac
    done
}

main() {
    local command_name="${1:-menu}" rc=0
    case "$command_name" in
        help|--help|-h) usage ;;
        version) printf 'JackTools %s\n' "$JACKTOOLS_VERSION" ;;
        menu) require_disclaimer || return 0; main_menu ;;
        all|hostname|network|admin-user|remove-ubuntu-user|bashrc|packages|cleanup)
            run_mutating_command "$command_name" || rc=$?
            if [[ "$command_name" != all ]]; then print_summary || rc=1; fi
            return "$rc"
            ;;
        *) usage >&2; die "comando sconosciuto: $command_name" ;;
    esac
}

main "$@"
