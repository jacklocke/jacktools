#!/usr/bin/env bash
# Step "remove_ubuntu": delete the default "ubuntu" account, only when another verified
# administrator can still log in. Runs last (phase "final"), after the security phase.
set -Eeuo pipefail

REMOVE_TARGET="ubuntu"
REMOVE_PHRASE="ELIMINA ubuntu"

# Another account in the sudo group with a key or password, allowed by the SSH policy.
remove_safe_admin() {
    local candidate
    local -a candidates=()
    [[ -n "${CFG[ADMIN_USER]:-}" ]] && candidates+=("${CFG[ADMIN_USER]}")
    mapfile -t -O "${#candidates[@]}" candidates < <(users_discover)
    for candidate in "${candidates[@]}"; do
        [[ "$candidate" != "$REMOVE_TARGET" ]] || continue
        if ! user_exists "$candidate" || ! user_in_group "$candidate" sudo; then continue; fi
        { user_has_key "$candidate" || [[ "$(user_password_state "$candidate")" == P ]]; } || continue
        ssh_user_permitted "$candidate" || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

remove_session_is_target() { [[ "$ENV_OPERATOR" == "$REMOVE_TARGET" || "${USER:-}" == "$REMOVE_TARGET" ]]; }

remove_ubuntu_collect() {
    local admin
    if ! user_exists "$REMOVE_TARGET"; then ui_info remove.absent; return 1; fi
    if remove_session_is_target; then ui_error remove.own_session; return 1; fi
    # The admin created in this run is checked again at apply time, when it exists.
    if ! admin=$(remove_safe_admin) && [[ -z "${CFG[ADMIN_USER]:-}" ]]; then ui_error remove.no_admin; return 1; fi
    [[ -n "$admin" ]] && msg remove.admin_found "$admin"
    ui_warn remove.warning
    ui_confirm_exact "$REMOVE_PHRASE" remove.confirm || return 1
    CFG[REMOVE_HOME]=no
    CFG[REMOVE_MAIL]=no
    ui_confirm remove.confirm_home && CFG[REMOVE_HOME]=yes
    ui_confirm remove.confirm_mail && CFG[REMOVE_MAIL]=yes
    return 0
}

remove_ubuntu_plan() {
    msg remove.plan "$REMOVE_TARGET"
    [[ "${CFG[REMOVE_HOME]}" == yes ]] && msg remove.plan_home
    [[ "${CFG[REMOVE_MAIL]}" == yes ]] && msg remove.plan_mail
    return 0
}

remove_ubuntu_apply() {
    local admin external
    user_exists "$REMOVE_TARGET" || return 0
    remove_session_is_target && { ui_error remove.own_session; return 1; }
    admin=$(remove_safe_admin) || { ui_error remove.no_admin; return 1; }
    log_write INFO "removing $REMOVE_TARGET, verified admin: $admin"
    external=$(find "$(root_path /)" -xdev -user "$REMOVE_TARGET" -not -path "$(user_home "$REMOVE_TARGET")" \
        -not -path "$(user_home "$REMOVE_TARGET")/*" 2>/dev/null | wc -l || true)
    (( external > 0 )) && ui_warn remove.external_files "$external"
    if [[ "${CFG[REMOVE_HOME]}" == yes ]]; then run userdel --remove "$REMOVE_TARGET" || return 1
    else run userdel "$REMOVE_TARGET" || return 1; fi
    if [[ "${CFG[REMOVE_MAIL]}" == yes && -e "$(root_path "/var/mail/$REMOVE_TARGET")" ]]; then
        run rm -f -- "$(root_path "/var/mail/$REMOVE_TARGET")" || return 1
    fi
    return 0
}

remove_ubuntu_verify() { ! user_exists "$REMOVE_TARGET"; }

step_register remove_ubuntu step.remove_ubuntu final 0
