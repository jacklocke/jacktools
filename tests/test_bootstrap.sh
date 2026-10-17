#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT
export JACKTOOLS_TEST_MODE=1 NO_COLOR=1
# shellcheck source=/dev/null
source "$ROOT/bootstrap.sh"
set +e +E; trap - ERR; set -e

# ---- URL construction
resolve() { # resolve ARGS... -> base URL (in a subshell, like a fresh run)
    ( BS_REPO='' BS_REF='' BS_PROVIDER='' BS_BASE_URL='' BS_REF_TYPE=branch BS_ALLOW_HTTP=0
      bs_parse_args "$@"; bs_resolve_source >/dev/null 2>&1; printf '%s|%s|%s' "$BS_BASE_URL" "$JACKTOOLS_SOURCE_ARGS" "$JACKTOOLS_SOURCE" )
}
expected_base=$(BS_REPO="$DEFAULT_REPO" BS_REF="$DEFAULT_REF" BS_REF_TYPE="$DEFAULT_REF_TYPE" BS_PROVIDER="${DEFAULT_PROVIDER:-$(bs_detect_provider "$DEFAULT_REPO")}" bs_base_url)
assert_eq 'default source comes from DEFAULT_REPO' "$expected_base" "$(resolve | cut -d'|' -f1)"
assert_eq 'shipped default is GitHub' 'https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main' "$(resolve | cut -d'|' -f1)"
assert_eq 'default tag type honoured' 'https://git.example.org/me/jt/raw/tag/v9' \
    "$( DEFAULT_REPO=https://git.example.org/me/jt DEFAULT_REF=v9 DEFAULT_REF_TYPE=tag; resolve | cut -d'|' -f1 )"
assert_eq 'default provider only for the default repo' 'https://code.example/me/jt/-/raw/main|https://other.example/x/y/raw/branch/main' \
    "$( DEFAULT_REPO=https://code.example/me/jt DEFAULT_PROVIDER=gitlab; printf '%s|%s' "$(resolve | cut -d'|' -f1)" "$(resolve --repo https://other.example/x/y | cut -d'|' -f1)" )"
assert_eq 'gitea tag' 'https://git.example.org/me/jt/raw/tag/v2.0.0' "$(resolve --repo https://git.example.org/me/jt --tag v2.0.0 | cut -d'|' -f1)"
assert_eq 'github branch' 'https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/dev' "$(resolve --repo https://github.com/jacklocke/jacktools.git --ref dev | cut -d'|' -f1)"
assert_eq 'github tag' 'https://raw.githubusercontent.com/jacklocke/jacktools/refs/tags/v2' "$(resolve --repo https://github.com/jacklocke/jacktools/ --tag v2 | cut -d'|' -f1)"
assert_eq 'gitlab' 'https://gitlab.example.com/grp/jt/-/raw/main' "$(resolve --repo https://gitlab.example.com/grp/jt | cut -d'|' -f1)"
assert_eq 'forced provider kept in args' '--repo https://code.example/me/jt --ref main --provider gitlab' "$(resolve --repo https://code.example/me/jt --provider gitlab | cut -d'|' -f2)"
assert_eq 'base url wins' 'https://files.example/jt|--base-url https://files.example/jt' "$(resolve --repo https://github.com/a/b --base-url https://files.example/jt/ | cut -d'|' -f1-2)"
assert_eq 'token and cacert paths kept, never the token' '--repo https://git.example.org/me/jt --ref main --token-file /root/t --cacert /root/ca.pem' \
    "$(resolve --repo https://git.example.org/me/jt --token-file /root/t --cacert /root/ca.pem | cut -d'|' -f2)"
for bad in 'http://git.example.org/me/jt' 'https://git.example.org/me jt' 'ftp://x/y' 'https://x/y;rm' 'git@github.com:a/b.git'; do
    assert_rc "repo refused: $bad" 1 quiet bash "$ROOT/bootstrap.sh" --repo "$bad" -- version
done
assert_rc 'bad ref refused' 1 quiet bash "$ROOT/bootstrap.sh" --ref '../x' -- version
assert_rc 'raw provider needs base-url' 1 quiet bash "$ROOT/bootstrap.sh" --provider raw -- version
assert_rc 'unknown option refused' 1 quiet bash "$ROOT/bootstrap.sh" --version
assert_contains 'help' '--token-file' "$(bash "$ROOT/bootstrap.sh" --help)"
assert_eq 'http only with --allow-http' 'http://git.lan/me/jt/raw/branch/main' "$(resolve --repo http://git.lan/me/jt --allow-http | cut -d'|' -f1)"

# ---- token header file
printf 'abcd1234TOKEN\n' >"$WORK/token"; chmod 600 "$WORK/token"
for case in 'gitea|Authorization: token abcd1234TOKEN' 'gitlab|PRIVATE-TOKEN: abcd1234TOKEN' 'github|Authorization: Bearer abcd1234TOKEN'; do
    out=$( BS_TOKEN_FILE="$WORK/token" BS_PROVIDER="${case%%|*}"; bs_prepare_token; cat "$BS_HEADER_FILE"; stat -c %a "$BS_HEADER_FILE"; rm -f "$BS_HEADER_FILE" )
    assert_eq "header for ${case%%|*}" "${case#*|}"$'\n600' "$out"
done
chmod 644 "$WORK/token"
assert_rc 'readable token file refused' 1 quiet bash -c "source '$ROOT/bootstrap.sh'; BS_TOKEN_FILE='$WORK/token' BS_PROVIDER=gitea; bs_prepare_token"
chmod 600 "$WORK/token"

# ---- end to end with a fake curl serving files from a directory
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out='' url=''
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; -H|--proto|--retry|--connect-timeout|--max-time|--cacert) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
rel=${url#"$FAKE_BASE"/}
[[ "$rel" != "$url" && -f "$FAKE_SERVER/$rel" ]] || exit 22
cp "$FAKE_SERVER/$rel" "$out"
FAKE
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" FAKE_BASE=https://files.example/jt FAKE_SERVER="$ROOT" FAKE_CURL_LOG="$WORK/curl.log"
export JACKTOOLS_BOOTSTRAP_DIR="$WORK/target"
out=$(bash "$ROOT/bootstrap.sh" --base-url https://files.example/jt --token-file "$WORK/token" -- version 2>&1)
assert_contains 'jacktools started with forwarded command' 'JackTools 2.0.0-dev' "$out"
assert_contains 'source shown' 'Sorgente: raw https://files.example/jt' "$out"
missing=''
while IFS= read -r rel; do cmp -s "$ROOT/$rel" "$WORK/target/$rel" || missing+=" $rel"; done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/MANIFEST")
assert_eq 'every MANIFEST file downloaded identical' '' "$missing"
assert_eq 'target is private' 700 "$(stat -c %a "$WORK/target")"
assert_false 'token never in curl arguments' grep -q abcd1234TOKEN "$WORK/curl.log"
assert_true 'token sent through a header file' grep -q -- '-H @' "$WORK/curl.log"
assert_true 'https only' grep -q -- "--proto =https" "$WORK/curl.log"
assert_false 'token never in output' grep -q abcd1234TOKEN <<<"$out"
assert_false 'no progress bar without a terminal' grep -q 'Download \[' <<<"$out"
# With a terminal (script gives a pty): one line rewritten in place, cleared at the end.
tty_out=$(script -qec "bash '$ROOT/bootstrap.sh' --base-url https://files.example/jt -- version" /dev/null 2>&1 </dev/null)
assert_contains 'progress bar on a terminal' 'Download [--------------------] 0/' "$tty_out"
assert_contains 'progress shows the file' '1/' "$tty_out"
assert_contains 'progress line cleared before the summary' $'\r\e[KScaricati e verificati' "$tty_out"
assert_false 'header file removed' bash -c "ls /tmp/tmp.* 2>/dev/null | xargs -r grep -l abcd1234TOKEN 2>/dev/null | grep -q ."

# A tampered server: path traversal in MANIFEST, broken script, missing file.
cp -r "$ROOT" "$WORK/server"
export FAKE_SERVER="$WORK/server"
printf '../../etc/passwd\n' >>"$WORK/server/MANIFEST"
assert_contains 'path traversal refused' 'percorso non sicuro' "$(bash "$ROOT/bootstrap.sh" --base-url https://files.example/jt -- version 2>&1 || true)"
cp "$ROOT/MANIFEST" "$WORK/server/MANIFEST"
printf 'if then\n' >>"$WORK/server/lib/core/ui.sh"
assert_contains 'syntax error refused' 'errore di sintassi' "$(bash "$ROOT/bootstrap.sh" --base-url https://files.example/jt -- version 2>&1 || true)"
cp "$ROOT/lib/core/ui.sh" "$WORK/server/lib/core/ui.sh"
rm "$WORK/server/lib/core/env.sh"
assert_contains 'missing file reported with its URL' 'download fallito: https://files.example/jt/lib/core/env.sh' "$(bash "$ROOT/bootstrap.sh" --base-url https://files.example/jt -- version 2>&1 || true)"
tty_out=$(script -qec "bash '$ROOT/bootstrap.sh' --base-url https://files.example/jt -- version" /dev/null 2>&1 </dev/null || true)
assert_contains 'error on its own line after the progress bar' $'lib/core/env.sh\e[K\r\nERRORE: download fallito' "$tty_out"
rm -rf "$WORK/target"; ln -s "$WORK/server" "$WORK/target"
assert_contains 'symlinked target refused' 'link simbolico' "$(bash "$ROOT/bootstrap.sh" --base-url https://files.example/jt -- version 2>&1 || true)"
rm "$WORK/target"

# --local runs a checkout without downloading.
: >"$WORK/curl.log"
assert_contains 'local mode' 'JackTools 2.0.0-dev' "$(bash "$ROOT/bootstrap.sh" --local "$ROOT" -- version 2>&1)"
assert_eq 'local mode downloads nothing' '' "$(cat "$WORK/curl.log")"
finish_tests
