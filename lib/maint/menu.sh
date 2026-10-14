#!/usr/bin/env bash
# Maintenance submenu.
set -Eeuo pipefail

# maint_do ACTION [ARGS...]: run one menu action; a failure is reported and the operator
# goes back to the menu instead of leaving JackTools.
maint_do() {
    "$@" && return 0
    ui_warn maint.action_failed
    return 0
}

maintenance_menu() {
    local choice
    local -a items=(
        "$(msg_get maint.menu.status)" "$(msg_get maint.menu.updates)" "$(msg_get maint.menu.fail2ban)"
        "$(msg_get maint.menu.users)" "$(msg_get maint.menu.firewall)" "$(msg_get maint.menu.ssh)"
        "$(msg_get maint.menu.docker)" "$(msg_get maint.menu.export)"
    )
    while ui_menu choice maint.menu.title items; do
        case "$choice" in
            0) maint_do status_report ;;
            1) maint_do run_single_step upgrade ;;
            2) maint_do maint_f2b_menu ;;
            3) maint_do maint_users_menu ;;
            4) maint_do maint_fw_menu ;;
            5) maint_do maint_ssh_menu ;;
            6) maint_do maint_docker_menu ;;
            7) maint_do export_run ;;
        esac
    done
    return 0
}
