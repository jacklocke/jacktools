#!/usr/bin/env bash
# Step "customize": pick users, then per user the .bashrc modules (assets/bashrc.d),
# .tmux.conf and the sensitive options (docker group, SSH key, sudo); one banner for all.
set -Eeuo pipefail

CUSTOM_BEGIN="# >>> JACKTOOLS CUSTOMIZATION >>>"
CUSTOM_END="# <<< JACKTOOLS CUSTOMIZATION <<<"
CUSTOM_EXTRAS=(tmux docker_group ssh_key sudo)
# Files a module needs in the user's home: module id -> "asset in assets/|path under home".
declare -gA CUSTOM_MODULE_FILES=(
    [tmux-login-menu]="tmux-login-menu.sh|.local/bin/tmux-login-menu.sh"
    [drin]="drin.sh|.local/bin/drin"
)
# Commands a module needs: the plan warns when they are neither installed nor selected
# among the packages of this run.
declare -gA CUSTOM_MODULE_NEEDS=(
    [powerline]="powerline"
    [tmux-login-menu]="tmux"
    [drin]="figlet at"
)
# msg-keys: customize.extra.tmux customize.extra.docker_group customize.extra.ssh_key customize.extra.sudo

declare -ga CUSTOM_MOD_IDS=() CUSTOM_MOD_DESC=() CUSTOM_MOD_DEFAULT=() CUSTOM_MOD_FILE=()

# ---- Users

login_defs_value() {
    local value
    value=$(awk -v k="$1" '$1 == k { print $2; exit }' "$(root_path /etc/login.defs)" 2>/dev/null)
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '%s' "$2"
}

login_shell_valid() {
    case "$1" in */nologin|*/false|'') return 1 ;; esac
    grep -Fqx -- "$1" "$(root_path /etc/shells)" 2>/dev/null
}

# Human accounts: UID_MIN..UID_MAX with a real login shell, in passwd order.
users_discover() {
    local min max name uid shell
    min=$(login_defs_value UID_MIN 1000)
    max=$(login_defs_value UID_MAX 60000)
    while IFS=: read -r name _ uid _ _ _ shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= min && uid <= max )) || continue
        login_shell_valid "$shell" && printf '%s\n' "$name"
    done < <(users_passwd)
    return 0
}

# ---- Modules and banners

# Header: "# jt-module: id | description | on|off"
custom_load_modules() {
    local file header
    local re='^# jt-module: ([a-z0-9-]+) \| (.+) \| (on|off)$'
    CUSTOM_MOD_IDS=(); CUSTOM_MOD_DESC=(); CUSTOM_MOD_DEFAULT=(); CUSTOM_MOD_FILE=()
    for file in "$JACKTOOLS_DIR"/assets/bashrc.d/*.sh; do
        [[ -f "$file" ]] || continue
        IFS= read -r header <"$file" || true
        if [[ ! "$header" =~ $re ]]; then ui_error customize.bad_module "${file##*/}"; return 1; fi
        CUSTOM_MOD_IDS+=("${BASH_REMATCH[1]}")
        CUSTOM_MOD_DESC+=("${BASH_REMATCH[2]}")
        CUSTOM_MOD_FILE+=("$file")
        if [[ "${BASH_REMATCH[3]}" == on ]]; then CUSTOM_MOD_DEFAULT+=(1); else CUSTOM_MOD_DEFAULT+=(0); fi
    done
}

banners_list() {
    local file
    for file in "$JACKTOOLS_DIR"/assets/banners/*.txt; do
        [[ -f "$file" ]] && basename "$file" .txt
    done
    return 0
}

banner_file() { printf '%s/assets/banners/%s.txt' "$JACKTOOLS_DIR" "$1"; }

BANNER_CUSTOM="custom"
BANNER_TEXT_MAX=30

# 1..BANNER_TEXT_MAX characters, not only blanks, no control characters or double quotes.
valid_banner_text() { (( ${#1} >= 1 && ${#1} <= BANNER_TEXT_MAX )) && [[ "$1" =~ [^[:space:]] && ! "$1" =~ [[:cntrl:]] && "$1" != *[\"\$\`\\]* ]]; }

# Large-letter rendering of TEXT (replaced in tests).
banner_figlet() { figlet -w 200 -- "$1"; }

# banner_lines: the text of the selected banner (a file, or the custom text via figlet).
banner_lines() {
    if [[ "${CFG[BANNER]}" == "$BANNER_CUSTOM" ]]; then
        banner_figlet "${CFG[BANNER_TEXT]}"
    else
        ui_print_file "$(banner_file "${CFG[BANNER]}")"
    fi
}

# banner_echo_lines: one echo per banner line; single quotes keep every character literal.
banner_echo_lines() {
    local line quote="'" escaped="'\\''"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf "echo '%s'\n" "${line//$quote/$escaped}"
    done
}

# Banner named like the hostname (case-insensitive), otherwise "welcome".
banner_suggested() {
    local host name
    host=$(hostname_current 2>/dev/null || hostname)
    while IFS= read -r name; do
        [[ "${name,,}" == "${host,,}" ]] && { printf '%s' "$name"; return 0; }
    done < <(banners_list)
    [[ -f "$(banner_file welcome)" ]] && printf welcome
    return 0
}

banners_render_all() {
    local name
    while IFS= read -r name; do
        printf '\n=== %s ===\n\n' "$name"
        ui_print_file "$(banner_file "$name")"
    done < <(banners_list)
}

# figlet is needed already while choosing, to show the preview: installing it here is the
# one deliberate change made during collect, always announced and confirmed.
banner_ensure_figlet() {
    command_exists figlet && return 0
    if [[ "$JACKTOOLS_DRY_RUN" == 1 ]]; then ui_warn customize.figlet_dry_run; return 1; fi
    ui_warn customize.figlet_needed
    [[ "$JT_CONFIG_MODE" == 1 ]] || ui_confirm customize.figlet_confirm || return 1
    if ! { apt_update_once && apt_get install -- figlet && command_exists figlet; }; then
        ui_error customize.figlet_failed
        return 1
    fi
}

# banner_custom_text: ask a text, show the figlet preview; 0 = accepted (CFG set), 1 = back.
banner_custom_text() {
    local text choice
    local -a actions
    banner_ensure_figlet || return 1
    actions=("$(msg_get customize.custom.accept)" "$(msg_get customize.custom.change)")
    while true; do
        ui_prompt text customize.custom.prompt "$BANNER_TEXT_MAX" || return 1
        [[ -n "$text" ]] || return 1
        if ! valid_banner_text "$text"; then ui_warn customize.custom.invalid "$BANNER_TEXT_MAX"; continue; fi
        msg customize.custom.preview
        banner_figlet "$text" | banner_echo_lines | sed 's/^/    /'
        printf '\n'
        banner_figlet "$text"
        while true; do
            ui_menu choice customize.custom.title actions customize.custom.back || return 1
            if (( choice == 0 )); then
                CFG[BANNER]="$BANNER_CUSTOM"
                CFG[BANNER_TEXT]="$text"
                return 0
            fi
            break
        done
    done
}

# banner_choose: sets CFG[BANNER] to a banner name, "custom" (with CFG[BANNER_TEXT]) or "none".
banner_choose() {
    local -a names items
    local choice suggested default='' i count
    mapfile -t names < <(banners_list)
    count=${#names[@]}
    suggested=$(banner_suggested)
    items=("${names[@]}" "$(msg_get customize.banner.custom)" "$(msg_get customize.banner.none)" "$(msg_get customize.banner.show_all)")
    for i in "${!names[@]}"; do [[ "${names[$i]}" == "$suggested" ]] && default=$i; done
    while true; do
        ui_menu choice customize.banner.title items ui.menu.cancel "$default" || return 1
        if (( choice < count )); then CFG[BANNER]="${names[$choice]}"; return 0; fi
        case $(( choice - count )) in
            0) banner_custom_text && return 0 ;;
            1) CFG[BANNER]=none; return 0 ;;
            2) banners_render_all | ui_pager ;;
        esac
    done
}

# ---- Collect

custom_user_label() {
    local user="$1"
    if [[ "$user" == root ]]; then msg_get customize.user.root
    elif ! user_exists "$user"; then msg_get customize.user.new "$user"
    else msg_get customize.user.existing "$user" "$(user_uid "$user")" "$(user_shell "$user")"; fi
}

custom_docker_available() { group_exists docker || [[ -n "${CFG[DOCKER_ARCH]:-}" ]]; }

custom_collect_user() {
    local user="$1" i extra key choice
    local -a labels=() selected=() modules=() extras=() extras_offered=() sudo_modes
    for i in "${!CUSTOM_MOD_IDS[@]}"; do
        labels+=("${CUSTOM_MOD_DESC[$i]}")
        selected+=("${CUSTOM_MOD_DEFAULT[$i]}")
    done
    for extra in "${CUSTOM_EXTRAS[@]}"; do
        [[ "$extra" == docker_group ]] && ! custom_docker_available && continue
        extras_offered+=("$extra")
        labels+=("$(msg_get "customize.extra.$extra")")
        if [[ "$extra" == tmux ]]; then selected+=(1); else selected+=(0); fi
    done
    ui_checklist customize.modules.title labels selected "$user" || return 1
    for i in "${!CUSTOM_MOD_IDS[@]}"; do [[ ${selected[$i]} == 1 ]] && modules+=("${CUSTOM_MOD_IDS[$i]}"); done
    for i in "${!extras_offered[@]}"; do
        [[ ${selected[$((i + ${#CUSTOM_MOD_IDS[@]}))]} == 1 ]] && extras+=("${extras_offered[$i]}")
    done
    CFG["CUSTOM_MODULES:$user"]="${modules[*]}"
    CFG["CUSTOM_EXTRAS:$user"]="${extras[*]}"
    if [[ " ${extras[*]} " == *" docker_group "* ]]; then
        ui_warn customize.docker_group_warning
        ui_confirm customize.docker_group_confirm "$user" || CFG["CUSTOM_EXTRAS:$user"]="${CFG["CUSTOM_EXTRAS:$user"]/docker_group/}"
    fi
    if [[ " ${extras[*]} " == *" ssh_key "* ]]; then
        while true; do
            ui_prompt key customize.prompt.key "$user" || return 1
            [[ -n "$key" ]] || return 1
            if valid_ssh_public_key "$key"; then CFG["CUSTOM_KEY:$user"]="$key"; break; fi
            ui_warn admin.invalid_key
        done
    fi
    if [[ " ${extras[*]} " == *" sudo "* ]]; then
        sudo_modes=("$(msg_get admin.sudo.password)" "$(msg_get admin.sudo.nopasswd)")
        ui_menu choice admin.sudo.title sudo_modes ui.menu.cancel || return 1
        if (( choice == 0 )); then CFG["CUSTOM_SUDO:$user"]=password; else CFG["CUSTOM_SUDO:$user"]=nopasswd; fi
    fi
    return 0
}

customize_collect() {
    local -a users=() labels=() selected=() chosen=()
    local user i
    custom_load_modules || return 1
    mapfile -t users < <(users_discover)
    if [[ -n "${CFG[ADMIN_USER]:-}" && " ${users[*]} " != *" ${CFG[ADMIN_USER]} "* ]]; then users+=("${CFG[ADMIN_USER]}"); fi
    users+=(root)
    for user in "${users[@]}"; do
        labels+=("$(custom_user_label "$user")")
        if [[ "$user" != root && ( "$user" == "${CFG[ADMIN_USER]:-}" || "$user" == "$ENV_OPERATOR" ) ]]; then
            selected+=(1)
        else
            selected+=(0)
        fi
    done
    ui_checklist customize.users.title labels selected || return 1
    for i in "${!users[@]}"; do [[ ${selected[$i]} == 1 ]] && chosen+=("${users[$i]}"); done
    (( ${#chosen[@]} > 0 )) || return 1
    CFG[CUSTOM_USERS]="${chosen[*]}"
    for user in "${chosen[@]}"; do
        msg customize.user_header "$user"
        custom_collect_user "$user" || return 1
    done
    CFG[BANNER]=none
    for user in "${chosen[@]}"; do
        if [[ " ${CFG["CUSTOM_MODULES:$user"]} " == *" banner "* ]]; then banner_choose || return 1; break; fi
    done
    return 0
}

# ---- Rendering

# custom_render_block USER: content of the managed block (markers excluded).
custom_render_block() {
    local user="$1" i
    printf '# Gestito da JackTools: le modifiche dentro questo blocco vengono sovrascritte.\n'
    # ":" keeps the block valid when no module is selected.
    printf 'if [[ $- == *i* ]]; then\n:\n'
    for i in "${!CUSTOM_MOD_IDS[@]}"; do
        [[ " ${CFG["CUSTOM_MODULES:$user"]} " == *" ${CUSTOM_MOD_IDS[$i]} "* ]] || continue
        printf '\n# --- %s\n' "${CUSTOM_MOD_IDS[$i]}"
        sed '1d; /^# The chosen banner is embedded/d' "${CUSTOM_MOD_FILE[$i]}"
        if [[ "${CUSTOM_MOD_IDS[$i]}" == banner && "${CFG[BANNER]:-none}" != none ]]; then
            # Marker comments let the export find which banner this block uses.
            if [[ "${CFG[BANNER]}" == "$BANNER_CUSTOM" ]]; then
                printf '# jacktools-banner-text: %s\n' "${CFG[BANNER_TEXT]}"
            else
                printf '# jacktools-banner: %s\n' "${CFG[BANNER]}"
            fi
            # shellcheck disable=SC2016 # Written literally into .bashrc, expanded at login.
            printf 'if [ -z "${TMUX:-}" ]; then\n'
            banner_lines | banner_echo_lines || return 1
            printf 'fi\n'
        fi
    done
    printf '\nfi\n'
}

# custom_render_bashrc USER OUTPUT: the user's .bashrc with the block replaced.
custom_render_bashrc() {
    local user="$1" output="$2" content bashrc
    bashrc="$(user_home "$user")/.bashrc"
    fs_mktemp content
    custom_render_block "$user" >"$content" || return 1
    managed_block_render "$bashrc" "$CUSTOM_BEGIN" "$CUSTOM_END" "$content" "$output" || return 1
    bash -n "$output"
}

custom_bashrc_ok() {
    local user="$1" candidate bashrc
    bashrc="$(user_home "$user")/.bashrc"
    [[ -f "$bashrc" ]] || return 1
    fs_mktemp candidate
    custom_render_bashrc "$user" "$candidate" 2>/dev/null && cmp -s "$candidate" "$bashrc"
}

# Module files needed by USER's selection, as "asset|path under home" lines.
custom_module_files() {
    local id
    for id in ${CFG["CUSTOM_MODULES:$1"]:-}; do
        [[ -v "CUSTOM_MODULE_FILES[$id]" ]] && printf '%s\n' "${CUSTOM_MODULE_FILES[$id]}"
    done
    return 0
}

custom_module_file_ok() { cmp -s "$JACKTOOLS_DIR/assets/${2%%|*}" "$(user_home "$1")/${2#*|}" 2>/dev/null; }

custom_tmux_ok() { cmp -s "$JACKTOOLS_DIR/assets/tmux.conf" "$(user_home "$1")/.tmux.conf" 2>/dev/null; }

# Warn about commands the selected modules need and nobody is installing.
custom_plan_missing_commands() {
    local id cmd missing
    for id in ${CFG["CUSTOM_MODULES:$1"]:-}; do
        [[ -v "CUSTOM_MODULE_NEEDS[$id]" ]] || continue
        missing=''
        for cmd in ${CUSTOM_MODULE_NEEDS[$id]}; do
            command_exists "$cmd" || [[ " ${CFG[PACKAGES]:-} " == *" $cmd "* ]] || missing+=" $cmd"
        done
        [[ -z "$missing" ]] || msg customize.plan_module_needs "$id" "${missing# }"
    done
    return 0
}

customize_plan() {
    local user extras entry
    for user in ${CFG[CUSTOM_USERS]}; do
        msg customize.plan_user "$user" "${CFG["CUSTOM_MODULES:$user"]:-$(msg_get customize.plan_nothing)}"
        if user_exists "$user" && custom_bashrc_ok "$user"; then msg customize.plan_bashrc_same; fi
        extras=" ${CFG["CUSTOM_EXTRAS:$user"]} "
        [[ "$extras" == *" tmux "* ]] && msg customize.plan_tmux
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            if ! user_exists "$user" || ! custom_module_file_ok "$user" "$entry"; then msg customize.plan_module_file "${entry#*|}"; fi
        done < <(custom_module_files "$user")
        custom_plan_missing_commands "$user"
        [[ "$extras" == *" docker_group "* ]] && msg customize.plan_docker_group
        [[ "$extras" == *" ssh_key "* ]] && msg customize.plan_key
        [[ "$extras" == *" sudo "* ]] && msg "customize.plan_sudo_${CFG["CUSTOM_SUDO:$user"]}"
        # msg-keys: customize.plan_sudo_password customize.plan_sudo_nopasswd
    done
    case "${CFG[BANNER]}" in
        none) ;;
        "$BANNER_CUSTOM") msg customize.plan_banner_custom "${CFG[BANNER_TEXT]}" ;;
        *) msg customize.plan_banner "${CFG[BANNER]}" ;;
    esac
    return 0
}

# ---- Apply

custom_apply_bashrc() {
    local user="$1" home bashrc candidate mode status=0
    home=$(user_home "$user")
    bashrc="$home/.bashrc"
    managed_block_status "$bashrc" "$CUSTOM_BEGIN" "$CUSTOM_END" || status=$?
    if (( status == 2 )); then ui_error customize.markers_broken "$bashrc"; return 1; fi
    fs_mktemp candidate
    custom_render_bashrc "$user" "$candidate" || { ui_error customize.render_failed "$user"; return 1; }
    [[ -f "$bashrc" ]] && cmp -s "$candidate" "$bashrc" && return 0
    mode=644
    [[ -f "$bashrc" ]] && mode=$(stat -c %a "$bashrc")
    backup_file "$bashrc" "bashrc-$user" >/dev/null || return 1
    atomic_install "$candidate" "$bashrc" "$mode" "$user" "$(user_primary_group "$user")" || return 1
    state_flag NEW_SHELL
}

custom_apply_tmux() {
    local user="$1" file
    custom_tmux_ok "$user" && return 0
    file="$(user_home "$user")/.tmux.conf"
    backup_file "$file" "tmux-$user" >/dev/null || return 1
    atomic_install "$JACKTOOLS_DIR/assets/tmux.conf" "$file" 0644 "$user" "$(user_primary_group "$user")"
}

# Install the files of the selected modules (e.g. ~/.local/bin/tmux-login-menu.sh, 0755),
# creating missing directories owned by the user.
custom_apply_module_files() {
    local user="$1" entry home group dest dir rel part
    local -a parts
    home=$(user_home "$user"); group=$(user_primary_group "$user")
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        custom_module_file_ok "$user" "$entry" && continue
        rel=${entry#*|}
        dest="$home/$rel"
        dir="$home"
        IFS=/ read -r -a parts <<<"${rel%/*}"
        for part in "${parts[@]}"; do
            dir="$dir/$part"
            if [[ ! -d "$dir" ]]; then mkdir -- "$dir" && chmod 0755 "$dir" && fs_chown "$user:$group" "$dir" || return 1; fi
        done
        backup_file "$dest" "module-$user-${rel##*/}" >/dev/null || return 1
        atomic_install "$JACKTOOLS_DIR/assets/${entry%%|*}" "$dest" 0755 "$user" "$group" || return 1
        log_write INFO "module file installed: $dest"
    done < <(custom_module_files "$user")
    return 0
}

customize_apply() {
    local user extras failed=0
    custom_load_modules || return 1
    if [[ "${CFG[BANNER]:-none}" == "$BANNER_CUSTOM" ]]; then banner_ensure_figlet || return 1; fi
    for user in ${CFG[CUSTOM_USERS]}; do
        if ! user_exists "$user" || [[ ! -d "$(user_home "$user")" ]]; then
            ui_error account.no_home "$user"; failed=1; continue
        fi
        extras=" ${CFG["CUSTOM_EXTRAS:$user"]} "
        custom_apply_bashrc "$user" || failed=1
        custom_apply_module_files "$user" || failed=1
        if [[ "$extras" == *" tmux "* ]]; then custom_apply_tmux "$user" || failed=1; fi
        if [[ "$extras" == *" docker_group "* ]]; then
            if group_exists docker; then account_add_group "$user" docker || failed=1; else ui_warn customize.no_docker_group; fi
        fi
        if [[ "$extras" == *" ssh_key "* ]]; then account_install_key "$user" "${CFG["CUSTOM_KEY:$user"]}" || failed=1; fi
        if [[ "$extras" == *" sudo "* ]]; then account_set_sudo "$user" "${CFG["CUSTOM_SUDO:$user"]}" || failed=1; fi
    done
    (( failed == 0 ))
}

# --config: modules and banner named in the file must exist here.
customize_config_prepare() {
    local user id
    custom_load_modules || return 1
    for user in ${CFG[CUSTOM_USERS]}; do
        for id in ${CFG["CUSTOM_MODULES:$user"]}; do
            [[ " ${CUSTOM_MOD_IDS[*]} " == *" $id "* ]] || { ui_error config.unknown_module "$id"; return 1; }
        done
        [[ -v "CFG[CUSTOM_EXTRAS:$user]" ]] || CFG["CUSTOM_EXTRAS:$user"]=''
    done
    return 0
}

customize_verify() {
    local user entry
    for user in ${CFG[CUSTOM_USERS]}; do
        custom_bashrc_ok "$user" || return 1
        while IFS= read -r entry; do
            [[ -z "$entry" ]] || custom_module_file_ok "$user" "$entry" || return 1
        done < <(custom_module_files "$user")
        [[ " ${CFG["CUSTOM_EXTRAS:$user"]} " != *" tmux "* ]] || custom_tmux_ok "$user" || return 1
    done
}

step_register customize step.customize users 1
