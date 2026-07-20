#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/test_helper.sh"

mapfile -t manifest < <(
    awk '
        /^files=\(/ {inside=1; next}
        inside && /^\)/ {exit}
        inside {for (i=1; i<=NF; i++) print $i}
    ' "$ROOT/bootstrap.sh"
)

expected=(
    jacktools.sh
    assets/header.txt assets/disclaimer.txt assets/packages.txt
    assets/bashrc_customization assets/tmux.conf
    lib/common.sh lib/hostname.sh lib/network.sh lib/ssh.sh
    lib/users.sh lib/customization.sh lib/docker.sh lib/packages.sh lib/cleanup.sh
)

assert_eq 'manifest bootstrap completo' "$(printf '%s\n' "${expected[@]}" | sort)" "$(printf '%s\n' "${manifest[@]}" | sort)"
assert_eq 'manifest bootstrap senza duplicati' "${#manifest[@]}" "$(printf '%s\n' "${manifest[@]}" | sort -u | wc -l | tr -d ' ')"

for file in "${manifest[@]}"; do
    assert_true "file bootstrap presente: $file" test -s "$ROOT/$file"
    if [[ "$file" == *.sh ]]; then
        assert_eq "shebang Bash: $file" '#!/usr/bin/env bash' "$(head -n 1 "$ROOT/$file")"
        assert_true "sintassi Bash: $file" bash -n "$ROOT/$file"
    fi
done

finish_tests
