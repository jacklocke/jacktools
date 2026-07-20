#!/usr/bin/env bash
set -Eeuo pipefail

safe_cleanup_path() {
    local path="$1"
    [[ "$path" == /tmp/jacktools && -n "$path" && "$path" != /tmp && "$path" != / && ! -L "$path" ]]
}

safe_bootstrap_cleanup_path() {
    [[ "$1" == /tmp/jacktools-bootstrap.sh ]]
}

cleanup_jacktools() {
    local target=/tmp/jacktools bootstrap=/tmp/jacktools-bootstrap.sh confirmed="${1:-0}" exit_code="${2:-0}"
    safe_cleanup_path "$target" || { error "percorso di pulizia non sicuro."; set_status 'Pulizia temporanei' FALLITO; return 1; }
    safe_bootstrap_cleanup_path "$bootstrap" || { error "percorso del bootstrap non sicuro."; set_status 'Pulizia temporanei' FALLITO; return 1; }
    if [[ ! -d "$target" && ! -e "$bootstrap" && ! -L "$bootstrap" ]]; then
        info "nessun file temporaneo JackTools da eliminare."
        set_status 'Pulizia temporanei' 'NON ESEGUITA'
        return 0
    fi
    if [[ "$confirmed" != 1 ]]; then
        confirm_yes "Eliminare definitivamente /tmp/jacktools e /tmp/jacktools-bootstrap.sh? Log, backup e configurazioni resteranno intatti." || { set_status 'Pulizia temporanei' 'NON ESEGUITA'; return 0; }
    fi
    if [[ -d "$target" ]] && ! rm -rf -- /tmp/jacktools; then
        error "impossibile eliminare /tmp/jacktools."
        set_status 'Pulizia temporanei' FALLITO
        return 1
    fi
    if [[ -e "$bootstrap" || -L "$bootstrap" ]] && ! rm -f -- /tmp/jacktools-bootstrap.sh; then
        error "impossibile eliminare /tmp/jacktools-bootstrap.sh."
        set_status 'Pulizia temporanei' FALLITO
        return 1
    fi
    if [[ -e "$target" || -L "$target" || -e "$bootstrap" || -L "$bootstrap" ]]; then
        error "verifica della pulizia fallita: sono rimasti file temporanei JackTools."
        set_status 'Pulizia temporanei' FALLITO
        return 1
    fi
    info "verifica completata: non restano copie temporanee JackTools sulla macchina."
    set_status 'Pulizia temporanei' OK
    exit "$exit_code"
}

offer_cleanup() {
    local exit_code="${1:-0}"
    printf 'La directory /tmp/jacktools e /tmp/jacktools-bootstrap.sh sono copie temporanee. Configurazioni, log e backup persistenti non verranno eliminati.\n'
    if confirm_yes "Vuoi eliminare tutte le copie temporanee JackTools dalla macchina?"; then cleanup_jacktools 1 "$exit_code"; else set_status 'Pulizia temporanei' 'NON ESEGUITA'; fi
}
