#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/test_helper.sh
source "$ROOT/tests/test_helper.sh"
# shellcheck disable=SC2034 # Variabili consumate dalle librerie caricate dinamicamente.
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/packages.sh
source "$ROOT/lib/packages.sh"

temporary=$(mktemp); trap 'rm -f -- "$temporary"' EXIT
printf '# commento\ncurl default\nvim\n' >"$temporary"
assert_true 'parser accetta file valido' parse_packages_file "$temporary"
assert_eq 'due pacchetti riconosciuti' 2 "${#PACKAGE_NAMES[@]}"
assert_eq 'flag default riconosciuto' 1 "${PACKAGE_DEFAULTS[0]}"
assert_eq 'assenza flag non preselezionata' 0 "${PACKAGE_DEFAULTS[1]}"

command_log=$(mktemp)
# shellcheck disable=SC2034 # Letta da run_cmd nel modulo common.sh.
JACKTOOLS_COMMAND_LOG="$command_log"
assert_true 'apt-get update preliminare disponibile' refresh_apt_indexes
assert_true 'apt-get update e il comando preliminare' grep -Fqx 'MOCK: apt-get update' "$command_log"
rm -f -- "$command_log"

assert_true 'lista programmi reale valida' parse_packages_file "$ROOT/assets/packages.txt"
for required_package in zip unzip curl wget powerline tmux nano; do
    if printf '%s\n' "${PACKAGE_NAMES[@]}" | grep -Fxq "$required_package"; then
        pass "pacchetto richiesto presente: $required_package"
    else
        fail "pacchetto richiesto presente: $required_package"
    fi
done
printf 'curl --force\n' >"$temporary"
assert_false 'flag sconosciuto rifiutato' parse_packages_file "$temporary"
printf '%s\n' '--option default' >"$temporary"
assert_false 'nome malevolo rifiutato' parse_packages_file "$temporary"
finish_tests
