#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

# Confirmations: only Y/y accepts; empty, N/n and EOF decline; invalid answers re-ask.
assert_true 'confirm y' ui_confirm main.version 1 <<<'y'
assert_true 'confirm Y' ui_confirm main.version 1 <<<'Y'
assert_false 'confirm n' ui_confirm main.version 1 <<<'n'
assert_false 'confirm empty' ui_confirm main.version 1 <<<''
assert_false 'confirm EOF' ui_confirm main.version 1 </dev/null
assert_true 'confirm re-asks after invalid' quiet ui_confirm main.version 1 <<<$'yes\ny'
assert_false 'confirm does not accept yes' quiet ui_confirm main.version 1 <<<$'yes\n'

assert_true 'exact confirmation' ui_confirm_exact 'ELIMINA ubuntu' main.version 1 <<<'ELIMINA ubuntu'
assert_false 'exact confirmation is case sensitive' ui_confirm_exact 'ELIMINA ubuntu' main.version 1 <<<'elimina ubuntu'

answer=''
ui_prompt answer main.version 1 <<<'  spaced value '
assert_eq 'prompt keeps spaces' '  spaced value ' "$answer"
assert_rc 'prompt EOF returns 1' 1 ui_prompt answer main.version 1 </dev/null

# Menu: 1-based input, 0-based result; 0/empty/EOF go back; invalid re-asks.
items=(alpha beta gamma)
choice=''
ui_menu choice main.version items >/dev/null <<<'2'
assert_eq 'menu returns index' 1 "$choice"
ui_menu choice main.version items >/dev/null 2>&1 <<<$'7\nx\n3'
assert_eq 'menu re-asks after invalid input' 2 "$choice"
assert_rc 'menu 0 goes back' 1 quiet ui_menu choice main.version items <<<'0'
assert_rc 'menu empty goes back' 1 quiet ui_menu choice main.version items <<<''

# Checklist (numeric fallback, stdin is not a terminal).
labels=(one two three)
selected=(1 0 0)
ui_checklist main.version labels selected >/dev/null <<<$'2 3\n1\n'
assert_eq 'checklist toggles and confirms' '0 1 1' "${selected[*]}"
selected=(1 0 0)
ui_checklist main.version labels selected >/dev/null 2>&1 <<<$'9\n2\n'
assert_eq 'checklist ignores invalid batch' '1 1 0' "${selected[*]}"
assert_rc 'checklist q cancels' 1 quiet ui_checklist main.version labels selected <<<'q'
empty=(); empty_sel=()
assert_rc 'checklist with no items cancels' 1 ui_checklist main.version empty empty_sel </dev/null

assert_eq 'pager falls back to cat' 'text' "$(printf 'text' | ui_pager)"

DISCLAIMER_ACCEPTED=0
assert_false 'disclaimer refused without space' quiet ui_disclaimer <<<'y'
assert_true 'disclaimer accepted with space' quiet ui_disclaimer <<<' '
assert_true 'disclaimer asked once' ui_disclaimer </dev/null

assert_contains 'warn goes to stderr with label' 'AVVISO: JackTools 1' "$(ui_warn main.version 1 2>&1 >/dev/null)"
assert_contains 'header shows source' 'Sorgente: gitea' "$(JACKTOOLS_SOURCE=gitea ui_header)"
prompt=''; ui_prompt prompt main.version 1 <<<'value'
assert_eq 'prompt works with caller variable named prompt' value "$prompt"
path=''; fs_mktemp path
assert_true 'fs_mktemp works with caller variable named path' test -f "$path"
finish_tests
