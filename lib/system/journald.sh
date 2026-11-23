#!/usr/bin/env bash
# Step "journald": cap the systemd journal size and enable logrotate compression.
set -Eeuo pipefail

JOURNALD_DROPIN="/etc/systemd/journald.conf.d/99-jacktools.conf"
JOURNALD_DEFAULT_MAX="200M"

valid_journal_size() { [[ "$1" =~ ^[1-9][0-9]{0,5}[MG]$ ]]; }

journald_render() { printf '# Managed by JackTools.\n[Journal]\nSystemMaxUse=%s\n' "${CFG[JOURNAL_MAX]}"; }

journald_dropin_ok() { fs_file_matches "$(root_path "$JOURNALD_DROPIN")" journald_render; }

logrotate_compress_enabled() { grep -Eq '^[[:space:]]*compress[[:space:]]*$' "$(root_path /etc/logrotate.conf)" 2>/dev/null; }

journald_collect() {
    ui_ask 'CFG[JOURNAL_MAX]' --default "$JOURNALD_DEFAULT_MAX" --upper valid_journal_size journald.invalid \
        journald.prompt "$JOURNALD_DEFAULT_MAX" || return 1
    CFG[LOGROTATE_COMPRESS]=keep
    if [[ -f "$(root_path /etc/logrotate.conf)" ]] && ! logrotate_compress_enabled; then
        ui_confirm journald.compress_confirm && CFG[LOGROTATE_COMPRESS]=on
    fi
    return 0
}

journald_plan() {
    local changes=0
    if ! journald_dropin_ok; then msg journald.plan_max "${CFG[JOURNAL_MAX]}" "$JOURNALD_DROPIN"; changes=1; fi
    if [[ "${CFG[LOGROTATE_COMPRESS]}" == on ]] && ! logrotate_compress_enabled; then msg journald.plan_compress; changes=1; fi
    (( changes )) || msg steps.plan.compliant
}

# logrotate_render SOURCE: uncomment "#compress" when present, otherwise add "compress"
# before the first include.
logrotate_render() {
    awk '
        !done && /^[[:space:]]*#[[:space:]]*compress[[:space:]]*$/ { print "compress"; done = 1; next }
        !done && /^[[:space:]]*include[[:space:]]/ { print "compress"; done = 1 }
        { print }
        END { if (!done) print "compress" }
    ' "$1"
}

journald_apply() {
    local conf
    if ! journald_dropin_ok; then
        fs_write_managed "$(root_path "$JOURNALD_DROPIN")" journald-dropin 0644 journald_render || return 1
        run systemctl restart systemd-journald || return 1
        run journalctl --vacuum-size="${CFG[JOURNAL_MAX]}" >/dev/null || ui_warn journald.vacuum_failed
    fi
    if [[ "${CFG[LOGROTATE_COMPRESS]}" == on ]] && ! logrotate_compress_enabled; then
        conf=$(root_path /etc/logrotate.conf)
        fs_write_managed "$conf" logrotate-conf 0644 logrotate_render "$conf" || return 1
    fi
    return 0
}

journald_verify() {
    journald_dropin_ok || return 1
    [[ "${CFG[LOGROTATE_COMPRESS]}" != on ]] || logrotate_compress_enabled
}

step_register journald step.journald system 1
