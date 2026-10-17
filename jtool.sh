#!/usr/bin/env bash
# jtool.sh - short launcher: downloads bootstrap.sh and runs it, keeping the terminal as input.
#   curl -fsSL https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/jtool.sh | sudo bash
#   ... | sudo bash -s -- [bootstrap options] [-- command and options of jacktools.sh]
# Everything runs from the last line: a download cut halfway executes nothing.
# Like bootstrap.sh, it writes its few messages directly (Italian).
set -Eeuo pipefail

JTOOL_BOOTSTRAP_URL="https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/bootstrap.sh"

jtool_die() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }

jtool_main() {
    local target=/tmp/jacktools-bootstrap.sh tmp
    if [[ "${JACKTOOLS_TEST_MODE:-0}" == 1 ]]; then
        target="${JTOOL_TARGET:-$target}"
    elif [[ ${EUID} -ne 0 ]]; then
        jtool_die "eseguire come root: curl -fsSL <URL di jtool.sh> | sudo bash"
    fi
    command -v curl >/dev/null 2>&1 || jtool_die "curl non è installato."
    tmp=$(mktemp "${target}.XXXXXX") || jtool_die "impossibile creare un file temporaneo."
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 120 \
            -o "$tmp" "$JTOOL_BOOTSTRAP_URL"; then
        rm -f -- "$tmp"; jtool_die "download fallito: $JTOOL_BOOTSTRAP_URL"
    fi
    bash -n "$tmp" 2>/dev/null || { rm -f -- "$tmp"; jtool_die "bootstrap.sh scaricato non valido: $JTOOL_BOOTSTRAP_URL"; }
    chmod 0700 "$tmp"
    # rename, never write through: an existing link at the target path is replaced, not followed
    mv -fT -- "$tmp" "$target"
    # Piped into bash, stdin is the script itself: the menu reads from the terminal instead.
    if { : </dev/tty; } 2>/dev/null; then
        exec bash "$target" "$@" </dev/tty
    fi
    exec bash "$target" "$@"
}

jtool_main "$@"
