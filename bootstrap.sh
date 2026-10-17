#!/usr/bin/env bash
# JackTools bootstrap: download the files listed in MANIFEST from a configurable git server
# into /tmp/jacktools, check them and start jacktools.sh.
#
# It runs before the message catalog exists, so its few messages are written here directly.
#
#   sudo bash jacktools-bootstrap.sh [--repo URL] [--ref BRANCH | --tag TAG] [--provider P]
#        [--base-url URL] [--token-file FILE] [--cacert FILE] [--allow-http] [--local DIR]
#        [-- command and options for jacktools.sh]
set -Eeuo pipefail

# The only default source. A fork changes these lines and the README, or runs
# tools/cambia-server-git.sh, which updates both.
DEFAULT_REPO="https://github.com/jacklocke/jacktools"
DEFAULT_REF="main"
DEFAULT_REF_TYPE="branch"   # branch | tag
DEFAULT_PROVIDER=""         # empty: detected from DEFAULT_REPO

TARGET_DIR="/tmp/jacktools"
# Tests may redirect the target, never in real runs.
if [[ "${JACKTOOLS_TEST_MODE:-0}" == 1 && -n "${JACKTOOLS_BOOTSTRAP_DIR:-}" ]]; then TARGET_DIR="$JACKTOOLS_BOOTSTRAP_DIR"; fi

BS_REPO="${JACKTOOLS_REPO:-}"
BS_REF="${JACKTOOLS_REF:-}"
BS_REF_TYPE="branch"
BS_PROVIDER="${JACKTOOLS_PROVIDER:-}"
BS_BASE_URL="${JACKTOOLS_BASE_URL:-}"
BS_TOKEN_FILE="${JACKTOOLS_TOKEN_FILE:-}"
BS_CACERT="${JACKTOOLS_CACERT:-}"
BS_ALLOW_HTTP=0
BS_LOCAL=""
BS_HEADER_FILE=""
BS_PROGRESS=0   # 1 = the download progress line is open on the terminal
declare -a BS_FORWARD=()

bs_die() { bs_progress_break; printf 'ERRORE: %s\n' "$*" >&2; exit 1; }
bs_warn() { bs_progress_break; printf 'AVVISO: %s\n' "$*" >&2; }

# Download progress: one line rewritten in place, only when stdout is a terminal.
# bs_progress DONE TOTAL FILE
bs_progress() {
    [[ -t 1 ]] || return 0
    local width=20 filled bar rest
    filled=$(( $1 * width / $2 ))
    printf -v bar '%*s' "$filled" ''
    printf -v rest '%*s' "$(( width - filled ))" ''
    printf '\rDownload [%s%s] %d/%d  %.40s\033[K' "${bar// /#}" "${rest// /-}" "$1" "$2" "$3"
    BS_PROGRESS=1
}
# Clears the progress line (end of the download).
bs_progress_end() { if (( BS_PROGRESS )); then printf '\r\033[K'; BS_PROGRESS=0; fi; }
# Leaves the progress line visible and moves to a new line (before an error or warning).
bs_progress_break() { if (( BS_PROGRESS )); then printf '\n'; BS_PROGRESS=0; fi; }

bs_usage() {
    cat <<'EOF'
Uso: sudo bash jacktools-bootstrap.sh [opzioni] [-- comando e opzioni di jacktools.sh]

  --repo URL         repository (GitHub, GitLab, Gitea/Forgejo); predefinito nel file
  --ref BRANCH       branch da usare (predefinito: main)
  --tag TAG          tag da usare al posto del branch
  --provider P       github | gitlab | gitea | raw (di solito ricavato dall'URL)
  --base-url URL     URL diretto dei file (server web statico o casi particolari)
  --token-file FILE  token per repository privati (file di root, permessi 0600)
  --cacert FILE      certificato della CA per server interni
  --allow-http       accetta http (sconsigliato)
  --local DIR        nessun download: esegue la copia in DIR
  -h, --help         questo aiuto
EOF
}

bs_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --repo|--ref|--tag|--provider|--base-url|--token-file|--cacert|--local)
                (( $# >= 2 )) || bs_die "l'opzione $1 richiede un valore."
                case "$1" in
                    --repo) BS_REPO="$2" ;;
                    --ref) BS_REF="$2"; BS_REF_TYPE=branch ;;
                    --tag) BS_REF="$2"; BS_REF_TYPE=tag ;;
                    --provider) BS_PROVIDER="$2" ;;
                    --base-url) BS_BASE_URL="$2" ;;
                    --token-file) BS_TOKEN_FILE="$2" ;;
                    --cacert) BS_CACERT="$2" ;;
                    --local) BS_LOCAL="$2" ;;
                esac
                shift 2
                ;;
            --allow-http) BS_ALLOW_HTTP=1; shift ;;
            -h|--help) bs_usage; exit 0 ;;
            --) shift; BS_FORWARD=("$@"); return 0 ;;
            *) bs_die "opzione sconosciuta: $1 (le opzioni di jacktools.sh vanno dopo --)" ;;
        esac
    done
}

bs_valid_url() {
    local scheme='https'
    (( BS_ALLOW_HTTP )) && scheme='https?'
    [[ "$1" =~ ^${scheme}://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%+-]+)*/?$ ]]
}

bs_valid_ref() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != *..* && "$1" != /* ]]; }

# Provider from the repository host: github.com, any host with "gitlab", otherwise Gitea/Forgejo.
bs_detect_provider() {
    local host="${1#*://}"
    host=${host%%/*}
    case "$host" in
        github.com|www.github.com) printf github ;;
        *gitlab*) printf gitlab ;;
        *) printf gitea ;;
    esac
}

# bs_base_url: raw URL of the repository root for the chosen ref.
bs_base_url() {
    local repo="${BS_REPO%/}" path
    repo=${repo%.git}
    case "$BS_PROVIDER" in
        github)
            path=${repo#*://*/}
            [[ "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || bs_die "URL GitHub non valido: $BS_REPO (atteso https://github.com/utente/progetto)"
            if [[ "$BS_REF_TYPE" == tag ]]; then printf 'https://raw.githubusercontent.com/%s/refs/tags/%s' "$path" "$BS_REF"
            else printf 'https://raw.githubusercontent.com/%s/refs/heads/%s' "$path" "$BS_REF"; fi
            ;;
        gitlab) printf '%s/-/raw/%s' "$repo" "$BS_REF" ;;
        gitea) printf '%s/raw/%s/%s' "$repo" "$BS_REF_TYPE" "$BS_REF" ;;
        *) bs_die "provider sconosciuto: $BS_PROVIDER (github, gitlab, gitea o raw)" ;;
    esac
}

# Resolve the effective source once: BS_BASE_URL, JACKTOOLS_SOURCE and the arguments
# that reproduce it on another server (JACKTOOLS_SOURCE_ARGS, never the token).
bs_resolve_source() {
    local args=()
    if [[ -n "$BS_BASE_URL" ]]; then
        BS_BASE_URL=${BS_BASE_URL%/}
        bs_valid_url "$BS_BASE_URL" || bs_die "URL non valido o non https: $BS_BASE_URL"
        BS_PROVIDER=raw
        args=(--base-url "$BS_BASE_URL")
        JACKTOOLS_SOURCE="raw $BS_BASE_URL"
    else
        # The default provider belongs to the default repository only.
        if [[ -z "$BS_REPO" ]]; then
            BS_REPO="$DEFAULT_REPO"
            BS_PROVIDER="${BS_PROVIDER:-$DEFAULT_PROVIDER}"
        fi
        if [[ -z "$BS_REF" ]]; then
            BS_REF="$DEFAULT_REF"
            BS_REF_TYPE="$DEFAULT_REF_TYPE"
        fi
        bs_valid_url "$BS_REPO" || bs_die "URL del repository non valido o non https: $BS_REPO"
        bs_valid_ref "$BS_REF" || bs_die "branch o tag non valido: $BS_REF"
        [[ -n "$BS_PROVIDER" ]] || BS_PROVIDER=$(bs_detect_provider "$BS_REPO")
        [[ "$BS_PROVIDER" != raw ]] || bs_die "--provider raw richiede --base-url."
        BS_BASE_URL=$(bs_base_url)
        args=(--repo "$BS_REPO")
        if [[ "$BS_REF_TYPE" == tag ]]; then args+=(--tag "$BS_REF"); else args+=(--ref "$BS_REF"); fi
        [[ "$BS_PROVIDER" == "$(bs_detect_provider "$BS_REPO")" ]] || args+=(--provider "$BS_PROVIDER")
        JACKTOOLS_SOURCE="$BS_PROVIDER $BS_REPO ($BS_REF_TYPE $BS_REF)"
    fi
    [[ -z "$BS_TOKEN_FILE" ]] || args+=(--token-file "$BS_TOKEN_FILE")
    [[ -z "$BS_CACERT" ]] || args+=(--cacert "$BS_CACERT")
    (( BS_ALLOW_HTTP == 0 )) || args+=(--allow-http)
    JACKTOOLS_SOURCE_ARGS="${args[*]}"
    JACKTOOLS_BOOTSTRAP_URL="$BS_BASE_URL/bootstrap.sh"
    if [[ "$BS_BASE_URL" == http://* ]]; then bs_warn "download senza cifratura (http): usare https appena possibile."; fi
    export JACKTOOLS_SOURCE JACKTOOLS_SOURCE_ARGS JACKTOOLS_BOOTSTRAP_URL
}

# Secret files must belong to root (the current user in tests) and be private.
bs_private_file() {
    local file="$1" owner mode
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    owner=$(stat -c %u -- "$file"); mode=$(stat -c %a -- "$file")
    if [[ "${JACKTOOLS_TEST_MODE:-0}" == 1 ]]; then [[ "$owner" == "${EUID}" ]] || return 1; else [[ "$owner" == 0 ]] || return 1; fi
    (( (8#$mode & 8#077) == 0 ))
}

# The token goes into a private header file read by curl (-H @file): never in an argument,
# a URL, the environment of jacktools.sh or the output.
bs_prepare_token() {
    local token header
    [[ -n "$BS_TOKEN_FILE" ]] || return 0
    bs_private_file "$BS_TOKEN_FILE" || bs_die "file del token non sicuro: deve essere di root con permessi 0600 ($BS_TOKEN_FILE)."
    IFS= read -r token <"$BS_TOKEN_FILE" || true
    [[ "$token" =~ ^[A-Za-z0-9._~+/=-]{8,}$ ]] || bs_die "il file del token non contiene un token valido."
    case "$BS_PROVIDER" in
        gitlab) header="PRIVATE-TOKEN: $token" ;;
        gitea) header="Authorization: token $token" ;;
        *) header="Authorization: Bearer $token" ;;
    esac
    BS_HEADER_FILE=$(mktemp)
    chmod 0600 "$BS_HEADER_FILE"
    printf '%s\n' "$header" >"$BS_HEADER_FILE"
}

bs_cleanup() { [[ -z "$BS_HEADER_FILE" ]] || rm -f -- "$BS_HEADER_FILE"; }

# bs_fetch URL OUTPUT
bs_fetch() {
    local -a options=(-fsSL --retry 2 --connect-timeout 15 --max-time 120)
    if (( BS_ALLOW_HTTP )); then options+=(--proto '=http,https'); else options+=(--proto '=https' --tlsv1.2); fi
    [[ -z "$BS_CACERT" ]] || options+=(--cacert "$BS_CACERT")
    [[ -z "$BS_HEADER_FILE" ]] || options+=(-H "@$BS_HEADER_FILE")
    curl "${options[@]}" -o "$2" "$1"
}

bs_safe_path() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != *..* && "$1" != /* ]]; }

# bs_check_file PATH FILE: scripts must be valid Bash; bashrc.d modules are snippets.
bs_check_file() {
    local rel="$1" file="$2" first
    [[ -s "$file" ]] || bs_die "file scaricato vuoto: $rel"
    [[ "$rel" == *.sh ]] || return 0
    if [[ "$rel" != assets/bashrc.d/* ]]; then
        IFS= read -r first <"$file" || true
        [[ "$first" == '#!/usr/bin/env bash' ]] || bs_die "il file non è uno script Bash valido: $rel"
    fi
    bash -n "$file" || bs_die "errore di sintassi nel file scaricato: $rel"
}

bs_prepare_target() {
    if [[ -L "$TARGET_DIR" ]]; then bs_die "$TARGET_DIR è un link simbolico: operazione rifiutata."; fi
    if [[ -e "$TARGET_DIR" ]]; then
        [[ -d "$TARGET_DIR" ]] || bs_die "$TARGET_DIR esiste e non è una directory."
        rm -rf -- "$TARGET_DIR"
    fi
    mkdir -p -- "$TARGET_DIR"
    chmod 0700 "$TARGET_DIR"
}

bs_download() {
    local rel destination count
    local -a files
    bs_prepare_target
    printf 'Sorgente: %s\n' "$JACKTOOLS_SOURCE"
    bs_fetch "$BS_BASE_URL/MANIFEST" "$TARGET_DIR/MANIFEST" || bs_die "download fallito: $BS_BASE_URL/MANIFEST"
    mapfile -t files < <(grep -vE '^[[:space:]]*(#|$)' "$TARGET_DIR/MANIFEST")
    (( ${#files[@]} > 0 )) || bs_die "MANIFEST vuoto."
    count=0
    for rel in "${files[@]}"; do
        bs_progress "$count" "${#files[@]}" "$rel"
        bs_safe_path "$rel" || bs_die "percorso non sicuro nel MANIFEST: $rel"
        destination="$TARGET_DIR/$rel"
        mkdir -p -- "$(dirname -- "$destination")"
        bs_fetch "$BS_BASE_URL/$rel" "$destination.download" || bs_die "download fallito: $BS_BASE_URL/$rel"
        bs_check_file "$rel" "$destination.download"
        mv -f -- "$destination.download" "$destination"
        (( ++count ))
    done
    bs_progress_end
    chmod -R go-rwx "$TARGET_DIR"
    printf 'Scaricati e verificati %s file.\n' "${#files[@]}"
}

bs_main() {
    local dir rc=0
    bs_parse_args "$@"
    if [[ "${JACKTOOLS_TEST_MODE:-0}" != 1 ]]; then
        [[ ${EUID} -eq 0 ]] || bs_die "eseguire il bootstrap come root (sudo bash ...)."
    fi
    if [[ -n "$BS_LOCAL" ]]; then
        dir=$(cd -- "$BS_LOCAL" 2>/dev/null && pwd -P) || bs_die "directory non trovata: $BS_LOCAL"
        [[ -f "$dir/jacktools.sh" ]] || bs_die "jacktools.sh non trovato in $dir"
        export JACKTOOLS_SOURCE="local $dir"
    else
        command -v curl >/dev/null 2>&1 || bs_die "curl non è installato."
        bs_resolve_source
        trap bs_cleanup EXIT
        bs_prepare_token
        bs_download
        bs_cleanup
        dir="$TARGET_DIR"
    fi
    bash "$dir/jacktools.sh" "${BS_FORWARD[@]}" || rc=$?
    exit "$rc"
}

# Sourced by the tests: only run when executed.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then bs_main "$@"; fi
