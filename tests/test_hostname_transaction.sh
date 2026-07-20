#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/test_helper.sh"
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/hostname.sh"

work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
printf '127.0.1.1\tserver-old\n' >"$work/backup"
printf '127.0.1.1\tserver-new\n' >"$work/hosts"

HOSTNAME_SET_TO=''
hostnamectl() {
    if [[ ${1:-} == set-hostname ]]; then HOSTNAME_SET_TO="${2:-}"; return 0; fi
    return 1
}

assert_true 'rollback hostname completo riuscito' restore_hostname_backup server-old "$work/backup" "$work/hosts"
assert_eq 'rollback ripristina nome host' server-old "$HOSTNAME_SET_TO"
assert_true 'rollback ripristina file hosts' grep -Fqx $'127.0.1.1\tserver-old' "$work/hosts"
assert_false 'rollback hostname senza backup fallisce' restore_hostname_backup server-old '' "$work/hosts"

finish_tests
