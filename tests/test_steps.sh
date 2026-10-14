#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

# Fake steps: behaviour driven by FAKE_* variables, calls recorded in CALLS.
CALLS=''
for id in alpha beta gamma; do
    eval "
        ${id}_collect() { CALLS+=' ${id}:collect'; [[ \${FAKE_CANCEL:-} != ${id} ]]; }
        ${id}_plan() { printf 'plan ${id}\n'; }
        ${id}_apply() { CALLS+=' ${id}:apply'; return \${FAKE_RC_${id}:-0}; }
    "
done
gamma_verify() { CALLS+=' gamma:verify'; [[ ${FAKE_VERIFY_FAIL:-0} == 0 ]]; }
MSG['test.alpha']='Alpha'; MSG['test.beta']='Beta'; MSG['test.gamma']='Gamma'
step_register alpha test.alpha phase1 1
step_register beta test.beta phase1 0
step_register gamma test.gamma phase1 1 container
step_register other test.alpha phase2 1

reset_state() { STATE_ORDER=(); STATE_STATUS=(); CALLS=''; }

ids=()
steps_of_phase phase1 ids
assert_eq 'steps of phase in registration order' 'alpha beta gamma' "${ids[*]}"
assert_true 'step exists' step_exists beta
assert_false 'unknown step' step_exists nope

# Defaults alpha+gamma selected; confirm apply.
reset_state
steps_run ids select >/dev/null <<<$'\ny'
assert_eq 'default selection collected, applied, verified' ' alpha:collect gamma:collect alpha:apply gamma:apply gamma:verify' "$CALLS"
assert_eq 'states OK' 'OK OK' "$(state_get test.alpha) $(state_get test.gamma)"
assert_eq 'unselected step untouched' '' "$(state_get test.beta)"

# Toggle beta on, alpha off.
reset_state
steps_run ids select >/dev/null <<<$'1 2\n\ny'
assert_eq 'checklist changes selection' ' beta:collect gamma:collect beta:apply gamma:apply gamma:verify' "$CALLS"

# Cancelled collect is recorded and not applied.
reset_state
FAKE_CANCEL=alpha steps_run ids select >/dev/null <<<$'\ny'
assert_eq 'cancelled collect state' CANCELLED "$(state_get test.alpha)"
assert_eq 'cancelled step not applied' ' alpha:collect gamma:collect gamma:apply gamma:verify' "$CALLS"

# Declining the final confirmation applies nothing.
reset_state
steps_run ids select >/dev/null <<<$'\nn'
assert_eq 'declined confirmation applies nothing' ' alpha:collect gamma:collect' "$CALLS"
assert_eq 'declined confirmation state' CANCELLED "$(state_get test.gamma)"

# Dry-run shows the plan and applies nothing.
reset_state
out=$(JACKTOOLS_DRY_RUN=1 steps_run ids select <<<$'\n'; printf '|%s' "$CALLS")
assert_contains 'dry-run prints plan' 'plan gamma' "$out"
assert_contains 'dry-run applies nothing' '| alpha:collect gamma:collect' "$out"

# Failures, rollbacks and verification.
reset_state
FAKE_RC_alpha=1 FAKE_RC_gamma=3 steps_run ids select >/dev/null 2>&1 <<<$'\ny' && rc=0 || rc=$?
assert_eq 'failed run returns 1' 1 "$rc"
assert_eq 'apply rc 1 is FAILED' FAILED "$(state_get test.alpha)"
assert_eq 'apply rc 3 is RESTORED' RESTORED "$(state_get test.gamma)"
assert_false 'verify skipped after failed apply' grep -q 'gamma:verify' <<<"$CALLS"
reset_state
FAKE_VERIFY_FAIL=1 steps_run ids select >/dev/null 2>&1 <<<$'\ny' || true
assert_eq 'failed verify is FAILED' FAILED "$(state_get test.gamma)"

# Steps excluded for the detected virtualization are skipped before any question.
reset_state
ENV_VIRT=lxc ENV_VIRT_KIND=container
steps_run ids select >/dev/null <<<$'\ny'
assert_eq 'container skips gamma' SKIPPED "$(state_get test.gamma)"
assert_false 'skipped step not collected' grep -q 'gamma:collect' <<<"$CALLS"
ENV_VIRT=none ENV_VIRT_KIND=bare

# A single step runs without the selection checklist.
reset_state
single=(beta)
steps_run single >/dev/null <<<'y'
assert_eq 'single step without checklist' ' beta:collect beta:apply' "$CALLS"
finish_tests
