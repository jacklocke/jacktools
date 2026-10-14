#!/usr/bin/env bash
# The only user-interface layer: every prompt, menu and checklist goes through here.
# Functions take message keys, never literal text; item labels are already-rendered strings.
set -Eeuo pipefail

if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'
    BLINK=$'\033[5m'; REVERSE=$'\033[7m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; BLINK=''; REVERSE=''; RESET=''
fi

: "${DISCLAIMER_ACCEPTED:=0}"

ui_is_interactive() { [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]]; }

ui_info() {
    local text
    text=$(msg_get "$@")
    printf '%s%s%s: %s\n' "$GREEN" "$(msg_get ui.label.info)" "$RESET" "$text"
    log_write INFO "$text"
}

ui_warn() {
    local text
    text=$(msg_get "$@")
    printf '%s%s%s: %s\n' "$YELLOW" "$(msg_get ui.label.warn)" "$RESET" "$text" >&2
    log_write WARN "$text"
}

ui_error() {
    local text
    text=$(msg_get "$@")
    printf '%s%s%s: %s\n' "$RED" "$(msg_get ui.label.error)" "$RESET" "$text" >&2
    log_write ERROR "$text"
}

die() {
    ui_error "$@"
    exit 1
}

ui_title() { printf '\n%s%s%s\n' "$BOLD" "$(msg_get "$@")" "$RESET"; }

ui_separator() { printf '\n%s%s%s\n\n' "$YELLOW" '------------------------------------------------------------' "$RESET"; }

# ui_prompt RESULT_VAR KEY [ARGS...]: free text; returns 1 on EOF.
ui_prompt() {
    local -n ui_prompt_result="$1"
    IFS= read -r -p "$(msg_get "${@:2}") " ui_prompt_result || return 1
}

# ui_prompt_secret RESULT_VAR KEY [ARGS...]: like ui_prompt without echo.
ui_prompt_secret() {
    local -n ui_secret_result="$1"
    local ui_secret_rc=0
    IFS= read -r -s -p "$(msg_get "${@:2}") " ui_secret_result || ui_secret_rc=1
    printf '\n'
    return "$ui_secret_rc"
}

# ui_confirm KEY [ARGS...]: Y/y confirms; N/n, empty input or EOF decline.
ui_confirm() {
    local prompt answer
    prompt="$(msg_get "$@") $(msg_get ui.confirm.suffix)"
    while true; do
        IFS= read -r -p "$prompt " answer || return 1
        case "$answer" in
            Y|y) return 0 ;;
            N|n|'') return 1 ;;
            *) ui_warn ui.confirm.invalid ;;
        esac
    done
}

# ui_confirm_exact EXPECTED KEY [ARGS...]: the operator must type EXPECTED verbatim.
ui_confirm_exact() {
    local expected="$1" prompt answer
    prompt="$(msg_get "${@:2}") $(msg_get ui.confirm_exact.suffix "$expected")"
    IFS= read -r -p "$prompt " answer || return 1
    [[ "$answer" == "$expected" ]]
}

# ui_menu RESULT_VAR TITLE_KEY ITEMS_ARRAY [BACK_KEY] [DEFAULT_INDEX]
# Numbered menu; stores the 0-based index of the choice. Returns 1 for back/EOF, and for
# empty input unless DEFAULT_INDEX is given (empty input then selects it).
ui_menu() {
    local -n ui_menu_result="$1"
    local -n ui_menu_items="$3"
    local ui_menu_title="$2" ui_menu_back="${4:-ui.menu.back}" ui_menu_default="${5:-}" ui_menu_choice ui_menu_i
    local ui_menu_prompt
    while true; do
        ui_title "$ui_menu_title"
        for ui_menu_i in "${!ui_menu_items[@]}"; do
            printf '%s%2d.%s %s\n' "$GREEN" "$((ui_menu_i + 1))" "$RESET" "${ui_menu_items[$ui_menu_i]}"
        done
        printf '%s%2d.%s %s\n' "$GREEN" 0 "$RESET" "$(msg_get "$ui_menu_back")"
        if [[ -n "$ui_menu_default" ]]; then
            ui_menu_prompt=$(msg_get ui.menu.prompt_default "${ui_menu_items[$ui_menu_default]}")
        else
            ui_menu_prompt=$(msg_get ui.menu.prompt)
        fi
        IFS= read -r -p "$ui_menu_prompt " ui_menu_choice || return 1
        if [[ -z "$ui_menu_choice" && -n "$ui_menu_default" ]]; then
            ui_menu_result="$ui_menu_default"
            return 0
        fi
        case "$ui_menu_choice" in
            ''|0) return 1 ;;
        esac
        if [[ "$ui_menu_choice" =~ ^[1-9][0-9]*$ ]] && (( ui_menu_choice <= ${#ui_menu_items[@]} )); then
            ui_menu_result=$((ui_menu_choice - 1))
            return 0
        fi
        ui_warn ui.menu.invalid
    done
}

# ui_checklist TITLE_KEY LABELS_ARRAY SELECTED_ARRAY [TITLE_ARGS...]
# SELECTED holds 1/0 per label and is updated in place. Returns 0 on confirm, 1 on cancel.
ui_checklist() {
    if ui_is_interactive; then
        ui_checklist_interactive "$@"
    else
        ui_checklist_numeric "$@"
    fi
}

ui_checkbox() { [[ "$1" == 1 ]] && printf 'x' || printf ' '; }

ui_checklist_interactive() {
    local -n ui_cl_labels="$2"
    local -n ui_cl_selected="$3"
    local -a ui_cl_title_args=("${@:4}")
    local ui_cl_title="$1" ui_cl_current=0 ui_cl_count=${#ui_cl_labels[@]} ui_cl_key ui_cl_rest ui_cl_i ui_cl_all
    (( ui_cl_count > 0 )) || return 1
    while true; do
        printf '\033[H\033[2J%s%s%s\n%s\n\n' "$BOLD" "$(msg_get "$ui_cl_title" "${ui_cl_title_args[@]}")" "$RESET" "$(msg_get ui.checklist.help)"
        for ui_cl_i in "${!ui_cl_labels[@]}"; do
            (( ui_cl_i == ui_cl_current )) && printf '%s' "$REVERSE"
            printf '[%s] %s%s\n' "$(ui_checkbox "${ui_cl_selected[$ui_cl_i]}")" "${ui_cl_labels[$ui_cl_i]}" "$RESET"
        done
        IFS= read -rsn1 ui_cl_key || return 1
        case "$ui_cl_key" in
            '') return 0 ;;
            ' ') ui_cl_selected[ui_cl_current]=$((1 - ui_cl_selected[ui_cl_current])) ;;
            k) ui_cl_current=$(((ui_cl_current - 1 + ui_cl_count) % ui_cl_count)) ;;
            j) ui_cl_current=$(((ui_cl_current + 1) % ui_cl_count)) ;;
            a)
                ui_cl_all=1
                for ui_cl_i in "${!ui_cl_selected[@]}"; do [[ ${ui_cl_selected[$ui_cl_i]} == 1 ]] || ui_cl_all=0; done
                for ui_cl_i in "${!ui_cl_selected[@]}"; do ui_cl_selected[ui_cl_i]=$((1 - ui_cl_all)); done
                ;;
            q) return 1 ;;
            $'\e')
                if IFS= read -rsn2 -t 0.15 ui_cl_rest; then
                    case "$ui_cl_rest" in
                        '[A') ui_cl_current=$(((ui_cl_current - 1 + ui_cl_count) % ui_cl_count)) ;;
                        '[B') ui_cl_current=$(((ui_cl_current + 1) % ui_cl_count)) ;;
                    esac
                else
                    return 1
                fi
                ;;
        esac
    done
}

# Fallback for non-interactive terminals: numbers toggle items, empty input confirms.
ui_checklist_numeric() {
    local -n ui_cn_labels="$2"
    local -n ui_cn_selected="$3"
    local -a ui_cn_title_args=("${@:4}")
    local ui_cn_title="$1" ui_cn_count=${#ui_cn_labels[@]} ui_cn_input ui_cn_token ui_cn_i ui_cn_valid
    local -a ui_cn_tokens
    (( ui_cn_count > 0 )) || return 1
    while true; do
        ui_title "$ui_cn_title" "${ui_cn_title_args[@]}"
        for ui_cn_i in "${!ui_cn_labels[@]}"; do
            printf '%2d. [%s] %s\n' "$((ui_cn_i + 1))" "$(ui_checkbox "${ui_cn_selected[$ui_cn_i]}")" "${ui_cn_labels[$ui_cn_i]}"
        done
        IFS= read -r -p "$(msg_get ui.checklist.numeric_prompt) " ui_cn_input || return 1
        [[ -n "$ui_cn_input" ]] || return 0
        [[ "$ui_cn_input" != q ]] || return 1
        read -r -a ui_cn_tokens <<<"$ui_cn_input"
        ui_cn_valid=1
        for ui_cn_token in "${ui_cn_tokens[@]}"; do
            [[ "$ui_cn_token" =~ ^[1-9][0-9]*$ ]] && (( ui_cn_token <= ui_cn_count )) || ui_cn_valid=0
        done
        if (( ! ui_cn_valid )); then
            ui_warn ui.checklist.invalid "$ui_cn_count"
            continue
        fi
        for ui_cn_token in "${ui_cn_tokens[@]}"; do
            ui_cn_i=$((ui_cn_token - 1))
            ui_cn_selected[ui_cn_i]=$((1 - ui_cn_selected[ui_cn_i]))
        done
    done
}

# ui_pager: page stdin with less on a terminal, plain output otherwise.
ui_pager() {
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
        less -R
    else
        cat
    fi
}

# ui_print_file FILE: print a text asset verbatim, preserving spacing.
ui_print_file() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done <"$1"
}

ui_header() {
    local header="$JACKTOOLS_DIR/assets/header.txt"
    printf '%s' "$BOLD"
    if [[ -r "$header" ]]; then ui_print_file "$header"; else printf '=== JackTools ===\n'; fi
    printf '%s' "$RESET"
    msg ui.header.version "${JACKTOOLS_VERSION:-?}"
    [[ -z ${JACKTOOLS_SOURCE:-} ]] || msg ui.header.source "$JACKTOOLS_SOURCE"
    (( ${JACKTOOLS_DRY_RUN:-0} )) && msg ui.header.dry_run
    return 0
}

# ui_disclaimer: shown once per run; accepted only with SPACE followed by Enter.
ui_disclaimer() {
    local answer disclaimer="$JACKTOOLS_DIR/assets/disclaimer.txt"
    (( DISCLAIMER_ACCEPTED )) && return 0
    ui_header
    printf '\n%s%s%s%s%s\n' "$RED" "$BOLD" "$BLINK" "$(msg_get ui.disclaimer.title)" "$RESET"
    [[ -r "$disclaimer" ]] || { ui_error ui.disclaimer.missing; return 1; }
    ui_print_file "$disclaimer"
    printf '\n'
    IFS= read -r -p "$(msg_get ui.disclaimer.prompt) " answer || return 1
    if [[ "$answer" != ' ' ]]; then
        ui_warn ui.disclaimer.declined
        return 1
    fi
    DISCLAIMER_ACCEPTED=1
}
