#!/usr/bin/env bash
# Persistent log. Callers must never pass passwords, tokens or private keys.
set -Eeuo pipefail

: "${JACKTOOLS_TEST_MODE:=0}"
: "${JACKTOOLS_LOG:=/var/log/jacktools.log}"

log_target() {
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        printf '%s' "${JACKTOOLS_TEST_LOG:-/dev/null}"
    else
        printf '%s' "$JACKTOOLS_LOG"
    fi
}

# log_write LEVEL MESSAGE: one line per event; logging failures never stop the tool.
log_write() {
    local level="$1" message="$2" line target="$JACKTOOLS_LOG"
    [[ "$JACKTOOLS_TEST_MODE" != 1 ]] || target="${JACKTOOLS_TEST_LOG:-/dev/null}"
    printf -v line '%(%Y-%m-%d %H:%M:%S)T [%s] %s' -1 "$level" "${message//$'\n'/ }"
    { printf '%s\n' "$line" >>"$target"; } 2>/dev/null || true
}

# log_init: create the real log with mode 0600 (no-op in test mode).
log_init() {
    [[ "$JACKTOOLS_TEST_MODE" == 1 ]] && return 0
    (umask 077 && touch -- "$JACKTOOLS_LOG") && chmod 0600 -- "$JACKTOOLS_LOG"
}
