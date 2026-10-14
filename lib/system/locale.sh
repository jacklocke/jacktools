#!/usr/bin/env bash
# Step "locale": system-wide LANG in /etc/default/locale (UTF-8 only).
# Without a UTF-8 locale tmux replaces powerline glyphs with "_".
set -Eeuo pipefail

LOCALE_CHOICES=(C.UTF-8 it_IT.UTF-8 en_US.UTF-8)
# Menu labels, same order as LOCALE_CHOICES: the operator sees what each code means.
LOCALE_CHOICE_KEYS=(locale.choice.c locale.choice.it locale.choice.en)

locale_current() {
    local file line value=''
    file=$(root_path /etc/default/locale)
    if [[ -r "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^LANG=\"?([^\"]*)\"?$ ]] && value="${BASH_REMATCH[1]}"
        done <"$file"
    fi
    printf '%s' "$value"
}

# Compare locale names the way glibc does: case-insensitive, "utf8" == "UTF-8".
locale_normalize() {
    local name="${1,,}"
    printf '%s' "${name//utf-8/utf8}"
}

locale_available() {
    local wanted name
    wanted=$(locale_normalize "$1")
    locale -a 2>/dev/null | while IFS= read -r name; do locale_normalize "$name"; printf '\n'; done |
        grep -Fxq -- "$wanted"
}

locale_collect() {
    local -a items=()
    local current choice answer name
    # msg-keys: locale.choice.c locale.choice.it locale.choice.en
    current=$(locale_current)
    msg locale.current "${current:-$(msg_get locale.unset)}"
    for name in "${LOCALE_CHOICE_KEYS[@]}"; do items+=("$(msg_get "$name")"); done
    items+=("$(msg_get locale.other)")
    ui_menu choice locale.menu.title items ui.menu.cancel || return 1
    if (( choice < ${#LOCALE_CHOICES[@]} )); then
        CFG[LOCALE]="${LOCALE_CHOICES[$choice]}"
        return 0
    fi
    while true; do
        ui_prompt answer locale.prompt || return 1
        [[ -n "$answer" ]] || return 1
        if valid_locale "$answer"; then CFG[LOCALE]="$answer"; return 0; fi
        ui_warn locale.invalid
    done
}

locale_plan() {
    local current
    current=$(locale_current)
    if [[ "$current" == "${CFG[LOCALE]}" ]]; then
        msg steps.plan.compliant
        return 0
    fi
    msg locale.plan "${current:-$(msg_get locale.unset)}" "${CFG[LOCALE]}"
    locale_available "${CFG[LOCALE]}" || msg locale.plan_generate "${CFG[LOCALE]}"
}

# /etc/default/locale rendered directly (same result as update-locale, but testable).
locale_render() {
    awk -v value="$2" '
        /^LANG=/ { if (!done) print "LANG=" value; done = 1; next }
        { print }
        END { if (!done) print "LANG=" value }
    ' "$1" >"$3"
}

locale_apply() {
    local file candidate
    [[ "$(locale_current)" == "${CFG[LOCALE]}" ]] && return 0
    if ! locale_available "${CFG[LOCALE]}"; then
        command_exists locale-gen || { ui_error locale.no_locale_gen; return 1; }
        run locale-gen "${CFG[LOCALE]}" || { ui_error locale.generate_failed "${CFG[LOCALE]}"; return 1; }
    fi
    file=$(root_path /etc/default/locale)
    [[ -e "$file" ]] || touch "$file" || return 1
    fs_mktemp candidate
    locale_render "$file" "${CFG[LOCALE]}" "$candidate" || return 1
    backup_file "$file" default-locale >/dev/null || return 1
    atomic_install "$candidate" "$file" 0644 || return 1
    state_flag NEW_SHELL
}

locale_verify() { [[ "$(locale_current)" == "${CFG[LOCALE]}" ]]; }

step_register locale step.locale system 1
