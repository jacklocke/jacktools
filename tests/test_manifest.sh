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
finish_tests
