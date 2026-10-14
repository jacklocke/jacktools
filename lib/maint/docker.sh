#!/usr/bin/env bash
# Maintenance: Docker disk cleanup (with preview) and container logs.
set -Eeuo pipefail

# Read-only docker queries (replaced in tests).
docker_query() { docker "$@" 2>/dev/null; }

maint_docker_available() {
    command_exists docker && docker_query info >/dev/null && return 0
    ui_warn maint.docker.unavailable
    return 1
}

maint_docker_prune() {
    local choice
    local -a modes args=(system prune -f)
    maint_docker_available || return 0
    ui_title maint.docker.usage
    docker_query system df
    modes=("$(msg_get maint.docker.prune_basic)" "$(msg_get maint.docker.prune_all)")
    ui_menu choice maint.docker.prune_title modes || return 0
    (( choice == 1 )) && args+=(-a)
    if ui_confirm maint.docker.confirm_volumes; then
        ui_warn maint.docker.volumes_warning
        args+=(--volumes)
    fi
    ui_confirm maint.docker.confirm_prune "docker ${args[*]}" || return 0
    run docker "${args[@]}"
}

maint_docker_logs() {
    local choice
    local -a names labels
    maint_docker_available || return 0
    mapfile -t names < <(docker_query ps -a --format '{{.Names}}')
    if (( ${#names[@]} == 0 )); then ui_info maint.docker.no_containers; return 0; fi
    mapfile -t labels < <(docker_query ps -a --format '{{.Names}}  ({{.Status}})')
    ui_menu choice maint.docker.logs_title labels || return 0
    docker_query logs --tail 200 --timestamps "${names[$choice]}" 2>&1 | ui_pager
}

maint_docker_menu() {
    local choice
    local -a items=("$(msg_get maint.docker.prune)" "$(msg_get maint.docker.logs)")
    while ui_menu choice maint.docker.title items; do
        case "$choice" in
            0) maint_do maint_docker_prune ;;
            1) maint_do maint_docker_logs ;;
        esac
    done
    return 0
}
