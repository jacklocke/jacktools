#!/usr/bin/env bash
# jtool.sh, the short launcher: piped into bash like "curl ... | sudo bash", with a fake curl.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT

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
export PATH="$WORK/bin:$PATH" FAKE_SERVER="$ROOT" FAKE_CURL_LOG="$WORK/curl.log"
export FAKE_BASE=https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main
export JACKTOOLS_TEST_MODE=1 JTOOL_TARGET="$WORK/jacktools-bootstrap.sh"
piped() { bash -s -- "$@" <"$WORK/jtool.sh" 2>&1; }   # like: curl ... | sudo bash -s -- ARGS

cp "$ROOT/jtool.sh" "$WORK/jtool.sh"
: >"$WORK/curl.log"
out=$(piped --local "$ROOT" -- version)
assert_contains 'bootstrap run with the forwarded arguments' 'JackTools 2.0.0-dev' "$out"
assert_true 'bootstrap.sh saved as downloaded' cmp -s "$ROOT/bootstrap.sh" "$JTOOL_TARGET"
assert_eq 'bootstrap.sh private' 700 "$(stat -c %a "$JTOOL_TARGET")"
assert_contains 'downloads bootstrap.sh from the GitHub default' "$FAKE_BASE/bootstrap.sh" "$(cat "$WORK/curl.log")"
assert_true 'https only' grep -q -- '--proto =https' "$WORK/curl.log"
assert_eq 'launcher URL matches the bootstrap default' \
    "$(bash -c 'source "$1"; JACKTOOLS_TEST_MODE=0; BS_REPO=$DEFAULT_REPO BS_REF=$DEFAULT_REF BS_REF_TYPE=$DEFAULT_REF_TYPE BS_PROVIDER=github bs_base_url' _ "$ROOT/bootstrap.sh")/bootstrap.sh" \
    "$(sed -n 's/^JTOOL_BOOTSTRAP_URL="\(.*\)"$/\1/p' "$ROOT/jtool.sh")"

# A download cut halfway (last line missing) runs nothing.
: >"$WORK/curl.log"
head -n -1 "$ROOT/jtool.sh" >"$WORK/jtool.sh"
out=$(piped --local "$ROOT" -- version)
assert_eq 'truncated launcher does nothing' '' "$out$(cat "$WORK/curl.log")"

# Failed download: clear error, nothing left behind.
cp "$ROOT/jtool.sh" "$WORK/jtool.sh"; rm -f "$JTOOL_TARGET"
out=$(FAKE_BASE=https://elsewhere.example piped -- version || true)
assert_contains 'download error reported' 'ERRORE: download fallito' "$out"
assert_false 'no bootstrap left after a failure' test -e "$JTOOL_TARGET"
assert_eq 'no temporary file left' '' "$(find "$WORK" -maxdepth 1 -name 'jacktools-bootstrap.sh.*')"

# A link at the target path is replaced, never written through.
printf 'keep\n' >"$WORK/victim"; ln -s "$WORK/victim" "$JTOOL_TARGET"
piped --local "$ROOT" -- version >/dev/null
assert_eq 'link target untouched' keep "$(cat "$WORK/victim")"
assert_false 'target is no longer a link' test -L "$JTOOL_TARGET"

# Outside test mode a non-root user is refused before any download.
if (( EUID != 0 )); then
    : >"$WORK/curl.log"
    out=$(JACKTOOLS_TEST_MODE=0 piped -- version || true)
    assert_contains 'root required' 'sudo bash' "$out"
    assert_eq 'nothing downloaded without root' '' "$(cat "$WORK/curl.log")"
fi
finish_tests
