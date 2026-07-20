#!/usr/bin/env bash
set -Eeuo pipefail

JACKTOOLS_REF="${JACKTOOLS_REF:-main}"
JACKTOOLS_BASE_URL="${JACKTOOLS_BASE_URL:-https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/${JACKTOOLS_REF}}"
readonly TARGET_DIR="/tmp/jacktools"

die() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2329 # Richiamate indirettamente dai trap.
on_error() { printf 'ERRORE: bootstrap interrotto alla riga %s (codice %s).\n' "$2" "$1" >&2; }
# shellcheck disable=SC2329
on_signal() { printf 'Bootstrap interrotto dal segnale.\n' >&2; exit 130; }
# shellcheck disable=SC2329
on_exit() { :; }
trap 'on_error "$?" "$LINENO"' ERR
trap 'on_signal' INT TERM
trap 'on_exit' EXIT

[[ ${EUID} -eq 0 ]] || die "eseguire il bootstrap come root (sudo bash ...)."
command -v curl >/dev/null 2>&1 || die "curl non e installato."

if [[ -L "$TARGET_DIR" ]]; then
    die "$TARGET_DIR e un link simbolico; operazione rifiutata."
fi
if [[ -e "$TARGET_DIR" ]]; then
    [[ -d "$TARGET_DIR" && "$TARGET_DIR" == /tmp/jacktools ]] || die "percorso temporaneo non sicuro."
    rm -rf -- "$TARGET_DIR"
fi
install -d -o root -g root -m 0700 "$TARGET_DIR" "$TARGET_DIR/assets" "$TARGET_DIR/lib"

files=(
    jacktools.sh
    assets/header.txt assets/disclaimer.txt assets/packages.txt
    assets/bashrc_customization assets/tmux.conf
    lib/common.sh lib/hostname.sh lib/network.sh lib/ssh.sh
    lib/users.sh lib/customization.sh lib/packages.sh lib/cleanup.sh
)

for file in "${files[@]}"; do
    destination="$TARGET_DIR/$file"
    temporary="${destination}.download"
    curl -fsSL "$JACKTOOLS_BASE_URL/$file" -o "$temporary" || die "download fallito: $file"
    [[ -s "$temporary" ]] || die "file scaricato vuoto: $file"
    if [[ "$file" == *.sh ]]; then
        IFS= read -r first_line <"$temporary" || die "impossibile leggere: $file"
        [[ "$first_line" == '#!/usr/bin/env bash' ]] || die "il file non e uno script Bash valido: $file"
        bash -n "$temporary" || die "errore sintattico nel file scaricato: $file"
    fi
    mv -f -- "$temporary" "$destination"
done

chmod 0700 "$TARGET_DIR/jacktools.sh"
main_rc=0
bash "$TARGET_DIR/jacktools.sh" "$@" || main_rc=$?
exit "$main_rc"
