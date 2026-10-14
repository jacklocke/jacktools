#!/usr/bin/env bash
# Every message key used by the code exists in each catalog, and no catalog key is unused.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

mapfile -t code_files < <(find "$ROOT/lib" -name '*.sh'; printf '%s\n' "$ROOT/jacktools.sh")
# Keys are always namespaced (area.name...) and end at a quote, a parenthesis, a semicolon
# or a blank, so dynamic keys such as "state.flag.$flag" are skipped (list them in
# # msg-keys: comments).
key_re='[a-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+'
end_re='(["\);[:space:]]|$)'
used=$(
    {
        grep -ohE "\\b(msg|msg_get|ui_info|ui_warn|ui_error|die|ui_title|ui_confirm|ui_checklist|state_label|state_set) +\"?$key_re$end_re" "${code_files[@]}" |
            sed -E 's/^[a-z_]+ +"?//; s/["\);[:space:]]$//'
        grep -ohE "\\b(ui_prompt|ui_prompt_secret|ui_menu|ui_confirm_exact|step_register|network_ask) +[^ ]+ +\"?$key_re$end_re" "${code_files[@]}" |
            sed -E 's/^[a-z_]+ +[^ ]+ +"?//; s/["\);[:space:]]$//'
        grep -ohE '# msg-keys:.*' "${code_files[@]}" | sed 's/# msg-keys://' | tr ' ' '\n'
    } | grep -E "^$key_re\$" | sort -u
)
assert_true 'key extraction finds keys' test -n "$used"

for catalog in "$ROOT"/messages/*.sh; do
    lang=$(basename "$catalog" .sh)
    assert_rc "catalog $lang loads" 0 msg_load "$lang"
    missing=''
    while IFS= read -r key; do
        [[ -v "MSG[$key]" ]] || missing+=" $key"
    done <<<"$used"
    assert_eq "catalog $lang has every used key" '' "$missing"
    unused=''
    for key in "${!MSG[@]}"; do
        grep -rqF -- "$key" "${code_files[@]}" || unused+=" $key"
    done
    assert_eq "catalog $lang has no unused keys" '' "$unused"
done
finish_tests
