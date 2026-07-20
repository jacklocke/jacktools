#!/usr/bin/env bash
set -Eeuo pipefail

declare -ga PACKAGE_NAMES=()
declare -ga PACKAGE_DEFAULTS=()

valid_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; }

parse_packages_file() {
    local file="$1" line name flag extra line_number=0
    PACKAGE_NAMES=(); PACKAGE_DEFAULTS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number+=1)); line=${line%%#*}; [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        read -r name flag extra <<<"$line"
        valid_package_name "$name" || { error "nome pacchetto non valido alla riga $line_number."; return 1; }
        [[ -z ${extra:-} ]] || { error "troppi campi alla riga $line_number."; return 1; }
        [[ -z ${flag:-} || "$flag" == default ]] || { error "flag sconosciuto alla riga $line_number."; return 1; }
        PACKAGE_NAMES+=("$name"); [[ "$flag" == default ]] && PACKAGE_DEFAULTS+=(1) || PACKAGE_DEFAULTS+=(0)
    done <"$file"
}

numeric_checklist() {
    local -n labels_ref="$1"
    local -n selected_ref="$2"
    local i input token
    printf 'Checklist (fallback numerico):\n'
    for i in "${!labels_ref[@]}"; do printf '%2d. [%s] %s\n' "$((i+1))" "$([[ ${selected_ref[$i]} == 1 ]] && printf x || printf ' ')" "${labels_ref[$i]}"; done
    read -r -p "Numeri da attivare/disattivare separati da spazi, Invio per confermare, q per annullare: " input
    [[ "$input" != q ]] || return 1
    for token in $input; do [[ "$token" =~ ^[0-9]+$ ]] && ((token>=1 && token<=${#labels_ref[@]})) || return 2; i=$((token-1)); selected_ref[i]=$((1-selected_ref[i])); done
}

interactive_checklist() {
    local -n labels_ref="$1"
    # shellcheck disable=SC2178 # Nameref a un array definito dal chiamante.
    local -n selected_ref="$2"
    local current=0 key rest i count=${#labels_ref[@]}
    while true; do
        printf '\033[H\033[2JUsare frecce, spazio, Invio; q/Esc annulla.\n'
        for i in "${!labels_ref[@]}"; do
            ((i==current)) && printf '%s' "$REVERSE"
            printf '[%s] %s%s\n' "$([[ ${selected_ref[$i]} == 1 ]] && printf x || printf ' ')" "${labels_ref[$i]}" "$RESET"
        done
        IFS= read -rsn1 key || return 1
        case "$key" in
            '') return 0 ;;
            ' ') selected_ref[current]=$((1-selected_ref[current])) ;;
            q) return 1 ;;
            $'\e')
                if IFS= read -rsn2 -t 0.15 rest; then case "$rest" in '[A') current=$(((current-1+count)%count)) ;; '[B') current=$(((current+1)%count)) ;; esac; else return 1; fi
                ;;
        esac
    done
}

apt_locked() {
    command -v fuser >/dev/null 2>&1 || return 1
    fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1
}

refresh_apt_indexes() {
    run_cmd apt-get update
}

install_apt_package() {
    local package="$1"
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq 'install ok installed'; then set_status "$package" OK; info "$package gia installato."; return 0; fi
    if DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y -- "$package"; then set_status "$package" OK; else set_status "$package" FALLITO; return 1; fi
}

install_package_dispatch() {
    local package="$1"
    case "$package" in
        docker) install_docker ;;
        tmux) install_apt_package tmux && install_tmux_configuration ;;
        *) install_apt_package "$package" ;;
    esac
}

current_os_label() {
    local name='Ubuntu' version='' pretty='' suffix=''
    if [[ -r /etc/os-release ]]; then
        name=$(awk -F= '$1 == "NAME" {value=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release)
        version=$(awk -F= '$1 == "VERSION_ID" {value=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release)
        pretty=$(awk -F= '$1 == "PRETTY_NAME" {value=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release)
    fi
    [[ "$pretty" == *LTS* ]] && suffix=' LTS'
    if [[ -n "$version" ]]; then printf '%s %s%s' "${name:-Ubuntu}" "$version" "$suffix"; else printf '%s' "${pretty:-Ubuntu}"; fi
}

manage_packages() {
    local os_label i package rc=0
    os_label=$(current_os_label)
    local -a labels=("Aggiornamento generale del sistema ($os_label)") selected=(1)
    parse_packages_file "$JACKTOOLS_DIR/assets/packages.txt" || { set_status 'Pacchetti' FALLITO; return 1; }
    labels+=("${PACKAGE_NAMES[@]}"); selected+=("${PACKAGE_DEFAULTS[@]}")
    if [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]]; then interactive_checklist labels selected || { set_status 'Pacchetti' ANNULLATO; return 0; }
    else numeric_checklist labels selected || { set_status 'Pacchetti' ANNULLATO; return 0; }; fi
    printf 'Selezione:\n'; for i in "${!labels[@]}"; do [[ ${selected[$i]} == 1 ]] && printf '  - %s\n' "${labels[$i]}"; done
    confirm_yes "Procedere con APT?" || { set_status 'Pacchetti' ANNULLATO; return 0; }
    apt_locked && { error "APT/dpkg e occupato; attendere il completamento dell'altro processo."; set_status 'Pacchetti' FALLITO; return 1; }
    if refresh_apt_indexes; then
        set_status 'Aggiornamento indici APT' OK
    else
        error "apt-get update fallito: installazione e upgrade non verranno eseguiti."
        set_status 'Aggiornamento indici APT' FALLITO
        set_status 'Pacchetti' FALLITO
        return 1
    fi
    if [[ ${selected[0]} == 1 ]]; then
        if DEBIAN_FRONTEND=noninteractive run_cmd apt-get upgrade -y; then
            set_status 'Aggiornamento sistema' OK
            # shellcheck disable=SC2034 # Letta da print_summary nel modulo common.sh.
            REBOOT_RECOMMENDED=1
        else
            set_status 'Aggiornamento sistema' FALLITO
            rc=1
        fi
    else set_status 'Aggiornamento sistema' SALTATO; fi
    for ((i=1; i<${#labels[@]}; i++)); do
        package=${labels[$i]}
        if [[ ${selected[$i]} != 1 ]]; then set_status "$package" SALTATO; continue; fi
        if ! install_package_dispatch "$package"; then
            rc=1
            if [[ -t 0 ]]; then confirm_yes "Installazione fallita. Continuare con gli altri pacchetti?" || break; else break; fi
        fi
    done
    if (( rc )); then set_status 'Pacchetti' FALLITO; else set_status 'Pacchetti' OK; fi
    return "$rc"
}
