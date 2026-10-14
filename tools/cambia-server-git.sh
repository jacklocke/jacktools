#!/usr/bin/env bash
# cambia-server-git.sh: point JackTools to another git server.
#
# Updates the default source in bootstrap.sh (DEFAULT_REPO, DEFAULT_REF, DEFAULT_REF_TYPE,
# DEFAULT_PROVIDER) and every reference to the current server in README and docs. Raw URLs
# are computed with the bootstrap's own functions, so they always match what bootstrap.sh
# downloads. A tool for whoever publishes JackTools: it runs from a checkout and is not
# listed in MANIFEST. Like bootstrap.sh, it writes its few messages directly.
#
#   bash tools/cambia-server-git.sh [--repo URL] [--ref BRANCH | --tag TAG] [--provider P]
#                                   [--dry-run] [--yes] [--check]
set -Eeuo pipefail

CS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Never touched: CLAUDE.md (documents several servers on purpose), other projects' scripts,
# test data, previous backups.
CS_EXCLUDE_RE='^(\.git/|CLAUDE\.md$|assets/drin\.sh$|assets/tmux-login-menu\.sh$|tests/|\.cambia-server-backup-)'

# bs_* helpers and DEFAULT_*: bootstrap.sh runs nothing when sourced.
# shellcheck source=/dev/null
source "$CS_ROOT/bootstrap.sh"

CS_REPO="" CS_REF="" CS_REF_TYPE="" CS_PROVIDER="" CS_FORCED=""
CS_DRY_RUN=0 CS_YES=0 CS_CHECK=0
declare -a CS_SOURCES=() CS_FROM=() CS_TO=()

cs_die() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }
cs_say() { printf '%s\n' "$*"; }

cs_usage() {
    cat <<'EOF'
Uso: bash tools/cambia-server-git.sh [opzioni]

Aggiorna il server git di JackTools: default in bootstrap.sh e riferimenti nel README.
Senza opzioni chiede i nuovi valori.

  --repo URL      nuovo repository (GitHub, GitLab, Gitea/Forgejo), solo https
  --ref BRANCH    branch (predefinito: main)
  --tag TAG       tag al posto del branch
  --provider P    github | gitlab | gitea, se non si ricava dall'URL
  --dry-run       mostra le modifiche senza scrivere
  --yes           applica a tutti i file senza chiedere
  --check         verifica online che bootstrap.sh e MANIFEST siano raggiungibili
  -h, --help      questo aiuto
EOF
}

cs_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --repo|--ref|--tag|--provider)
                (( $# >= 2 )) || cs_die "l'opzione $1 richiede un valore."
                case "$1" in
                    --repo) CS_REPO="$2" ;;
                    --ref) CS_REF="$2"; CS_REF_TYPE=branch ;;
                    --tag) CS_REF="$2"; CS_REF_TYPE=tag ;;
                    --provider) CS_PROVIDER="$2" ;;
                esac
                shift 2
                ;;
            --dry-run) CS_DRY_RUN=1; shift ;;
            --yes) CS_YES=1; shift ;;
            --check) CS_CHECK=1; shift ;;
            -h|--help) cs_usage; exit 0 ;;
            *) cs_die "opzione sconosciuta: $1" ;;
        esac
    done
}

# cs_raw_base REPO REF TYPE PROVIDER: raw URL of the repository root, as bootstrap.sh builds it.
cs_raw_base() {
    ( BS_REPO="${1%/}"; BS_REPO="${BS_REPO%.git}"; BS_REF="$2"; BS_REF_TYPE="$3"; BS_PROVIDER="$4"; bs_base_url )
}

cs_add_source() { # REPO REF TYPE PROVIDER FORCED(0|1)
    local entry="${1%/}|$2|$3|$4|$5" existing
    entry="${entry/.git|/|}"
    for existing in "${CS_SOURCES[@]}"; do [[ "$existing" == "$entry" ]] && return 0; done
    CS_SOURCES+=("$entry")
}

# Current sources: the bootstrap defaults, plus whatever the README launch command uses.
cs_collect_sources() {
    local url provider type readme="$CS_ROOT/README.md"
    provider=${DEFAULT_PROVIDER:-$(bs_detect_provider "$DEFAULT_REPO")}
    cs_add_source "$DEFAULT_REPO" "$DEFAULT_REF" "$DEFAULT_REF_TYPE" "$provider" "$([[ -n "$DEFAULT_PROVIDER" ]] && echo 1 || echo 0)"
    [[ -f "$readme" ]] || return 0
    while IFS= read -r url; do
        if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/refs/(heads|tags)/(.+)/bootstrap\.sh$ ]]; then
            if [[ "${BASH_REMATCH[2]}" == heads ]]; then type=branch; else type=tag; fi
            cs_add_source "https://github.com/${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "$type" github 0
        elif [[ "$url" =~ ^(https://.+)/-/raw/(.+)/bootstrap\.sh$ ]]; then
            cs_add_source "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" branch gitlab \
                "$([[ "$(bs_detect_provider "${BASH_REMATCH[1]}")" == gitlab ]] && echo 0 || echo 1)"
        elif [[ "$url" =~ ^(https://.+)/raw/(branch|tag)/(.+)/bootstrap\.sh$ ]]; then
            cs_add_source "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" gitea \
                "$([[ "$(bs_detect_provider "${BASH_REMATCH[1]}")" == gitea ]] && echo 0 || echo 1)"
        fi
    done < <(grep -oE 'https://[^]<>[:space:]`"'"'"'()]+/bootstrap\.sh' "$readme" | sort -u)
    # Only complete repository URLs (host/owner/name): placeholders like <utente> stop earlier.
    while IFS= read -r url; do
        [[ "$url" =~ ^https://[^/]+(/[^/]+){2,}$ ]] || continue
        cs_add_source "$url" "$DEFAULT_REF" "$DEFAULT_REF_TYPE" "$(bs_detect_provider "$url")" 0
    done < <(grep -oE -- '--repo https://[^]<>[:space:]`"'"'"'()]+' "$readme" | sed 's/^--repo //' | sort -u)
}

cs_ask() { # RESULT_VAR PROMPT DEFAULT
    local -n cs_ask_result="$1"
    local cs_ask_answer
    IFS= read -r -p "$2 [$3]: " cs_ask_answer || cs_die "input interrotto."
    cs_ask_result="${cs_ask_answer:-$3}"
}

# New source: from the options, otherwise asked; validated with the bootstrap rules.
cs_collect_new() {
    local kind detected
    if [[ -z "$CS_REPO" ]]; then
        cs_say "Sorgente attuale: $DEFAULT_REPO ($DEFAULT_REF_TYPE $DEFAULT_REF)"
        cs_ask CS_REPO "Nuovo repository (https://…)" "$DEFAULT_REPO"
        cs_ask kind "Branch (b) o tag (t)?" "$([[ "$DEFAULT_REF_TYPE" == tag ]] && echo t || echo b)"
        case "$kind" in t|T) CS_REF_TYPE=tag ;; *) CS_REF_TYPE=branch ;; esac
        cs_ask CS_REF "Nome del $CS_REF_TYPE" "$DEFAULT_REF"
    fi
    CS_REPO="${CS_REPO%/}"; CS_REPO="${CS_REPO%.git}"
    CS_REF="${CS_REF:-main}"; CS_REF_TYPE="${CS_REF_TYPE:-branch}"
    BS_ALLOW_HTTP=0
    bs_valid_url "$CS_REPO" || cs_die "URL del repository non valido o non https: $CS_REPO"
    bs_valid_ref "$CS_REF" || cs_die "branch o tag non valido: $CS_REF"
    detected=$(bs_detect_provider "$CS_REPO")
    if [[ -z "$CS_PROVIDER" && "$detected" == gitea && -t 0 ]]; then
        # Self-hosted host names do not tell Gitea/Forgejo from GitLab.
        cs_ask kind "Server Gitea/Forgejo (g) o GitLab (l)?" g
        case "$kind" in l|L) CS_PROVIDER=gitlab ;; *) CS_PROVIDER=gitea ;; esac
    fi
    CS_PROVIDER="${CS_PROVIDER:-$detected}"
    case "$CS_PROVIDER" in github|gitlab|gitea) ;; *) cs_die "provider sconosciuto: $CS_PROVIDER (github, gitlab o gitea)" ;; esac
    if [[ "$CS_PROVIDER" == "$detected" ]]; then CS_FORCED=0; else CS_FORCED=1; fi
    cs_raw_base "$CS_REPO" "$CS_REF" "$CS_REF_TYPE" "$CS_PROVIDER" >/dev/null || cs_die "repository non adatto al provider $CS_PROVIDER: $CS_REPO"
}

# Literal replacement pairs, longest first: raw base, "--repo URL [--provider P]", plain URL.
cs_build_pairs() {
    local source repo ref type provider forced new_raw new_repo_arg line
    local -a pairs=()
    new_raw=$(cs_raw_base "$CS_REPO" "$CS_REF" "$CS_REF_TYPE" "$CS_PROVIDER")
    new_repo_arg="--repo $CS_REPO"
    (( CS_FORCED )) && new_repo_arg+=" --provider $CS_PROVIDER"
    for source in "${CS_SOURCES[@]}"; do
        IFS='|' read -r repo ref type provider forced <<<"$source"
        pairs+=("$(cs_raw_base "$repo" "$ref" "$type" "$provider")"$'\t'"$new_raw")
        (( forced )) && pairs+=("--repo $repo --provider $provider"$'\t'"$new_repo_arg")
        pairs+=("--repo $repo"$'\t'"$new_repo_arg")
        pairs+=("$repo"$'\t'"$CS_REPO")
    done
    CS_FROM=(); CS_TO=()
    while IFS=$'\t' read -r source line; do
        [[ -n "$source" && "$source" != "$line" ]] || continue
        CS_FROM+=("$source"); CS_TO+=("$line")
    done < <(printf '%s\n' "${pairs[@]}" | awk -F'\t' '!seen[$1]++ { print length($1) "\t" $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)
}

# cs_transform FILE OUTPUT: one pass, earliest match first (longest on ties); a match counts
# only when it is a whole URL (not followed by a name character, not preceded by a path one).
cs_transform() {
    local pairs
    if (( ${#CS_FROM[@]} == 0 )); then cp -- "$1" "$2"; return 0; fi
    pairs=$(mktemp)
    paste <(printf '%s\n' "${CS_FROM[@]}") <(printf '%s\n' "${CS_TO[@]}") >"$pairs"
    awk -v pairs="$pairs" '
        BEGIN { while ((getline l < pairs) > 0) { split(l, a, "\t"); if (a[1] == "") continue; n++; f[n] = a[1]; t[n] = a[2] } }
        function repl(s,   out, best, bi, i, p, len, prev, nx) {
            out = ""
            while (1) {
                best = 0; bi = 0
                for (i = 1; i <= n; i++) {
                    p = index(s, f[i])
                    if (p > 0 && (best == 0 || p < best || (p == best && length(f[i]) > length(f[bi])))) { best = p; bi = i }
                }
                if (!best) return out s
                len = length(f[bi])
                prev = best > 1 ? substr(s, best - 1, 1) : substr(out, length(out), 1)
                nx = substr(s, best + len, 1)
                if (prev ~ /[A-Za-z0-9_.\/-]/ || nx ~ /[A-Za-z0-9_-]/) {
                    out = out substr(s, 1, best); s = substr(s, best + 1); continue
                }
                out = out substr(s, 1, best - 1) t[bi]; s = substr(s, best + len)
            }
        }
        { print repl($0) }
    ' "$1" >"$2"
    rm -f -- "$pairs"
    # awk always ends with a newline: keep files that had none byte-identical.
    if [[ -s "$1" && -s "$2" && $(tail -c1 -- "$1" | wc -l) -eq 0 ]]; then truncate -s -1 -- "$2"; fi
}

# The DEFAULT_* assignments of bootstrap.sh are rewritten explicitly.
cs_set_defaults() {
    local provider_value=''
    (( CS_FORCED )) && provider_value="$CS_PROVIDER"
    awk -v repo="$CS_REPO" -v ref="$CS_REF" -v type="$CS_REF_TYPE" -v prov="$provider_value" '
        /^DEFAULT_REPO=/ { sub(/^DEFAULT_REPO="[^"]*"/, "DEFAULT_REPO=\"" repo "\"") }
        /^DEFAULT_REF=/ { sub(/^DEFAULT_REF="[^"]*"/, "DEFAULT_REF=\"" ref "\"") }
        /^DEFAULT_REF_TYPE=/ { sub(/^DEFAULT_REF_TYPE="[^"]*"/, "DEFAULT_REF_TYPE=\"" type "\"") }
        /^DEFAULT_PROVIDER=/ { sub(/^DEFAULT_PROVIDER="[^"]*"/, "DEFAULT_PROVIDER=\"" prov "\"") }
        { print }
    ' "$1" >"$2"
}

cs_files() {
    local rel
    while IFS= read -r rel; do
        rel=${rel#./}
        [[ "$rel" =~ $CS_EXCLUDE_RE ]] && continue
        grep -Iq . "$CS_ROOT/$rel" 2>/dev/null && printf '%s\n' "$rel"
    done < <(cd "$CS_ROOT" && find . -type f | sort)
}

cs_confirm() {
    local answer
    (( CS_YES )) && return 0
    IFS= read -r -p "$1 [s/N]: " answer || return 1
    [[ "$answer" == [sSyY] ]]
}

cs_apply() {
    local rel file candidate step backup_dir='' changed=0
    local -a files
    candidate=$(mktemp); step=$(mktemp)
    # The list is read first: inside the loop stdin must stay the operator's, for the questions.
    mapfile -t files < <(cs_files)
    for rel in "${files[@]}"; do
        file="$CS_ROOT/$rel"
        cs_transform "$file" "$candidate"
        if [[ "$rel" == bootstrap.sh ]]; then cs_set_defaults "$candidate" "$step"; cp -- "$step" "$candidate"; fi
        cmp -s "$file" "$candidate" && continue
        changed=1
        printf '\n== %s ==\n' "$rel"
        diff -U0 "$file" "$candidate" | grep -E '^[-+][^-+]' || true
        (( CS_DRY_RUN )) && continue
        cs_confirm "Applicare a $rel?" || { cs_say "  saltato."; continue; }
        if [[ -z "$backup_dir" ]]; then backup_dir="$CS_ROOT/.cambia-server-backup-$(date '+%Y%m%d-%H%M%S')"; fi
        mkdir -p -- "$backup_dir/$(dirname -- "$rel")"
        cp -p -- "$file" "$backup_dir/$rel"
        cat -- "$candidate" >"$file"
        cs_say "  aggiornato."
    done
    rm -f -- "$candidate" "$step"
    if (( ! changed )); then cs_say "Nessuna modifica necessaria: il progetto punta già a questo server."; return 0; fi
    (( CS_DRY_RUN )) && { cs_say $'\nDry-run: nessun file modificato.'; return 0; }
    [[ -z "$backup_dir" ]] || cs_say "Copie dei file originali in: ${backup_dir#"$CS_ROOT"/}"
}

cs_report() {
    local raw command
    bash -n "$CS_ROOT/bootstrap.sh" || cs_die "bootstrap.sh non è più valido: ripristinare dal backup."
    raw=$(cs_raw_base "$CS_REPO" "$CS_REF" "$CS_REF_TYPE" "$CS_PROVIDER")
    command="curl -fsSL $raw/bootstrap.sh -o /tmp/jacktools-bootstrap.sh && sudo bash /tmp/jacktools-bootstrap.sh --repo $CS_REPO"
    (( CS_FORCED )) && command+=" --provider $CS_PROVIDER"
    printf '\nComando di avvio:\n  %s\n' "$command"
    if (( CS_CHECK )); then
        local path
        for path in bootstrap.sh MANIFEST; do
            if curl -fsSL --proto '=https' --max-time 20 -o /dev/null "$raw/$path"; then cs_say "raggiungibile: $raw/$path"
            else cs_say "NON raggiungibile: $raw/$path (file pubblicati? repository privato?)"; fi
        done
    else
        cs_say "Ricordarsi di pubblicare i file sul nuovo server (--check per verificarlo)."
    fi
}

cs_main() {
    cs_parse_args "$@"
    cs_collect_sources
    cs_collect_new
    cs_build_pairs
    cs_say "Nuova sorgente: $CS_PROVIDER $CS_REPO ($CS_REF_TYPE $CS_REF)"
    cs_apply
    cs_report
}

cs_main "$@"
