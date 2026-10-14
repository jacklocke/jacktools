#!/usr/bin/env bash
# Step "ufw": default deny incoming, the SSH port always allowed first, optional extra
# ports, then enable. Existing rules are never removed.
set -Eeuo pipefail

UFW_COMMON_RULES=(80/tcp 443/tcp)
# msg-keys: ufw.rule.http ufw.rule.https
UFW_COMMON_KEYS=(ufw.rule.http ufw.rule.https)

valid_ufw_rule() {
    [[ "$1" =~ ^([1-9][0-9]{0,4})(/(tcp|udp))?$ ]] && (( BASH_REMATCH[1] <= 65535 ))
}

# Output of `ufw status` (replaced in tests).
ufw_status() { ufw status 2>/dev/null; }
ufw_active() { ufw_status | grep -q '^Status: active'; }

# ufw_has_rule RULE: an ALLOW rule for RULE (IPv4 line) is present.
ufw_has_rule() { ufw_status | awk -v r="$1" '$1 == r && $2 == "ALLOW" { found = 1 } END { exit !found }'; }

ufw_collect() {
    local ssh_port answer item i
    local -a labels=() selected=() extra=()
    [[ "$ENV_VIRT_KIND" == container ]] && ui_warn ufw.container_warning
    ssh_port=${CFG[SSH_PORT]:-$(ssh_current_port)}
    msg ufw.ssh_rule "$ssh_port"
    for i in "${!UFW_COMMON_RULES[@]}"; do labels+=("$(msg_get "${UFW_COMMON_KEYS[$i]}")"); selected+=(0); done
    labels+=("$(msg_get ufw.rule.other)"); selected+=(0)
    ui_checklist ufw.rules.title labels selected || return 1
    CFG[UFW_ALLOW]="$ssh_port/tcp"
    for i in "${!UFW_COMMON_RULES[@]}"; do
        [[ ${selected[$i]} == 1 ]] && CFG[UFW_ALLOW]+=" ${UFW_COMMON_RULES[$i]}"
    done
    if [[ ${selected[${#UFW_COMMON_RULES[@]}]} == 1 ]]; then
        while true; do
            ui_prompt answer ufw.prompt.other || return 1
            IFS=', ' read -r -a extra <<<"$answer"
            for item in "${extra[@]}"; do valid_ufw_rule "$item" || { ui_warn ufw.invalid_rule "$item"; continue 2; }; done
            for item in "${extra[@]}"; do [[ " ${CFG[UFW_ALLOW]} " == *" $item "* ]] || CFG[UFW_ALLOW]+=" $item"; done
            break
        done
    fi
    return 0
}

ufw_missing_rules() {
    local rule
    for rule in ${CFG[UFW_ALLOW]}; do ufw_has_rule "$rule" || printf '%s\n' "$rule"; done
    return 0
}

ufw_compliant() { command_exists ufw && ufw_active && [[ -z "$(ufw_missing_rules)" ]]; }

ufw_plan() {
    if ufw_compliant; then msg steps.plan.compliant; return 0; fi
    command_exists ufw || msg ufw.plan_install
    msg ufw.plan_rules "$(ufw_missing_rules | xargs)"
    ufw_active || msg ufw.plan_enable
    return 0
}

ufw_apply() {
    local rule
    ufw_compliant && return 0
    if ! command_exists ufw; then
        apt_update_once || return 1
        apt_get install -- ufw || return 1
    fi
    run ufw default deny incoming >/dev/null || return 1
    run ufw default allow outgoing >/dev/null || return 1
    # CFG[UFW_ALLOW] starts with the SSH port, so it is allowed before anything else.
    for rule in ${CFG[UFW_ALLOW]}; do
        ufw_has_rule "$rule" || run ufw allow "$rule" >/dev/null || return 1
    done
    if ! ufw_active; then run ufw --force enable || return 1; fi
    return 0
}

ufw_verify() { ufw_compliant; }

step_register ufw step.ufw security 1
