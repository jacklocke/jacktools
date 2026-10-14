#!/usr/bin/env bash
# Message catalog. Catalogs in messages/<lang>.sh are data: they are parsed, never sourced.
set -Eeuo pipefail

declare -gA MSG=()
JT_MSG_LANG=""

# Accepted catalog line: MSG[key]="value" (value without double quotes, $ or backticks).
MSG_LINE_RE='^MSG\[([a-z][A-Za-z0-9_.]*)\]="([^"`$]*)"$'

# msg_load LANG: 0 loaded, 1 unknown language, 2 malformed catalog (MSG left untouched).
msg_load() {
    local lang="$1" file line line_number=0 key
    local -A loaded=()
    [[ "$lang" =~ ^[a-z]{2}$ ]] || return 1
    file="$JACKTOOLS_DIR/messages/$lang.sh"
    [[ -f "$file" && -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ "$line" =~ $MSG_LINE_RE ]]; then
            loaded["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        else
            # The catalog is unusable, so this one message cannot come from it.
            printf 'JackTools: invalid line %d in %s\n' "$line_number" "$file" >&2
            return 2
        fi
    done <"$file"
    MSG=()
    for key in "${!loaded[@]}"; do MSG["$key"]="${loaded[$key]}"; done
    JT_MSG_LANG="$lang"
}

# msg_get KEY [ARGS...]: formatted text without trailing newline; unknown keys print [KEY].
msg_get() {
    local key="$1"
    shift
    if [[ -v "MSG[$key]" ]]; then
        # shellcheck disable=SC2059 # Catalog entries are printf formats by design.
        printf -- "${MSG[$key]}" "$@"
    else
        printf '[%s]' "$key"
        log_write WARN "missing message key: $key"
    fi
}

msg() {
    msg_get "$@"
    printf '\n'
}
