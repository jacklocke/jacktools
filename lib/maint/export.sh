#!/usr/bin/env bash
# Maintenance: generate a --config file from the REAL state of this server, to set up
# other servers the same way. Server-specific values (hostname, network) are written
# commented out; passwords are never exported; removing "ubuntu" is never exported.
set -Eeuo pipefail

EXPORT_DIR="/root"

# Each export_<id> reads the live state, fills CFG and returns 0 when the step is worth
# repeating elsewhere (it is then added to STEPS).

export_hostname() { CFG[HOSTNAME]=$(hostname_current); CONFIG_COMMENTED[HOSTNAME]=1; return 1; }

export_locale() {
    local value
    value=$(locale_current)
    valid_locale "$value" || return 1
    CFG[LOCALE]="$value"
}

export_time() {
    local zone
    zone=$(time_current_zone)
    valid_timezone "$zone" || return 1
    CFG[TIMEZONE]="$zone"
    if time_ntp_enabled; then CFG[NTP]=on; else CFG[NTP]=keep; fi
}

# Network settings are tied to this machine: exported as commented reference only.
export_network() {
    local file key value
    local -a files
    files=("$(root_path /etc/netplan)"/99-jacktools-*.yaml)
    file=${files[0]}
    [[ -f "$file" ]] || return 1
    value=${file##*/99-jacktools-}; CFG[NET_IFACE]=${value%.yaml}
    if grep -q 'dhcp4: true' "$file"; then
        if grep -q 'use-dns: false' "$file"; then CFG[NET_MODE]=dhcp-dns; else CFG[NET_MODE]=dhcp; fi
    else
        CFG[NET_MODE]=static
        CFG[NET_CIDR]=$(awk '/addresses:/ { getline; gsub(/[-" ]/, ""); print; exit }' "$file")
        CFG[NET_GATEWAY]=$(awk '/via:/ { gsub(/"/, "", $2); print $2; exit }' "$file")
    fi
    value=$(awk '/nameservers:/ { getline; sub(/.*addresses: /, ""); print; exit }' "$file")
    [[ -z "$value" ]] || CFG[NET_DNS]=$(tr -d '[]" ' <<<"$value")
    value=$(awk '/search:/ { sub(/.*search: /, ""); print; exit }' "$file")
    [[ -z "$value" ]] || CFG[NET_SEARCH]=$(tr -d '[]" ' <<<"$value")
    for key in NET_IFACE NET_MODE NET_CIDR NET_GATEWAY NET_DNS NET_SEARCH; do CONFIG_COMMENTED["$key"]=1; done
    return 1
}

export_swap() {
    local mib
    mib=$(swap_file_active_mib)
    [[ -n "$mib" ]] || return 1
    # The kernel reports one page less than the file: round to whole MiB of the file.
    CFG[SWAP_SIZE]="$(( mib + 1 ))M"
    (( (mib + 1) % 1024 == 0 )) && CFG[SWAP_SIZE]="$(( (mib + 1) / 1024 ))G"
    return 0
}

export_journald() {
    local value
    value=$(awk -F= '$1 == "SystemMaxUse" { print $2 }' "$(root_path "$JOURNALD_DROPIN")" 2>/dev/null)
    valid_journal_size "$value" || return 1
    CFG[JOURNAL_MAX]="$value"
    if logrotate_compress_enabled; then CFG[LOGROTATE_COMPRESS]=on; else CFG[LOGROTATE_COMPRESS]=keep; fi
}

export_motd() { motd_compliant || return 1; CFG[MOTD_CLEAN]=yes; }

export_upgrade() { CFG[UPGRADE]=yes; }

export_packages() {
    local -a installed=()
    local name
    parse_packages_file "$JACKTOOLS_DIR/assets/packages.txt" >/dev/null 2>&1 || return 1
    for name in "${PACKAGE_NAMES[@]}" qemu-guest-agent; do apt_is_installed "$name" && installed+=("$name"); done
    (( ${#installed[@]} > 0 )) || return 1
    CFG[PACKAGES]="${installed[*]}"
}

export_docker() {
    docker_engine_installed || return 1
    CFG[DOCKER_REMOVE_CONFLICTS]=yes
    if apt_is_installed docker-compose-plugin; then CFG[DOCKER_COMPOSE]=yes; else CFG[DOCKER_COMPOSE]=no; fi
}

export_unattended() {
    local file time
    apt_is_installed unattended-upgrades || return 1
    file=$(root_path "$UNATTENDED_JACKTOOLS")
    [[ -f "$file" ]] || return 1
    time=$(sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";$/\1/p' "$file")
    if grep -q 'Automatic-Reboot "true"' "$file" && valid_reboot_time "$time"; then CFG[UNATTENDED_REBOOT]="$time"; else CFG[UNATTENDED_REBOOT]=no; fi
}

# The operator becomes the administrator of the new server, with the first SSH key found.
export_admin() {
    local user="$ENV_OPERATOR" key=''
    [[ "$user" != root ]] && user_exists "$user" && user_in_group "$user" sudo || return 1
    CFG[ADMIN_USER]="$user"
    CFG[ADMIN_FULLNAME]=$(user_field "$user" 5 | cut -d, -f1)
    valid_fullname "${CFG[ADMIN_FULLNAME]}" || CFG[ADMIN_FULLNAME]=''
    if user_has_key "$user"; then
        while IFS= read -r key; do valid_ssh_public_key "$key" && break; key=''; done <"$(user_home "$user")/.ssh/authorized_keys"
    fi
    CFG[ADMIN_KEY]="$key"
    CFG[ADMIN_SUDO]=$(account_sudo_mode "$user")
}

# Users whose .bashrc holds a JackTools block: modules come from its "# --- <id>" lines.
export_customize() {
    local user bashrc modules extras line users=''
    CFG[BANNER]=none
    while IFS= read -r user; do
        bashrc="$(user_home "$user")/.bashrc"
        managed_block_status "$bashrc" "$CUSTOM_BEGIN" "$CUSTOM_END" || continue
        modules=$(sed -n "/^$CUSTOM_BEGIN\$/,/^$CUSTOM_END\$/ s/^# --- \([a-z0-9-]*\)\$/\1/p" "$bashrc" | xargs)
        extras=''
        custom_tmux_ok "$user" && extras='tmux'
        users+=" $user"
        CFG["CUSTOM_MODULES:$user"]="$modules"
        CFG["CUSTOM_EXTRAS:$user"]="$extras"
        line=$(sed -n "s/^# jacktools-banner: \(.*\)$/\1/p" "$bashrc" | head -1)
        if [[ -n "$line" ]] && valid_banner_name "$line"; then CFG[BANNER]="$line"; fi
        line=$(sed -n "s/^# jacktools-banner-text: \(.*\)$/\1/p" "$bashrc" | head -1)
        if [[ -n "$line" ]] && valid_banner_text "$line"; then CFG[BANNER]=custom; CFG[BANNER_TEXT]="$line"; fi
        if [[ " $modules " == *" powerline-theme "* && -z "${CFG[PL_THEME]:-}" ]]; then
            line=$(pl_installed_theme "$user")
            if [[ -n "$line" ]] && valid_pl_theme "$line"; then CFG[PL_THEME]="$line"; else CFG[PL_THEME]="$PL_THEME_DEFAULT"; fi
        fi
    done < <(users_discover)
    [[ -n "$users" ]] || return 1
    CFG[CUSTOM_USERS]=$(xargs <<<"$users")
}

export_ssh() {
    [[ -f "$(root_path "$SSH_HARDEN_FILE")" ]] || return 1
    # shellcheck disable=SC2153 # CFG keys are not variables.
    CFG[SSH_PORT]=$(ssh_current_port)
    if [[ "$(ssh_policy_values passwordauthentication)" == no ]]; then CFG[SSH_PASSWORD_AUTH]=no; else CFG[SSH_PASSWORD_AUTH]=keep; fi
    case "$(ssh_policy_values permitrootlogin)" in
        no) CFG[SSH_ROOT_LOGIN]=no ;;
        prohibit-password|without-password) CFG[SSH_ROOT_LOGIN]=prohibit-password ;;
        *) CFG[SSH_ROOT_LOGIN]=keep ;;
    esac
}

# Allowed ports (IPv4 lines of ufw status), SSH port first.
export_ufw() {
    local rules ssh_port
    command_exists ufw && ufw_active || return 1
    ssh_port=$(ssh_current_port)
    rules=$(ufw_status | awk '$2 == "ALLOW" && $1 ~ /^[0-9]+(\/(tcp|udp))?$/ { print $1 }' | grep -vx "$ssh_port/tcp" | xargs || true)
    CFG[UFW_ALLOW]=$(xargs <<<"$ssh_port/tcp $rules")
}

export_fail2ban() {
    [[ -f "$(root_path "$F2B_JAIL_FILE")" ]] || return 1
    maint_f2b_load >/dev/null 2>&1 || return 1
    # The port follows the SSH step on the target server.
    unset 'CFG[SSH_PORT]'
    export_ssh >/dev/null 2>&1 || true
}

export_remove_ubuntu() { return 1; }

# export_collect: fill CFG and CFG[STEPS] from this server.
export_collect() {
    local id steps=''
    CFG=()
    CONFIG_COMMENTED=()
    for id in "${STEP_IDS[@]}"; do
        declare -F "export_$id" >/dev/null || continue
        if "export_$id"; then steps+=" $id"; fi
    done
    # shellcheck disable=SC2153 # CFG keys are not variables.
    CFG[STEPS]=$(xargs <<<"$steps")
}

export_command() {
    local file="$1"
    if [[ -n "${JACKTOOLS_BOOTSTRAP_URL:-}" ]]; then
        printf 'curl -fsSL %s -o /tmp/jacktools-bootstrap.sh && sudo bash /tmp/jacktools-bootstrap.sh %s -- all --config %s\n' \
            "$JACKTOOLS_BOOTSTRAP_URL" "${JACKTOOLS_SOURCE_ARGS:-}" "$file"
    else
        printf 'sudo bash jacktools.sh all --config %s\n' "$file"
    fi
}

export_run() {
    local dir file
    export_collect
    dir=$(root_path "$EXPORT_DIR")
    file="$dir/jacktools-$(hostname_current)-$(date '+%Y%m%d-%H%M%S').conf"
    ui_title maint.export.title
    msg maint.export.steps "${CFG[STEPS]:-$(msg_get customize.plan_nothing)}"
    msg maint.export.notes
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then msg cleanup.dry_run; return 0; fi
    ui_confirm maint.export.confirm "$file" || return 0
    mkdir -p -- "$dir" || return 1
    (umask 077 && config_write "$file") || { ui_error maint.export.failed; return 1; }
    chmod 0600 "$file"
    ui_info maint.export.done "$file"
    msg maint.export.how_to "$EXPORT_DIR/${file##*/}"
    export_command "$EXPORT_DIR/${file##*/}"
}
