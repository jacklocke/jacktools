#!/usr/bin/env bash
set -Eeuo pipefail

plausible_public_key() {
    local key="$1" type payload rest
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || return 1
    [[ "$key" != *'PRIVATE KEY'* && "$key" != *$'\t'* ]] || return 1
    read -r type payload rest <<<"$key"
    case "$type" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;; *) return 1 ;; esac
    [[ "$payload" =~ ^[A-Za-z0-9+/]+={0,3}$ && ${#payload} -ge 20 ]]
}

append_authorized_key_once() {
    local file="$1" key="$2"
    touch "$file"
    grep -Fqx -- "$key" "$file" || printf '%s\n' "$key" >>"$file"
}

validate_admin_account() {
    local username="$1" home
    id "$username" >/dev/null 2>&1 || return 1
    id -nG "$username" | tr ' ' '\n' | grep -Fxq sudo || return 1
    home=$(getent passwd "$username" | cut -d: -f6)
    [[ -n "$home" ]] || return 1
    visudo -c >/dev/null 2>&1 || return 1
    if [[ -e "$(root_path "/etc/sudoers.d/90-jacktools-$username")" ]]; then
        visudo -cf "$(root_path "/etc/sudoers.d/90-jacktools-$username")" >/dev/null || return 1
    fi
    if [[ -e "$home/.ssh/authorized_keys" ]]; then
        [[ $(stat -c %a "$home/.ssh") == 700 && $(stat -c %a "$home/.ssh/authorized_keys") == 600 ]] || return 1
    fi
    find_sshd_binary >/dev/null && "$(find_sshd_binary)" -t >/dev/null
}

create_admin_user() {
    local username fullname shell password='' public_key='' sudo_mode home group sudo_file candidate
    read -r -p "Nome del nuovo amministratore (vuoto per annullare): " username
    [[ -n "$username" ]] || { set_status 'Utente amministrativo' ANNULLATO; return 0; }
    valid_username "$username" || { error "nome utente non valido."; set_status 'Utente amministrativo' FALLITO; return 1; }
    read -r -p "Nome descrittivo (opzionale, vuoto per non impostarlo): " fullname
    read -r -p "Shell [/bin/bash] (vuoto per usare il valore predefinito): " shell; shell=${shell:-/bin/bash}
    [[ "$shell" == /bin/bash && -x "$shell" ]] || { error "per questa versione e consentita /bin/bash."; set_status 'Utente amministrativo' FALLITO; return 1; }
    read -r -s -p "Password (vuota per non impostarla): " password; printf '\n'
    read -r -p "Chiave pubblica SSH, una riga (opzionale, vuoto per non impostarla): " public_key
    [[ -z "$public_key" ]] || plausible_public_key "$public_key" || { error "chiave pubblica OpenSSH non valida."; set_status 'Utente amministrativo' FALLITO; return 1; }
    printf '1. sudo con password (predefinito)\n2. sudo senza password\n'; read -r -p "Modalita sudo (vuoto per annullare): " sudo_mode
    [[ -n "$sudo_mode" ]] || { set_status 'Utente amministrativo' ANNULLATO; return 0; }
    [[ "$sudo_mode" =~ ^[12]$ ]] || { set_status 'Utente amministrativo' ANNULLATO; return 0; }
    printf 'Utente: %s; shell: %s; password: %s; chiave: %s; sudo passwordless: %s\n' "$username" "$shell" "$([[ -n "$password" ]] && printf impostata || printf no)" "$([[ -n "$public_key" ]] && printf presente || printf no)" "$([[ "$sudo_mode" == 2 ]] && printf SI || printf NO)"
    confirm_yes "Creare o aggiornare questo amministratore?" || { set_status 'Utente amministrativo' ANNULLATO; return 0; }

    if ! id "$username" >/dev/null 2>&1; then
        run_cmd useradd --create-home --shell "$shell" --comment "$fullname" --groups sudo "$username" || { set_status 'Utente amministrativo' FALLITO; return 1; }
    else
        run_cmd usermod --append --groups sudo --shell "$shell" "$username"
    fi
    if [[ -n "$password" ]]; then
        if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
            log INFO "password account simulata in modalita test"
        else
            printf '%s:%s\n' "$username" "$password" | chpasswd
        fi
        password=''
    fi
    home=$(getent passwd "$username" | cut -d: -f6); group=$(id -gn "$username")
    if [[ -n "$public_key" ]]; then
        install -d -o "$username" -g "$group" -m 0700 "$home/.ssh"
        append_authorized_key_once "$home/.ssh/authorized_keys" "$public_key"
        chown "$username:$group" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"
    fi
    sudo_file=$(root_path "/etc/sudoers.d/90-jacktools-$username")
    if [[ "$sudo_mode" == 2 ]]; then
        candidate=$(mktemp); printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" >"$candidate"; chmod 0440 "$candidate"
        visudo -cf "$candidate" >/dev/null || { rm -f -- "$candidate"; set_status 'Utente amministrativo' FALLITO; return 1; }
        [[ -e "$sudo_file" ]] && backup_file "$sudo_file" "sudoers-$username" >/dev/null
        if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -- "$candidate" "$sudo_file"; else atomic_install "$candidate" "$sudo_file" 0440; fi
        rm -f -- "$candidate"
    elif [[ -e "$sudo_file" ]]; then
        backup_file "$sudo_file" "sudoers-$username" >/dev/null; rm -f -- "$sudo_file"
    fi
    if effective_ssh_policies | grep -q '^allowusers '; then ensure_user_in_managed_allowlist "$username" || { set_status 'Utente amministrativo' FALLITO; return 1; }; fi
    ssh_user_permitted "$username" || { error "l'amministratore risulta escluso dalla politica SSH effettiva."; set_status 'Utente amministrativo' FALLITO; return 1; }
    validate_admin_account "$username" || { error "verifica finale dell'amministratore fallita."; set_status 'Utente amministrativo' FALLITO; return 1; }
    NEW_ADMIN_USER="$username"; set_status 'Utente amministrativo' OK
}

admin_has_authentication() {
    local username="$1" home shadow_state
    home=$(getent passwd "$username" | cut -d: -f6)
    [[ -s "$home/.ssh/authorized_keys" ]] && return 0
    shadow_state=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
    [[ "$shadow_state" == P ]]
}

find_safe_admin() {
    local candidate
    [[ -n ${NEW_ADMIN_USER:-} ]] && candidate=$NEW_ADMIN_USER
    if [[ -z ${candidate:-} ]]; then
        while IFS=: read -r candidate _; do
            [[ "$candidate" == ubuntu ]] && continue
            id -nG "$candidate" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo && { printf '%s' "$candidate"; return 0; }
        done < <(getent passwd)
    fi
    return 1
}

ssh_user_permitted() {
    local username="$1" policies allow deny allow_groups deny_groups group
    policies=$(effective_ssh_policies)
    allow=$(awk '/^allowusers /{$1=""; sub(/^ /,""); print}' <<<"$policies")
    deny=$(awk '/^denyusers /{$1=""; sub(/^ /,""); print}' <<<"$policies")
    if [[ -n "$allow" ]]; then
        ssh_value_matches_patterns "$username" "$(xargs -n1 <<<"$allow" | sed 's/@.*$//' | xargs)" || return 1
    fi
    if [[ -n "$deny" ]] && ssh_value_matches_patterns "$username" "$(xargs -n1 <<<"$deny" | sed 's/@.*$//' | xargs)"; then return 1; fi
    allow_groups=$(awk '/^allowgroups /{$1=""; sub(/^ /,""); print}' <<<"$policies")
    deny_groups=$(awk '/^denygroups /{$1=""; sub(/^ /,""); print}' <<<"$policies")
    if [[ -n "$allow_groups" ]]; then
        local allowed=1
        for group in $(id -nG "$username"); do ssh_value_matches_patterns "$group" "$allow_groups" && allowed=0; done
        (( allowed == 0 )) || return 1
    fi
    if [[ -n "$deny_groups" ]]; then
        for group in $(id -nG "$username"); do ssh_value_matches_patterns "$group" "$deny_groups" && return 1; done
    fi
    return 0
}

ssh_value_matches_patterns() {
    local value="$1" patterns="$2" pattern
    for pattern in $patterns; do
        # shellcheck disable=SC2053 # I pattern OpenSSH devono mantenere i wildcard.
        [[ "$value" == $pattern ]] && return 0
    done
    return 1
}

can_remove_ubuntu() {
    local admin
    id ubuntu >/dev/null 2>&1 || return 2
    [[ $(current_session_user) != ubuntu && ${USER:-} != ubuntu ]] || return 1
    admin=$(find_safe_admin) || return 1
    validate_admin_account "$admin" && admin_has_authentication "$admin" && ssh_user_permitted "$admin" || return 1
}

is_removal_session_safe() {
    local target="$1" session_user="$2" login_user="$3"
    [[ "$target" != "$session_user" && "$target" != "$login_user" ]]
}

remove_ubuntu_user() {
    local remove_home remove_mail external_count
    if ! id ubuntu >/dev/null 2>&1; then info "utente ubuntu non presente."; set_status 'Eliminazione utente ubuntu' SALTATO; return 0; fi
    if ! is_removal_session_safe ubuntu "$(current_session_user)" "${USER:-}"; then
        error "ubuntu e l'utente della sessione corrente; accedere prima con il nuovo amministratore."
        set_status 'Eliminazione utente ubuntu' FALLITO; return 1
    fi
    can_remove_ubuntu || { error "manca un altro amministratore verificato con autenticazione valida."; set_status 'Eliminazione utente ubuntu' FALLITO; return 1; }
    printf '%sLa rimozione dell account ubuntu puo causare perdita di accesso.%s\n' "$RED" "$RESET"
    confirm_exact "Per continuare digitare esattamente" 'ELIMINA ubuntu' || { set_status 'Eliminazione utente ubuntu' ANNULLATO; return 0; }
    confirm_yes "Eliminare anche la home directory?" && remove_home=1 || remove_home=0
    confirm_yes "Eliminare anche il mail spool?" && remove_mail=1 || remove_mail=0
    external_count=$(find / -xdev -user ubuntu -not -path '/home/ubuntu/*' -not -path /home/ubuntu 2>/dev/null | wc -l || true)
    (( external_count > 0 )) && warn "rilevati $external_count percorsi posseduti da ubuntu fuori dalla home; non verranno eliminati."
    if (( remove_home )); then run_cmd userdel --remove ubuntu; else run_cmd userdel ubuntu; fi
    (( remove_mail )) && [[ -e /var/mail/ubuntu ]] && rm -f -- /var/mail/ubuntu
    id ubuntu >/dev/null 2>&1 && { set_status 'Eliminazione utente ubuntu' FALLITO; return 1; }
    set_status 'Eliminazione utente ubuntu' OK
}
