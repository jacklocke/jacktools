#!/usr/bin/env bash
# tools/cambia-server-git.sh, run on a throw-away copy of the project.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"

WORK=$(mktemp -d); trap 'rm -rf -- "$WORK"' EXIT
PROJ="$WORK/proj"
fresh() { rm -rf "$PROJ"; mkdir -p "$PROJ"; (cd "$ROOT" && tar --exclude='./.cambia-server-backup-*' -cf - .) | (cd "$PROJ" && tar -xf -); }
cs() { timeout 30 bash "$PROJ/tools/cambia-server-git.sh" "$@" </dev/null; }
default_of() { sed -n "s/^$1=\"\\(.*\\)\".*/\\1/p" "$PROJ/bootstrap.sh"; }
GITEA=https://git.dominio.di.example/utente/jacktools

# Shipped default: GitHub, consistent between bootstrap.sh and README.
fresh
assert_eq 'shipped DEFAULT_REPO is GitHub' https://github.com/jacklocke/jacktools "$(default_of DEFAULT_REPO)"
assert_contains 'README launches from GitHub raw' 'https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/bootstrap.sh' "$(cat "$PROJ/README.md")"

# Same server: nothing to do, nothing written.
out=$(cs --repo https://github.com/jacklocke/jacktools --yes)
assert_contains 'same server: nothing to change' 'Nessuna modifica necessaria' "$out"
assert_eq 'same server: no backup' '' "$(find "$PROJ" -maxdepth 1 -name '.cambia-server-backup-*')"

# Dry-run shows the change and writes nothing.
out=$(cs --repo "$GITEA" --dry-run)
assert_contains 'dry-run previews README' "+curl -fsSL $GITEA/raw/branch/main/bootstrap.sh" "$out"
assert_contains 'dry-run previews bootstrap' "+DEFAULT_REPO=\"$GITEA\"" "$out"
assert_eq 'dry-run writes nothing' https://github.com/jacklocke/jacktools "$(default_of DEFAULT_REPO)"

# To Gitea.
out=$(cs --repo "$GITEA/" --yes)
readme=$(cat "$PROJ/README.md")
assert_eq 'DEFAULT_REPO updated (trailing slash removed)' "$GITEA" "$(default_of DEFAULT_REPO)"
assert_contains 'README raw URL in Gitea format' "curl -fsSL $GITEA/raw/branch/main/bootstrap.sh" "$readme"
assert_contains 'README --repo updated' "--repo $GITEA" "$readme"
assert_false 'no GitHub raw URL left in README' grep -q 'raw.githubusercontent.com/jacklocke/jacktools' "$PROJ/README.md"
assert_contains 'generic placeholders untouched' 'https://raw.githubusercontent.com/<utente>/<progetto>/refs/heads/main/bootstrap.sh' "$readme"
assert_true 'bootstrap.sh still valid' bash -n "$PROJ/bootstrap.sh"
assert_eq 'jtool.sh downloads from the new server' "JTOOL_BOOTSTRAP_URL=\"$GITEA/raw/branch/main/bootstrap.sh\"" "$(grep '^JTOOL_BOOTSTRAP_URL=' "$PROJ/jtool.sh")"
assert_true 'backup of originals' test -f "$(find "$PROJ" -maxdepth 1 -name '.cambia-server-backup-*' | head -1)/README.md"
assert_true 'other projects untouched (drin)' cmp -s "$ROOT/assets/drin.sh" "$PROJ/assets/drin.sh"
assert_true 'CLAUDE.md untouched' cmp -s "$ROOT/CLAUDE.md" "$PROJ/CLAUDE.md"
assert_contains 'launch command printed' "sudo bash /tmp/jacktools-bootstrap.sh --repo $GITEA" "$out"
# The bootstrap really resolves the new default.
base=$(cd "$PROJ" && JACKTOOLS_TEST_MODE=1 bash -c 'source ./bootstrap.sh; bs_resolve_source >/dev/null 2>&1; printf %s "$BS_BASE_URL"')
assert_eq 'bootstrap resolves the new default' "$GITEA/raw/branch/main" "$base"

# Back to GitHub: every file identical to the original.
cs --repo https://github.com/jacklocke/jacktools --yes >/dev/null
assert_eq 'round trip restores every file' '' "$(diff -r -q -x '.cambia-server-backup-*' "$ROOT" "$PROJ" 2>&1 || true)"

# Tag, GitLab, forced provider.
fresh
cs --repo https://github.com/someone/fork --tag v2.1.0 --yes >/dev/null
assert_eq 'tag type stored' tag "$(default_of DEFAULT_REF_TYPE)"
assert_contains 'tag raw URL' 'https://raw.githubusercontent.com/someone/fork/refs/tags/v2.1.0/bootstrap.sh' "$(cat "$PROJ/README.md")"
fresh
cs --repo https://gitlab.example.com/grp/jt --yes >/dev/null
assert_contains 'GitLab raw URL' 'https://gitlab.example.com/grp/jt/-/raw/main/bootstrap.sh' "$(cat "$PROJ/README.md")"
fresh
cs --repo https://code.lan/grp/jt --provider gitlab --yes >/dev/null
assert_eq 'forced provider stored' gitlab "$(default_of DEFAULT_PROVIDER)"
assert_contains 'README gets --provider' '--repo https://code.lan/grp/jt --provider gitlab' "$(cat "$PROJ/README.md")"
cs --repo https://github.com/jacklocke/jacktools --yes >/dev/null
assert_eq 'forced provider removed on return' '' "$(diff -r -q -x '.cambia-server-backup-*' "$ROOT" "$PROJ" 2>&1 || true)"

# A name that merely starts like the old one is not replaced.
fresh
printf 'see https://github.com/jacklocke/jacktools-extra\n' >>"$PROJ/README.md"
cs --repo "$GITEA" --yes >/dev/null
assert_contains 'longer repository name left alone' 'https://github.com/jacklocke/jacktools-extra' "$(cat "$PROJ/README.md")"
# New URL containing the old one: replaced once, not twice.
fresh
cs --repo https://github.com/jacklocke/jacktools/sub --yes >/dev/null 2>&1 || true
assert_false 'no double replacement' grep -q 'jacktools/sub/sub' "$PROJ/README.md"

# Invalid input refused.
fresh
assert_rc 'http refused' 1 quiet cs --repo http://git.lan/me/jt --yes
assert_rc 'bad URL refused' 1 quiet cs --repo 'https://git.lan/me jt' --yes
assert_rc 'bad ref refused' 1 quiet cs --repo "$GITEA" --ref '../x' --yes
assert_rc 'unknown provider refused' 1 quiet cs --repo "$GITEA" --provider svn --yes
assert_eq 'nothing written after refusals' https://github.com/jacklocke/jacktools "$(default_of DEFAULT_REPO)"

# Interactive: questions answered on stdin (no terminal, so the provider is detected),
# per-file confirmation honoured: README yes, bootstrap.sh no.
fresh
printf '%s\nb\nmain\ns\nn\n' "$GITEA" | timeout 30 bash "$PROJ/tools/cambia-server-git.sh" >/dev/null 2>&1 || true
assert_contains 'first file confirmed (README)' "$GITEA" "$(cat "$PROJ/README.md")"
assert_eq 'second file declined (bootstrap.sh)' https://github.com/jacklocke/jacktools "$(default_of DEFAULT_REPO)"
finish_tests
