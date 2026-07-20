#!/usr/bin/env bash
set -Eeuo pipefail

: "${JACKTOOLS_TEST_MODE:=0}"
: "${JACKTOOLS_ROOT:=}"
: "${JACKTOOLS_LOG:=/var/log/jacktools.log}"
: "${JACKTOOLS_BACKUP_ROOT:=/var/backups/jacktools}"
: "${JACKTOOLS_DIR:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
: "${ORIGINAL_USER:=${SUDO_USER:-root}}"
: "${NEW_ADMIN_USER:=}"
: "${NETWORK_RESTORED:=0}"
: "${REBOOT_RECOMMENDED:=0}"
: "${NEW_SHELL_REQUIRED:=0}"
: "${DISCLAIMER_ACCEPTED:=0}"
declare -gA JT_STATUS=()

if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'
    BLINK=$'\033[5m'; REVERSE=$'\033[7m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; BLINK=''; REVERSE=''; RESET=''
fi
# shellcheck disable=SC2034 # REVERSE viene usata dal modulo packages.sh dopo il source.
readonly RED GREEN YELLOW BOLD BLINK REVERSE RESET

root_path() { printf '%s%s' "$JACKTOOLS_ROOT" "$1"; }
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
    local level="$1" message="$2" line
    line="$(timestamp) [$level] $message"
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        printf '%s\n' "$line" >>"${JACKTOOLS_TEST_LOG:-/dev/null}"
    else
        if ! { printf '%s\n' "$line" >>"$JACKTOOLS_LOG"; } 2>/dev/null; then :; fi
    fi
}
info() { printf '%sINFO%s: %s\n' "$GREEN" "$RESET" "$*"; log INFO "$*"; }
warn() { printf '%sAVVISO%s: %s\n' "$YELLOW" "$RESET" "$*" >&2; log WARN "$*"; }
error() { printf '%sERRORE%s: %s\n' "$RED" "$RESET" "$*" >&2; log ERROR "$*"; }
die() { error "$*"; exit 1; }
set_status() { JT_STATUS["$1"]="$2"; log INFO "$1: $2"; }

on_error() {
    local rc="$1" line="$2"
    error "errore inatteso alla riga $line (codice $rc)."
}
on_signal() { warn "operazione interrotta; nessuna fase successiva verra eseguita."; exit 130; }
on_exit() { local rc="$1"; log INFO "termine JackTools con codice $rc"; }
install_traps() {
    trap 'on_error "$?" "$LINENO"' ERR
    trap 'on_signal' INT TERM
    trap 'on_exit "$?"' EXIT
}

print_header() {
    local header="$JACKTOOLS_DIR/assets/header.txt"
    if [[ -r "$header" ]]; then
        printf '%s' "$BOLD"; while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done <"$header"; printf '%s' "$RESET"
    else
        warn "header non disponibile: $header"
        printf '=== JackTools ===\n'
    fi
}

require_disclaimer() {
    local answer
    (( DISCLAIMER_ACCEPTED )) && return 0
    print_header
    printf '%s%s%sATTENZIONE%s\n' "$RED" "$BOLD" "$BLINK" "$RESET"
    [[ -r "$JACKTOOLS_DIR/assets/disclaimer.txt" ]] || { error "disclaimer non disponibile."; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done <"$JACKTOOLS_DIR/assets/disclaimer.txt"
    IFS= read -r -p "Premere SPAZIO e poi INVIO per continuare (vuoto per uscire): " answer || return 1
    [[ "$answer" == ' ' ]] || { warn "conferma non fornita; nessuna modifica eseguita."; return 1; }
    DISCLAIMER_ACCEPTED=1
}

confirm_exact() {
    local prompt="$1" expected="$2" answer
    read -r -p "$prompt [$expected] (vuoto per annullare): " answer || return 1
    [[ "$answer" == "$expected" ]]
}
confirm_yes() {
    local prompt="$1" answer
    while true; do
        IFS= read -r -p "$prompt [Y/N] (vuoto per annullare): " answer || return 1
        case "$answer" in
            Y|y) return 0 ;;
            N|n|'') return 1 ;;
            *) warn "risposta non valida: digitare solamente Y/y oppure N/n." ;;
        esac
    done
}

print_section_separator() {
    printf '\n%s%s%s\n\n' "$YELLOW" '------------------------------------------------------------' "$RESET"
}

is_ssh_session() { [[ -n ${SSH_CONNECTION:-} || -n ${SSH_CLIENT:-} || -n ${SSH_TTY:-} ]]; }
current_session_user() { printf '%s' "${SUDO_USER:-${USER:-root}}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
run_cmd() {
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        { printf 'MOCK:'; printf ' %q' "$@"; printf '\n'; } >>"${JACKTOOLS_COMMAND_LOG:-/dev/null}"
        return 0
    fi
    "$@"
}

preflight_for() {
    local feature="$1" available_kb
    [[ "$JACKTOOLS_TEST_MODE" == 1 || ${EUID} -eq 0 ]] || die "JackTools deve essere eseguito come root."
    if [[ "$JACKTOOLS_TEST_MODE" != 1 ]]; then
        [[ -r /etc/os-release ]] || die "/etc/os-release non disponibile."
        # shellcheck disable=SC1091
        source /etc/os-release
        [[ ${ID:-} == ubuntu ]] || die "sistema non supportato: e richiesto Ubuntu Server."
        command_exists bash && command_exists apt-get && [[ -d /run/systemd/system ]] || die "Bash, APT o systemd non disponibili."
        install -d -o root -g root -m 0750 "$JACKTOOLS_BACKUP_ROOT"
        touch "$JACKTOOLS_LOG" && chmod 0600 "$JACKTOOLS_LOG"
        available_kb=$(df -Pk / | awk 'NR==2 {print $4}')
        (( available_kb >= 102400 )) || die "spazio insufficiente: servono almeno 100 MiB liberi."
    fi
    case "$feature" in
        network|all)
            command_exists netplan || die "Netplan non disponibile."
            command_exists ip || die "il comando ip non e disponibile."
            command_exists ping || die "il comando ping non e disponibile."
            ;;
    esac
    case "$feature" in
        admin-user|remove-ubuntu-user|all)
            find_sshd_binary >/dev/null || die "OpenSSH server non disponibile."
            ;;
    esac
    case "$feature" in
        admin-user|remove-ubuntu-user|all)
            command_exists visudo || die "visudo non disponibile."
            command_exists passwd || die "passwd non disponibile."
            ;;
    esac
    case "$feature" in
        admin-user|all)
            if ! command_exists useradd || ! command_exists usermod || ! command_exists chpasswd; then
                die "comandi di gestione utenti non disponibili."
            fi
            if [[ "$feature" == all ]] && ! command_exists userdel; then die "userdel non disponibile."; fi
            ;;
        remove-ubuntu-user)
            command_exists userdel || die "userdel non disponibile."
            ;;
    esac
    if is_ssh_session; then
        warn "sessione SSH rilevata: le modifiche a rete e accesso possono disconnettere la sessione."
    fi
    return 0
}

backup_file() {
    local source="$1" label="$2" stamp destination
    [[ -e "$source" ]] || return 0
    stamp=$(date '+%Y%m%d-%H%M%S-%N')
    destination="$JACKTOOLS_BACKUP_ROOT/$label-$stamp"
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -a -- "$source" "$destination"; else run_cmd cp -a -- "$source" "$destination"; fi
    printf '%s' "$destination"
}

atomic_install() {
    local candidate="$1" destination="$2" mode="$3" owner="${4:-root}" group="${5:-root}"
    local directory temporary
    directory=$(dirname -- "$destination")
    temporary=$(mktemp "$directory/.jacktools.XXXXXX")
    cp -- "$candidate" "$temporary"
    chmod "$mode" "$temporary"
    chown "$owner:$group" "$temporary"
    mv -f -- "$temporary" "$destination"
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_hostname() {
    local value="$1" label
    (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
    [[ "$value" != *.* && "$value" != *'/'* && "$value" != *[[:space:]]* ]] || return 1
    IFS=. read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        (( ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}
valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do [[ "$octet" =~ ^0$|^[1-9][0-9]{0,2}$ ]] && (( 10#$octet <= 255 )) || return 1; done
}
valid_cidr() {
    local value="$1" ip prefix
    [[ "$value" == */* ]] || return 1
    ip=${value%/*}; prefix=${value##*/}
    valid_ipv4 "$ip" && [[ "$prefix" =~ ^[0-9]+$ ]] && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}
valid_dns_list() {
    local input="$1" item
    IFS=, read -r -a items <<<"$input"
    (( ${#items[@]} > 0 )) || return 1
    for item in "${items[@]}"; do item=${item//[[:space:]]/}; valid_ipv4 "$item" || return 1; done
}
valid_search_domains() {
    local input="$1" domain label
    [[ -z "$input" ]] && return 0
    IFS=, read -r -a domains <<<"$input"
    for domain in "${domains[@]}"; do
        domain=${domain//[[:space:]]/}; [[ "$domain" != -* && "$domain" != *- && "$domain" == *.* ]] || return 1
        IFS=. read -r -a labels <<<"$domain"
        for label in "${labels[@]}"; do [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1; done
    done
}

print_summary() {
    local key status failed=0
    printf '\n%-34s %s\n' FASE STATO
    printf '%-34s %s\n' '----------------------------------' '----------------'
    for key in "${!JT_STATUS[@]}"; do
        status=${JT_STATUS[$key]}
        printf '%-34s %s\n' "$key" "$status"
        [[ "$status" == FALLITO ]] && failed=1
    done
    printf '\nLog: %s\nBackup: %s\n' "$JACKTOOLS_LOG" "$JACKTOOLS_BACKUP_ROOT"
    (( REBOOT_RECOMMENDED )) && printf 'Riavvio consigliato.\n'
    (( NEW_SHELL_REQUIRED )) && printf 'Aprire una nuova shell per rendere effettive tutte le modifiche.\n'
    (( NETWORK_RESTORED )) && printf 'La configurazione di rete precedente e stata ripristinata.\n'
    return "$failed"
}
