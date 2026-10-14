#!/usr/bin/env bash
# Step "swap": a JackTools-managed /swapfile (size or removal) with its /etc/fstab entry.
set -Eeuo pipefail

SWAP_FILE="/swapfile"

# Size in MiB of strings like 512M or 2G.
swap_size_mib() {
    local value="$1"
    case "$value" in
        *G) printf '%s' "$(( ${value%G} * 1024 ))" ;;
        *M) printf '%s' "${value%M}" ;;
        0) printf 0 ;;
    esac
}

valid_swap_size() { [[ "$1" == 0 || "$1" =~ ^[1-9][0-9]{0,5}[MG]$ ]]; }

swap_ram_mib() { awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' "$(root_path /proc/meminfo)" 2>/dev/null || printf 0; }

swap_suggested() {
    local ram
    ram=$(swap_ram_mib)
    if (( ram > 0 && ram < 4096 )); then printf '2G'; else printf '4G'; fi
}

# Active swap areas as "path size_mib" lines.
swap_active() { awk 'NR > 1 { printf "%s %d\n", $1, $3 / 1024 }' "$(root_path /proc/swaps)" 2>/dev/null || true; }

swap_file_active_mib() { swap_active | awk -v f="$SWAP_FILE" '$1 == f { print $2 }'; }

swap_collect() {
    local active answer suggested
    active=$(swap_active)
    msg swap.ram "$(swap_ram_mib)"
    if [[ -n "$active" ]]; then msg swap.active_list; printf '  %s\n' "${active//$'\n'/$'\n'  }"; else msg swap.none_active; fi
    if grep -vq "^$SWAP_FILE " <<<"$active" && [[ -n "$active" ]]; then ui_info swap.other_swap_present; fi
    suggested=$(swap_suggested)
    while true; do
        ui_prompt answer swap.prompt "$suggested" || return 1
        [[ -n "$answer" ]] || return 1
        answer=${answer^^}
        # shellcheck disable=SC2153 # CFG keys are not variables.
        if valid_swap_size "$answer"; then CFG[SWAP_SIZE]="$answer"; return 0; fi
        ui_warn swap.invalid
    done
}

swap_compliant() {
    local active_mib wanted_mib
    active_mib=$(swap_file_active_mib)
    wanted_mib=$(swap_size_mib "${CFG[SWAP_SIZE]}")
    if (( wanted_mib == 0 )); then
        [[ -z "$active_mib" ]] && ! swap_fstab_has_entry
    else
        # The kernel reports the usable size (one page less than the file).
        [[ -n "$active_mib" ]] && (( wanted_mib - active_mib <= 1 )) && swap_fstab_has_entry
    fi
}

swap_fstab_has_entry() { awk -v f="$SWAP_FILE" '$1 == f && $3 == "swap" { found = 1 } END { exit !found }' "$(root_path /etc/fstab)" 2>/dev/null; }

swap_plan() {
    if swap_compliant; then msg steps.plan.compliant; return 0; fi
    if [[ "${CFG[SWAP_SIZE]}" == 0 ]]; then
        msg swap.plan_remove "$SWAP_FILE"
    else
        msg swap.plan_create "$SWAP_FILE" "${CFG[SWAP_SIZE]}"
    fi
}

# swap_fstab_render SOURCE OUTPUT WANTED(0|1): drop old /swapfile lines, add one when wanted.
swap_fstab_render() {
    awk -v f="$SWAP_FILE" -v wanted="$3" '
        $1 == f { next }
        { print }
        END { if (wanted == 1) printf "%s none swap sw 0 0\n", f }
    ' "$1" >"$2"
}

swap_update_fstab() {
    local wanted="$1" fstab candidate
    fstab=$(root_path /etc/fstab)
    [[ -e "$fstab" ]] || touch "$fstab" || return 1
    fs_mktemp candidate
    swap_fstab_render "$fstab" "$candidate" "$wanted" || return 1
    cmp -s "$candidate" "$fstab" && return 0
    backup_file "$fstab" fstab >/dev/null || return 1
    atomic_install "$candidate" "$fstab" 0644
}

swap_free_mib() { df -Pm "$(root_path /)" | awk 'NR == 2 { print $4 }'; }

swap_apply() {
    local wanted_mib file
    swap_compliant && return 0
    wanted_mib=$(swap_size_mib "${CFG[SWAP_SIZE]}")
    file=$(root_path "$SWAP_FILE")
    if [[ -n "$(swap_file_active_mib)" ]]; then run swapoff "$file" || return 1; fi
    if (( wanted_mib == 0 )); then
        swap_update_fstab 0 || return 1
        run rm -f -- "$file" || return 1
        return 0
    fi
    # Keep at least 1 GiB free on the root filesystem after creating the file.
    if (( $(swap_free_mib) - wanted_mib < 1024 )); then ui_error swap.no_space; return 1; fi
    run rm -f -- "$file" || return 1
    run fallocate -l "${wanted_mib}M" "$file" || run dd if=/dev/zero of="$file" bs=1M count="$wanted_mib" status=none || return 1
    run chmod 0600 "$file" || return 1
    run mkswap "$file" >/dev/null || return 1
    run swapon "$file" || return 1
    swap_update_fstab 1
}

swap_verify() { swap_compliant; }

step_register swap step.swap system 0 container
