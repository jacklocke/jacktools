#!/usr/bin/env bash
# MANIFEST lists exactly the runtime files, and every script is valid Bash.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"

mapfile -t listed < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/MANIFEST" | sort)
mapfile -t actual < <(
    cd "$ROOT" && { printf '%s\n' jacktools.sh; find lib messages assets -type f; } | sort
)
assert_eq 'MANIFEST matches runtime files' "${actual[*]}" "${listed[*]}"
assert_eq 'MANIFEST has no duplicates' "${#listed[@]}" "$(printf '%s\n' "${listed[@]}" | sort -u | wc -l)"

for file in "${listed[@]}"; do
    assert_true "listed file exists: $file" test -s "$ROOT/$file"
    if [[ "$file" =~ ^[A-Za-z0-9._/-]+$ && "$file" != *..* ]]; then pass "safe path: $file"; else fail "safe path: $file"; fi
done
while IFS= read -r script; do
    rel=${script#"$ROOT"/}
    IFS= read -r first <"$script"
    # bashrc.d modules are snippets embedded in .bashrc, not scripts.
    if [[ "$rel" == assets/bashrc.d/* ]]; then
        if [[ "$first" == '# jt-module: '* ]]; then pass "module header: $rel"; else fail "module header: $rel"; fi
    else
        assert_eq "shebang: $rel" '#!/usr/bin/env bash' "$first"
    fi
    assert_true "bash -n: $rel" bash -n "$script"
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/.cambia-server-backup-*' | sort)

# Powerline theme assets: valid Python and JSON (checked only where python3 exists).
if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r file; do
        assert_true "python compiles: ${file#"$ROOT"/}" python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$file"
    done < <(find "$ROOT/assets" -name '*.py' | sort)
    while IFS= read -r file; do
        assert_true "valid json: ${file#"$ROOT"/}" python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$file"
    done < <(find "$ROOT/assets" -name '*.json' | sort)
fi

# Unix line endings everywhere: a CRLF script fails in bash before running a single line.
crlf=$({ find "$ROOT" -type f -not -path '*/.git/*' -not -path '*/.cambia-server-backup-*' -exec grep -lI $'\r' {} + 2>/dev/null || true; } | sed "s#^$ROOT/##" | xargs)
assert_eq 'no file with Windows line endings' '' "$crlf"
finish_tests
