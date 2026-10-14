#!/usr/bin/env bash
# Step "motd": silence Ubuntu news, help text and Pro/ESM advertising at login.
# Scripts are only made non-executable (chmod -x), so the change is easy to revert.
set -Eeuo pipefail

MOTD_NOISY_SCRIPTS=(10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status)

# Noisy scripts that exist and are still executable.
motd_active_scripts() {
    local name path
    for name in "${MOTD_NOISY_SCRIPTS[@]}"; do
        path="$(root_path /etc/update-motd.d)/$name"
        [[ -f "$path" && -x "$path" ]] && printf '%s\n' "$name"
    done
    return 0
}

motd_news_file() { root_path /etc/default/motd-news; }

motd_news_enabled() { [[ -f "$(motd_news_file)" ]] && ! grep -Eq '^ENABLED=0$' "$(motd_news_file)"; }

motd_compliant() { [[ -z "$(motd_active_scripts)" ]] && ! motd_news_enabled; }

motd_collect() {
    ui_confirm motd.confirm || return 1
    CFG[MOTD_CLEAN]=yes
}

motd_plan() {
    local name
    if motd_compliant; then msg steps.plan.compliant; return 0; fi
    motd_news_enabled && msg motd.plan_news
    while IFS= read -r name; do [[ -n "$name" ]] && msg motd.plan_script "$name"; done < <(motd_active_scripts)
    return 0
}

motd_apply() {
    local name file candidate
    if motd_news_enabled; then
        file=$(motd_news_file)
        fs_mktemp candidate
        sed -E 's/^ENABLED=.*/ENABLED=0/' "$file" >"$candidate" || return 1
        grep -q '^ENABLED=0$' "$candidate" || printf 'ENABLED=0\n' >>"$candidate"
        backup_file "$file" motd-news >/dev/null || return 1
        atomic_install "$candidate" "$file" 0644 || return 1
        run systemctl disable --now motd-news.timer >/dev/null 2>&1 || ui_warn motd.timer_failed
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ "$JACKTOOLS_DRY_RUN" != 1 ]]; then chmod a-x -- "$(root_path /etc/update-motd.d)/$name" || return 1; fi
        log_write INFO "motd script disabled: $name"
    done < <(motd_active_scripts)
    if command_exists pro; then run pro config set apt_news=false >/dev/null 2>&1 || ui_warn motd.pro_failed; fi
    return 0
}

motd_verify() { motd_compliant; }

step_register motd step.motd system 1
