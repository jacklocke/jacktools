#!/usr/bin/env bash
set -Eeuo pipefail

render_managed_bashrc() {
    local source="$1" customization="$2" output="$3"
    awk '
        $0 == "# >>> JACKTOOLS CUSTOMIZATION >>>" { skip=1; next }
        $0 == "# <<< JACKTOOLS CUSTOMIZATION <<<" { skip=0; next }
        !skip { lines[++count]=$0 }
        END {
            while (count > 0 && lines[count] == "") count--
            for (i=1; i<=count; i++) print lines[i]
        }
    ' "$source" >"$output"
    {
        printf '\n# >>> JACKTOOLS CUSTOMIZATION >>>\n'
        while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done <"$customization"
        printf '# <<< JACKTOOLS CUSTOMIZATION <<<\n'
    } >>"$output"
}

bashrc_has_managed_customization() {
    local bashrc="$1" begin_count end_count
    begin_count=$(grep -c '^# >>> JACKTOOLS CUSTOMIZATION >>>$' "$bashrc" || true)
    end_count=$(grep -c '^# <<< JACKTOOLS CUSTOMIZATION <<<$' "$bashrc" || true)
    if (( begin_count == 0 && end_count == 0 )); then return 1; fi
    (( begin_count == 1 && end_count == 1 )) || return 2
}

apply_bashrc_to_user() {
    local username="$1" home group bashrc backup candidate marker_rc
    id "$username" >/dev/null 2>&1 || { error "utente inesistente: $username"; return 1; }
    home=$(getent passwd "$username" | cut -d: -f6); group=$(id -gn "$username"); bashrc="$home/.bashrc"
    [[ -e "$bashrc" ]] || install -o "$username" -g "$group" -m 0644 /dev/null "$bashrc"
    if bashrc_has_managed_customization "$bashrc"; then
        info "personalizzazione Bash gia presente per $username: nessuna modifica necessaria."
        return 0
    else
        marker_rc=$?
        if (( marker_rc == 2 )); then error "marcatori JackTools incompleti nel .bashrc di $username; modifica rifiutata."; return 1; fi
    fi
    backup=$(backup_file "$bashrc" "bashrc-$username"); candidate=$(mktemp)
    render_managed_bashrc "$bashrc" "$JACKTOOLS_DIR/assets/bashrc_customization" "$candidate"
    if ! bash -n "$candidate"; then rm -f -- "$candidate"; [[ -n "$backup" ]] && cp -a -- "$backup" "$bashrc"; return 1; fi
    if cmp -s "$candidate" "$bashrc"; then rm -f -- "$candidate"; return 0; fi
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -- "$candidate" "$bashrc"; else atomic_install "$candidate" "$bashrc" "$(stat -c %a "$bashrc")" "$username" "$group"; fi
    rm -f -- "$candidate"
}

customize_bashrc() {
    local defaults input username rc=0
    [[ -r "$JACKTOOLS_DIR/assets/bashrc_customization" ]] || { error "asset Bash non disponibile."; set_status 'Personalizzazione Bash' FALLITO; return 1; }
    defaults="${NEW_ADMIN_USER:-}"
    [[ "$ORIGINAL_USER" != root ]] && defaults="$defaults $ORIGINAL_USER"
    defaults=$(xargs <<<"$defaults")
    read -r -p "Utenti a cui applicare la personalizzazione Bash (suggeriti: ${defaults:-nessuno}, vuoto per annullare): " input
    [[ -n "$input" ]] || { set_status 'Personalizzazione Bash' SALTATO; return 0; }
    printf 'Il blocco gestito verra sostituito per: %s\n' "$input"
    confirm_yes "Continuare?" || { set_status 'Personalizzazione Bash' ANNULLATO; return 0; }
    for username in $input; do apply_bashrc_to_user "$username" || rc=1; done
    if (( rc )); then
        set_status 'Personalizzazione Bash' FALLITO
    else
        # shellcheck disable=SC2034 # Letta da print_summary nel modulo common.sh.
        NEW_SHELL_REQUIRED=1
        set_status 'Personalizzazione Bash' OK
    fi
    return "$rc"
}

install_tmux_configuration() {
    local username home group destination
    confirm_yes "Creare o aggiornare .tmux.conf?" || return 0
    read -r -p "Utente suggerito: ${NEW_ADMIN_USER:-$ORIGINAL_USER} (vuoto per saltare la configurazione tmux): " username
    [[ -n "$username" ]] || return 0
    id "$username" >/dev/null 2>&1 || { error "utente inesistente: $username"; return 1; }
    home=$(getent passwd "$username" | cut -d: -f6); group=$(id -gn "$username"); destination="$home/.tmux.conf"
    if [[ -e "$destination" ]]; then
        confirm_yes "Sovrascrivere $destination dopo il backup?" || return 0
        backup_file "$destination" "tmux-$username" >/dev/null
    fi
    atomic_install "$JACKTOOLS_DIR/assets/tmux.conf" "$destination" 0644 "$username" "$group"
}
