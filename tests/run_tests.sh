#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
rc=0
for test_file in "$ROOT"/tests/test_*.sh; do
    [[ "$test_file" == */test_helper.sh ]] && continue
    printf '\n== %s ==\n' "${test_file##*/}"
    bash "$test_file" || rc=1
done
(( rc == 0 )) && printf '\nALL TESTS PASSED\n' || printf '\nSOME TESTS FAILED\n' >&2
exit "$rc"
