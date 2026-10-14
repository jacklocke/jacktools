#!/usr/bin/env bash
# Maintenance: read-only status report.
set -Eeuo pipefail

# State of a systemd unit, "inactive" when unknown (replaced in tests).
status_service_state() { systemctl is-active "$1" 2>/dev/null || true; }

# Upgradable packages according to the current APT lists (no update is run).
status_upgradable_count() { apt list --upgradable 2>/dev/null | grep -c 'upgradable' || true; }

status_line() { printf '  %-26s %s\n' "$(msg_get "$1")" "$2"; }

status_report() {
    local service state banned=0 jail
    ui_title maint.status.title
    status_line maint.status.host "$(hostname_current)"
    status_line maint.status.os "${ENV_OS_PRETTY:-?}"
    status_line maint.status.kernel "$(uname -r)"
    status_line maint.status.virt "$ENV_VIRT"
    status_line maint.status.uptime "$(uptime -p 2>/dev/null || true)"
    status_line maint.status.load "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)"
    status_line maint.status.memory "$(free -h 2>/dev/null | awk '/^Mem:/ { print $3 " / " $2 }')"
    status_line maint.status.swap "$(free -h 2>/dev/null | awk '/^Swap:/ { print $3 " / " $2 }')"
    status_line maint.status.disk "$(df -h / 2>/dev/null | awk 'NR == 2 { print $3 " / " $2 " (" $5 ")" }')"

    ui_title maint.status.services
    for service in "$(ssh_service_name)" ufw fail2ban docker unattended-upgrades; do
        state=$(status_service_state "$service")
        status_line maint.status.service "$service: ${state:-inactive}"
    done
    if command_exists ufw; then
        if ufw_active; then status_line maint.status.firewall "$(msg_get maint.status.active)"
        else status_line maint.status.firewall "$(msg_get maint.status.inactive)"; fi
    fi
    if command_exists fail2ban-client && [[ "$(status_service_state fail2ban)" == active ]]; then
        for jail in $(f2b_jails); do banned=$(( banned + $(f2b_banned "$jail" | wc -w) )); done
        status_line maint.status.banned "$banned"
    fi

    ui_title maint.status.updates
    status_line maint.status.upgradable "$(status_upgradable_count)"
    if apt_reboot_required; then status_line maint.status.reboot "$(msg_get maint.status.yes)"
    else status_line maint.status.reboot "$(msg_get maint.status.no)"; fi
    return 0
}
