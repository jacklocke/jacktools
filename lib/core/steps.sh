#!/usr/bin/env bash
# Step registry and the collect -> plan -> confirm -> apply -> verify engine.
#
# A step <id> implements:
#   <id>_collect  ask questions, fill CFG; 0 = proceed, 1 = cancelled. Never changes the system.
#   <id>_plan     print what will change (or that it is already compliant). Read-only.
#   <id>_apply    apply idempotently. 0 = OK, 1 = FAILED, 3 = RESTORED (rolled back).
#                 It runs in an `||` context, so errexit is off: check every command.
#   <id>_verify   optional; 0 when the real state matches CFG.
set -Eeuo pipefail

declare -gA CFG=()
declare -ga STEP_IDS=()
declare -gA STEP_LABEL=() STEP_PHASE=() STEP_DEFAULT=() STEP_SKIP_ON=()

STEP_RC_FAILED=1
STEP_RC_RESTORED=3

# step_register ID LABEL_KEY PHASE DEFAULT(1|0) [VIRT_KINDS_TO_SKIP...]
step_register() {
    local id="$1"
    [[ -v "STEP_PHASE[$id]" ]] || STEP_IDS+=("$id")
    STEP_LABEL["$id"]="$2"
    STEP_PHASE["$id"]="$3"
    STEP_DEFAULT["$id"]="$4"
    STEP_SKIP_ON["$id"]="${*:5}"
}

step_label() { msg_get "${STEP_LABEL[$1]}"; }

step_exists() { [[ -v "STEP_PHASE[$1]" ]]; }

step_supported() { [[ " ${STEP_SKIP_ON[$1]} " != *" $ENV_VIRT_KIND "* ]]; }

# steps_of_phase PHASE RESULT_ARRAY: registered steps of PHASE, in registration order.
steps_of_phase() {
    local -n steps_of_phase_result="$2"
    local steps_of_phase_id
    steps_of_phase_result=()
    for steps_of_phase_id in "${STEP_IDS[@]}"; do
        [[ "${STEP_PHASE[$steps_of_phase_id]}" == "$1" ]] && steps_of_phase_result+=("$steps_of_phase_id")
    done
    return 0
}

# steps_run IDS_ARRAY [select]
# Runs the given steps in order. With "select" the operator first picks them from a
# checklist. Returns 1 when any applied step failed.
steps_run() {
    local -n steps_run_ids="$1"
    local steps_run_select="${2:-}" steps_run_id steps_run_rc steps_run_failed=0 steps_run_i
    local -a steps_run_todo=() steps_run_labels=() steps_run_selected=() steps_run_ready=()

    for steps_run_id in "${steps_run_ids[@]}"; do
        if step_supported "$steps_run_id"; then
            steps_run_todo+=("$steps_run_id")
        else
            ui_info steps.skipped_virt "$(step_label "$steps_run_id")" "$ENV_VIRT"
            state_set "${STEP_LABEL[$steps_run_id]}" SKIPPED
        fi
    done
    (( ${#steps_run_todo[@]} > 0 )) || return 0

    # --config: answers come from the file; every step is checked before anything runs.
    if [[ "$JT_CONFIG_MODE" == 1 ]]; then
        for steps_run_id in "${steps_run_todo[@]}"; do
            config_check_step "$steps_run_id" || return 1
        done
        steps_run_ready=("${steps_run_todo[@]}")
    elif [[ "$steps_run_select" == select && ${#steps_run_todo[@]} -gt 1 ]]; then
        for steps_run_id in "${steps_run_todo[@]}"; do
            steps_run_labels+=("$(step_label "$steps_run_id")")
            steps_run_selected+=("${STEP_DEFAULT[$steps_run_id]}")
        done
        ui_checklist steps.select.title steps_run_labels steps_run_selected || { ui_info steps.cancelled; return 0; }
        for steps_run_i in "${!steps_run_todo[@]}"; do
            [[ ${steps_run_selected[$steps_run_i]} == 1 ]] && steps_run_ready+=("${steps_run_todo[$steps_run_i]}")
        done
        steps_run_todo=("${steps_run_ready[@]}")
        steps_run_ready=()
    fi

    for steps_run_id in "${steps_run_todo[@]}"; do
        [[ "$JT_CONFIG_MODE" == 1 ]] && break
        ui_title steps.collect.title "$(step_label "$steps_run_id")"
        if "${steps_run_id}_collect"; then
            steps_run_ready+=("$steps_run_id")
        else
            state_set "${STEP_LABEL[$steps_run_id]}" CANCELLED
        fi
    done
    (( ${#steps_run_ready[@]} > 0 )) || return 0

    ui_title steps.plan.title
    for steps_run_id in "${steps_run_ready[@]}"; do
        printf '\n%s%s%s\n' "$BOLD" "$(step_label "$steps_run_id")" "$RESET"
        "${steps_run_id}_plan" | sed 's/^/    /'
    done
    printf '\n'

    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then
        msg steps.dry_run_done
        for steps_run_id in "${steps_run_ready[@]}"; do state_set "${STEP_LABEL[$steps_run_id]}" NOT_RUN; done
        return 0
    fi
    if [[ "$JT_ASSUME_YES" == 1 ]]; then
        ui_warn steps.assume_yes
    elif ! ui_confirm steps.confirm_apply; then
        for steps_run_id in "${steps_run_ready[@]}"; do state_set "${STEP_LABEL[$steps_run_id]}" CANCELLED; done
        return 0
    fi

    for steps_run_id in "${steps_run_ready[@]}"; do
        ui_title steps.apply.title "$(step_label "$steps_run_id")"
        steps_run_rc=0
        "${steps_run_id}_apply" || steps_run_rc=$?
        if (( steps_run_rc == 0 )) && declare -F "${steps_run_id}_verify" >/dev/null && ! "${steps_run_id}_verify"; then
            ui_error steps.verify_failed "$(step_label "$steps_run_id")"
            steps_run_rc=$STEP_RC_FAILED
        fi
        case "$steps_run_rc" in
            0) state_set "${STEP_LABEL[$steps_run_id]}" OK ;;
            "$STEP_RC_RESTORED") state_set "${STEP_LABEL[$steps_run_id]}" RESTORED; steps_run_failed=1 ;;
            *) state_set "${STEP_LABEL[$steps_run_id]}" FAILED; steps_run_failed=1 ;;
        esac
    done
    (( steps_run_failed == 0 ))
}

# steps_ordered RESULT_ARRAY IDS...: the given step ids in registration (execution) order.
steps_ordered() {
    local -n steps_ordered_result="$1"
    local steps_ordered_id
    shift
    steps_ordered_result=()
    for steps_ordered_id in "${STEP_IDS[@]}"; do
        [[ " $* " == *" $steps_ordered_id "* ]] && steps_ordered_result+=("$steps_ordered_id")
    done
    return 0
}

# run_phase PHASE: every step of PHASE, chosen from a checklist.
run_phase() {
    local -a run_phase_steps
    steps_of_phase "$1" run_phase_steps
    steps_run run_phase_steps select
}

run_single_step() {
    local -a run_single_step_ids=("$1")
    steps_run run_single_step_ids
}
