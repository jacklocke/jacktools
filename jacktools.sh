#!/usr/bin/env bash
set -Eeuo pipefail

readonly JACKTOOLS_VERSION="2.0.0-dev"
JACKTOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly JACKTOOLS_DIR

# Load order matters: core first, then steps in the order they run inside each phase.
JACKTOOLS_LIBRARIES=(
    core/log core/msg core/ui core/exec core/fs core/validate core/state core/env core/steps core/cleanup core/config
    system/hostname system/locale system/time system/network system/swap system/journald system/motd
    install/apt install/docker install/unattended
    users/account users/admin users/powerline_theme users/customize users/remove_ubuntu
    security/ssh security/ufw security/fail2ban
    maint/status maint/fail2ban maint/users maint/firewall maint/ssh maint/docker maint/export maint/menu
)
for library in "${JACKTOOLS_LIBRARIES[@]}"; do
    # shellcheck source=/dev/null # Paths are resolved at runtime from JACKTOOLS_DIR.
    source "$JACKTOOLS_DIR/lib/$library.sh"
done

readonly DEFAULT_LANG="it"
# Phase commands and other commands; steps registered by the libraries are commands too.
readonly PHASE_COMMANDS=" system install users security "
# Phases of the full configuration, in execution order.
readonly FULL_PHASES="system install users security final"

MAIN_COMMAND=""
MAIN_LANG="${JT_LANG:-}"
MAIN_CONFIG_FILE=""

# Load the requested catalog, falling back to the default language.
main_load_messages() {
    local requested="${MAIN_LANG:-$DEFAULT_LANG}" rc=0
    msg_load "$requested" || rc=$?
    (( rc == 0 )) && return 0
    if [[ "$requested" != "$DEFAULT_LANG" ]] && msg_load "$DEFAULT_LANG"; then
        ui_warn main.lang_fallback "$requested" "$DEFAULT_LANG"
        return 0
    fi
    # Without a catalog there is no text to show: this is the only hardcoded message.
    printf 'JackTools: message catalog "%s" not available.\n' "$requested" >&2
    exit 1
}

# Language must be known before any message, so --lang is read in a first pass.
main_prescan_lang() {
    while (( $# > 0 )); do
        case "$1" in
            --lang) MAIN_LANG="${2:-}"; shift 2 || shift ;;
            --lang=*) MAIN_LANG="${1#--lang=}"; shift ;;
            *) shift ;;
        esac
    done
}

main_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) JACKTOOLS_DRY_RUN=1 ;;
            --yes) JT_ASSUME_YES=1 ;;
            --config)
                (( $# >= 2 )) || die main.option_needs_value "$1"
                MAIN_CONFIG_FILE="$2"
                shift
                ;;
            --config=*) MAIN_CONFIG_FILE="${1#--config=}" ;;
            --lang)
                (( $# >= 2 )) || die main.option_needs_value "$1"
                shift
                ;;
            --lang=*) ;;
            -h|--help|help) MAIN_COMMAND=help ;;
            --version|version) MAIN_COMMAND=version ;;
            -*) die main.unknown_option "$1" ;;
            *)
                [[ -z "$MAIN_COMMAND" ]] || die main.too_many_commands "$1"
                MAIN_COMMAND="$1"
                ;;
        esac
        shift
    done
    MAIN_COMMAND="${MAIN_COMMAND:-menu}"
}

main_is_known_command() {
    [[ " menu all cleanup maintenance status " == *" $1 "* || "$PHASE_COMMANDS" == *" $1 "* ]] || step_exists "$1"
}

# run_all: every phase in order with one checklist, one plan and one confirmation;
# with --config the steps listed in the file. Cleanup is offered at the end (interactive only).
run_all() {
    local -a ids=() phase_ids
    local phase rc=0
    if [[ "$JT_CONFIG_MODE" == 1 ]]; then
        # shellcheck disable=SC2086 # STEPS is a validated space-separated list.
        steps_ordered ids ${CFG[STEPS]}
    else
        for phase in $FULL_PHASES; do
            steps_of_phase "$phase" phase_ids
            ids+=("${phase_ids[@]}")
        done
    fi
    steps_run ids select || rc=1
    if [[ "$JT_CONFIG_MODE" != 1 && "$JACKTOOLS_DRY_RUN" != 1 ]]; then cleanup_run || rc=1; fi
    return "$rc"
}

# phase_menu PHASE TITLE_KEY ALL_KEY [EXTRA_PHASE]: whole phase or one of its steps;
# steps of EXTRA_PHASE are listed as single items but are not part of "whole phase".
phase_menu() {
    local -a items=("$(msg_get "$3")") ids extra_ids=()
    local choice id
    steps_of_phase "$1" ids
    [[ -z "${4:-}" ]] || steps_of_phase "$4" extra_ids
    ids+=("${extra_ids[@]}")
    for id in "${ids[@]}"; do items+=("$(step_label "$id")"); done
    while ui_menu choice "$2" items; do
        if (( choice == 0 )); then run_phase "$1" || true; else run_single_step "${ids[$((choice - 1))]}" || true; fi
    done
    return 0
}

main_menu() {
    local -a items=(
        "$(msg_get main.menu.full)" "$(msg_get main.menu.system)" "$(msg_get main.menu.install)"
        "$(msg_get main.menu.users)" "$(msg_get main.menu.security)" "$(msg_get main.menu.maintenance)"
        "$(msg_get main.menu.cleanup)"
    )
    local choice
    while ui_menu choice main.menu.title items main.menu.exit; do
        case "$choice" in
            0) run_all || true ;;
            1) phase_menu system main.system.title main.system.all ;;
            2) phase_menu install main.install.title main.install.all ;;
            3) phase_menu users main.users.title main.users.all final ;;
            4) phase_menu security main.security.title main.security.all ;;
            5) maintenance_menu ;;
            6) cleanup_run || true; return 0 ;;
        esac
    done
    return 0
}

main_dispatch() {
    case "$MAIN_COMMAND" in
        menu) main_menu ;;
        all) run_all ;;
        cleanup) cleanup_run ;;
        maintenance) maintenance_menu ;;
        status) status_report ;;
        system|install|users|security) run_phase "$MAIN_COMMAND" ;;
        *) run_single_step "$MAIN_COMMAND" ;;
    esac
}

main() {
    local rc=0
    main_prescan_lang "$@"
    main_load_messages
    main_parse_args "$@"
    case "$MAIN_COMMAND" in
        help) msg main.usage; return 0 ;;
        version) msg main.version "$JACKTOOLS_VERSION"; return 0 ;;
    esac
    main_is_known_command "$MAIN_COMMAND" || { msg main.usage >&2; die main.unknown_command "$MAIN_COMMAND"; }
    if [[ -n "$MAIN_CONFIG_FILE" ]]; then
        [[ "$MAIN_COMMAND" == all || "$MAIN_COMMAND" == menu ]] || die main.config_needs_all
        MAIN_COMMAND=all
        JT_CONFIG_MODE=1
    fi
    [[ "$JT_ASSUME_YES" != 1 || "$JT_CONFIG_MODE" == 1 ]] || die main.yes_needs_config

    core_install_traps
    env_detect
    preflight_base || exit 1
    log_write INFO "JackTools $JACKTOOLS_VERSION, source: ${JACKTOOLS_SOURCE:-local}"
    if [[ "$JT_CONFIG_MODE" == 1 ]]; then config_load "$MAIN_CONFIG_FILE" || exit 1; fi
    # The read-only status report needs no disclaimer; --yes accepts it explicitly.
    if [[ "$MAIN_COMMAND" != status && "$JT_ASSUME_YES" != 1 ]]; then ui_disclaimer || return 0; fi
    main_dispatch || rc=1
    if (( ${#STATE_ORDER[@]} > 0 )); then print_summary || rc=1; fi
    return "$rc"
}

main "$@"
