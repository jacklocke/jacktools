#!/usr/bin/env bash
# Powerline theme for the "powerline-theme" customization module: ~/.config/powerline from
# assets/powerline (config.json carries the chosen colour scheme), the colour schemes produced
# by assets/powerline/tools/gen-colorschemes.py, and the plcolors command (assets/plcolors.sh).
# Python only runs the generator shipped with the theme; the logic here stays in Bash.
set -Eeuo pipefail

PL_THEME_DEFAULT="gruvbox"
PL_ASSETS="powerline"
PL_CONFIG_ASSET="$PL_ASSETS/config.json"
PL_GENERATOR="$PL_ASSETS/tools/gen-colorschemes.py"

# Theme names: the keys of PALETTES in the generator, in file order.
pl_themes() { sed -n "s/^\t'\([a-z0-9_]*\)': {\$/\1/p" "$JACKTOOLS_DIR/assets/$PL_GENERATOR"; }

valid_pl_theme() {
    local name
    [[ "$1" =~ ^[a-z0-9_]+$ ]] || return 1
    while IFS= read -r name; do [[ "$name" == "$1" ]] && return 0; done < <(pl_themes)
    return 1
}

# config.json with THEME as colour scheme of both the shell prompt and the tmux bar.
pl_render_config() {
    sed "s/\"colorscheme\": \"[a-z0-9_]*\"/\"colorscheme\": \"$1\"/" "$JACKTOOLS_DIR/assets/$PL_CONFIG_ASSET"
}

# pl_generate DIR: generated files under DIR/powerline (colors.json and colorschemes/...).
pl_generate() {
    command_exists python3 || return 1
    XDG_CONFIG_HOME="$1" python3 "$JACKTOOLS_DIR/assets/$PL_GENERATOR" >/dev/null
}

# Generated files, relative to .config/powerline.
pl_generated_list() { (cd -- "$1/powerline" && find colors.json colorschemes -type f | LC_ALL=C sort); }

# Is USER's ~/.config/powerline up to date with freshly generated colour schemes?
pl_generated_ok() {
    local user="$1" dir rel base
    base="$(user_home "$user")/.config/powerline"
    fs_mktemp dir -d
    pl_generate "$dir" || return 1
    while IFS= read -r rel; do
        cmp -s "$dir/powerline/$rel" "$base/$rel" || return 1
    done < <(pl_generated_list "$dir")
}

# Install the generated colour schemes in USER's home (backup, owner the user, 0644).
pl_apply_generated() {
    local user="$1" dir rel base group
    base="$(user_home "$user")/.config/powerline"
    group=$(user_primary_group "$user")
    fs_mktemp dir -d
    pl_generate "$dir" || { ui_error customize.pl_theme.generate_failed; return 1; }
    while IFS= read -r rel; do
        cmp -s "$dir/powerline/$rel" "$base/$rel" && continue
        custom_make_dirs "$user" ".config/powerline/$rel" || return 1
        backup_file "$base/$rel" "powerline-$user-${rel//\//_}" >/dev/null || return 1
        atomic_install "$dir/powerline/$rel" "$base/$rel" 0644 "$user" "$group" || return 1
    done < <(pl_generated_list "$dir")
    log_write INFO "powerline colour schemes installed for $user"
}

# A running powerline daemon keeps the old theme: restart it for USER (replaced in tests).
pl_daemon_running() { pgrep -u "$1" -f powerline-daemon >/dev/null 2>&1; }

pl_reload_daemon() {
    local user="$1" home
    pl_daemon_running "$user" || return 0
    home=$(user_home "$user")
    run runuser -u "$user" -- env HOME="$home" XDG_CONFIG_HOME="$home/.config" powerline-daemon --replace || true
}

# Gallery of every theme (prompt and tmux bar), through plcolors on a temporary copy.
pl_gallery() {
    local dir
    if ! command_exists powerline-render; then ui_warn customize.pl_theme.no_gallery; return 0; fi
    fs_mktemp dir -d
    if ! { cp -r -- "$JACKTOOLS_DIR/assets/$PL_ASSETS" "$dir/" && pl_generate "$dir"; }; then
        ui_warn customize.pl_theme.no_gallery
        return 0
    fi
    # "(attivo)" would refer to the temporary copy: dropped, like the closing hint.
    XDG_CONFIG_HOME="$dir" bash "$JACKTOOLS_DIR/assets/plcolors.sh" | sed -e '$d' -e 's/  (attivo)$//' | ui_pager
}

# pl_choose: sets CFG[PL_THEME]; the gallery entry shows every theme and asks again.
pl_choose() {
    local -a names items
    local choice default='' i count current="${CFG[PL_THEME]:-$PL_THEME_DEFAULT}"
    mapfile -t names < <(pl_themes)
    count=${#names[@]}
    items=("${names[@]}" "$(msg_get customize.pl_theme.show_all)")
    for i in "${!names[@]}"; do [[ "${names[$i]}" == "$current" ]] && default=$i; done
    while true; do
        ui_menu choice customize.pl_theme.title items ui.menu.cancel "$default" || return 1
        if (( choice < count )); then CFG[PL_THEME]="${names[$choice]}"; return 0; fi
        pl_gallery
    done
}

# Theme of USER's installed config.json (for the export), empty if none.
pl_installed_theme() {
    local file
    file="$(user_home "$1")/.config/powerline/config.json"
    [[ -f "$file" ]] || return 0
    sed -n 's/.*"colorscheme": "\([a-z0-9_]*\)".*/\1/p' "$file" | head -n 1
}
