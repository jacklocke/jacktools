#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/test_helper.sh"
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/customization.sh"
source "$ROOT/lib/users.sh"

work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
# shellcheck disable=SC2016 # Il test richiede che $PATH resti letterale nel file.
printf 'export PATH="$PATH"\n' >"$work/bashrc"
render_managed_bashrc "$work/bashrc" "$ROOT/assets/bashrc_customization" "$work/one"
render_managed_bashrc "$work/one" "$ROOT/assets/bashrc_customization" "$work/two"
assert_true 'blocco bashrc idempotente' cmp -s "$work/one" "$work/two"
assert_eq 'un solo blocco bashrc' 1 "$(grep -c '^# >>> JACKTOOLS CUSTOMIZATION >>>$' "$work/two")"
assert_true 'personalizzazione Bash esistente rilevata' bashrc_has_managed_customization "$work/two"
printf '# >>> JACKTOOLS CUSTOMIZATION >>>\nblocco incompleto\n' >"$work/incomplete"
if bashrc_has_managed_customization "$work/incomplete"; then
    fail 'marcatori Bash incompleti rifiutati'
elif [[ $? -eq 2 ]]; then
    pass 'marcatori Bash incompleti rifiutati'
else
    fail 'marcatori Bash incompleti rifiutati'
fi

key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting test@example'
append_authorized_key_once "$work/authorized_keys" "$key"
append_authorized_key_once "$work/authorized_keys" "$key"
assert_eq 'chiave authorized_keys non duplicata' 1 "$(grep -Fxc "$key" "$work/authorized_keys")"
finish_tests
