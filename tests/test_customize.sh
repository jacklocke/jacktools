#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_users

mkdir -p "$JACKTOOLS_ROOT/etc"
printf '/bin/bash\n' >"$JACKTOOLS_ROOT/etc/shells"
printf 'tars\n' >"$JACKTOOLS_ROOT/etc/hostname"
add_user jack 1000 /bin/bash sudo
add_user alice 1001 /bin/bash
ENV_OPERATOR=jack
home="$WORK/home/jack"
# Ubuntu-like .bashrc with an old v1 block in the middle.
printf '# ~/.bashrc\ncase $- in *i*) ;; *) return;; esac\n# >>> JACKTOOLS CUSTOMIZATION >>>\nalias ll=%s\n# <<< JACKTOOLS CUSTOMIZATION <<<\nalias mine=true\n' "'exa -l'" >"$home/.bashrc"

custom_load_modules
CFG[BANNER]=welcome CFG["CUSTOM_MODULES:x"]='locale banner tmux-aliases'
assert_contains 'block renders with errexit on' 'alias tnew=' "$(set -e; custom_render_block x)"
assert_eq 'module header lines stripped' 0 "$(custom_render_block x | grep -c 'jt-module:')"
assert_contains 'module files in order' 'locale' "$(custom_render_block x | grep '^# --- ' | head -1)"
assert_eq 'modules in order' 'locale banner sysinfo powerline powerline-theme history tmux-aliases docker-aliases useful-aliases fun drin tmux-login-menu' "${CUSTOM_MOD_IDS[*]}"
assert_eq 'module defaults (powerline theme, history, drin and tmux login menu off)' '1 1 1 1 0 0 1 0 0 0 0 0' "${CUSTOM_MOD_DEFAULT[*]}"
assert_eq 'banners from files' 'C3 TARS UMB welcome zima zimalxc' "$(banners_list | LC_ALL=C sort | xargs)"
assert_eq 'banner suggested by hostname (case-insensitive)' TARS "$(banner_suggested)"
printf 'other\n' >"$JACKTOOLS_ROOT/etc/hostname"
assert_eq 'welcome when no banner matches' welcome "$(banner_suggested)"
printf 'tars\n' >"$JACKTOOLS_ROOT/etc/hostname"

# Users: jack (operator) preselected; modules default + useful-aliases (9); banner default.
customize_collect >"$WORK/out" 2>&1 <<<$'\n9\n\n'
assert_contains 'users listed with uid and shell' 'jack (uid 1000, /bin/bash)' "$(cat "$WORK/out")"
assert_contains 'root offered' 'root (amministratore di sistema)' "$(cat "$WORK/out")"
assert_eq 'operator selected' jack "${CFG[CUSTOM_USERS]}"
assert_eq 'modules chosen' 'locale banner sysinfo powerline tmux-aliases useful-aliases' "${CFG["CUSTOM_MODULES:jack"]}"
assert_eq 'tmux.conf selected by default' tmux "${CFG["CUSTOM_EXTRAS:jack"]}"
assert_eq 'banner default accepted' TARS "${CFG[BANNER]}"
assert_false 'docker group not offered without docker' grep -q 'gruppo docker' "$WORK/out"

customize_apply
bashrc=$(cat "$home/.bashrc")
assert_true 'bashrc is valid bash' bash -n "$home/.bashrc"
assert_contains 'user lines kept' 'alias mine=true' "$bashrc"
assert_false 'old v1 block replaced' grep -q exa "$home/.bashrc"
assert_eq 'single block' 1 "$(grep -c '^# >>> JACKTOOLS CUSTOMIZATION >>>$' "$home/.bashrc")"
assert_contains 'banner embedded as echo lines' "echo '_/  |______ _______  ______'" "$bashrc"
assert_false 'fun module not included' grep -q coffee "$home/.bashrc"
assert_true '.tmux.conf installed' cmp -s "$ROOT/assets/tmux.conf" "$home/.tmux.conf"
if command -v tmux >/dev/null; then
    # tmux reads the shipped file without errors (private server, no user config). Errors are
    # printed only by source-file on a running server, not by "-f" at start-up.
    tmux_check() { HOME="$home" tmux -L "jt-test-$$" -f /dev/null start-server \; source-file "$1" \; kill-server 2>&1; }
    assert_eq '.tmux.conf parsed by tmux' '' "$(tmux_check "$ROOT/assets/tmux.conf")"
    printf 'bogus-command\n' >"$WORK/bad-tmux.conf"
    assert_contains 'a broken tmux.conf is noticed' 'bogus-command' "$(tmux_check "$WORK/bad-tmux.conf")"
fi
assert_true 'bashrc backup' quiet compgen -G "$JACKTOOLS_BACKUP_ROOT/bashrc-jack-*"
assert_true 'verify' customize_verify
assert_contains 'plan reports bashrc up to date' 'già aggiornato' "$(customize_plan)"
cp "$home/.bashrc" "$WORK/before"
customize_apply
assert_true 'second apply changes nothing' cmp -s "$WORK/before" "$home/.bashrc"
assert_eq 'non-interactive shells print nothing' '' "$(HOME="$home" bash -c "source '$home/.bashrc'" 2>&1)"
out=$(HOME="$home" TMUX='' bash --norc -i -c "source '$home/.bashrc'" 2>/dev/null </dev/null || true)
assert_contains 'interactive shell shows banner' '_/  |______' "$out"
out=$(HOME="$home" TMUX=/tmp/x bash --norc -i -c "source '$home/.bashrc'" 2>/dev/null </dev/null || true)
assert_false 'no banner inside tmux' grep -q '_/  |______' <<<"$out"
assert_eq 'locale module sets UTF-8 when missing' C.UTF-8 "$(HOME="$home" LANG=C LC_ALL='' bash --norc -i -c "source '$home/.bashrc' >/dev/null 2>&1; printf %s \"\$LANG\"" 2>/dev/null </dev/null)"
assert_eq 'locale module keeps an existing UTF-8 locale' it_IT.UTF-8 "$(HOME="$home" LANG=it_IT.UTF-8 LC_ALL='' bash --norc -i -c "source '$home/.bashrc' >/dev/null 2>&1; printf %s \"\$LANG\"" 2>/dev/null </dev/null)"

# Re-running with fewer modules replaces the block instead of appending.
CFG["CUSTOM_MODULES:jack"]='tmux-aliases'
customize_apply
assert_false 'banner removed on rerun' grep -q '_/  |______' "$home/.bashrc"
assert_eq 'still a single block' 1 "$(grep -c '^# >>> JACKTOOLS CUSTOMIZATION >>>$' "$home/.bashrc")"

# Broken markers are refused, file untouched.
printf '# >>> JACKTOOLS CUSTOMIZATION >>>\nhalf\n' >"$WORK/home/alice/.bashrc"
CFG[CUSTOM_USERS]=alice CFG["CUSTOM_MODULES:alice"]=locale CFG["CUSTOM_EXTRAS:alice"]=''
assert_rc 'broken markers refused' 1 quiet customize_apply
assert_eq 'broken file untouched' $'# >>> JACKTOOLS CUSTOMIZATION >>>\nhalf' "$(cat "$WORK/home/alice/.bashrc")"

# Missing .bashrc is created with mode 644; sensitive extras.
rm "$WORK/home/alice/.bashrc"
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting alice@pc'
printf 'docker:x:999:\n' >>"$WORK/group"
# Users: toggle jack off, alice on. Modules: defaults off, tmux off, the three sensitive on.
customize_collect >"$WORK/out" 2>&1 <<EOF2
1 2

1 2 3 4 7 13 14 15 16

y
$key
2
EOF2
assert_eq 'only alice selected' alice "${CFG[CUSTOM_USERS]}"
assert_eq 'sensitive extras chosen' 'docker_group ssh_key sudo' "${CFG["CUSTOM_EXTRAS:alice"]}"
assert_eq 'no modules, so no banner question' none "${CFG[BANNER]}"
reset_commands
customize_apply
assert_true 'bashrc created' test -f "$WORK/home/alice/.bashrc"
assert_contains 'docker group added' 'RUN: usermod -aG docker alice' "$(commands_run)"
assert_true 'key installed' grep -qF "$key" "$WORK/home/alice/.ssh/authorized_keys"
assert_true 'nopasswd sudo' test -f "$JACKTOOLS_ROOT/etc/sudoers.d/90-jacktools-alice"

# ---- tmux login menu module: script installed in ~/.local/bin, launched from the block
rm -rf "$WORK/home/jack/.local"
CFG[CUSTOM_USERS]=jack CFG["CUSTOM_MODULES:jack"]='tmux-aliases tmux-login-menu' CFG["CUSTOM_EXTRAS:jack"]='' CFG[BANNER]=none
assert_contains 'plan announces the script' 'installazione di ~/.local/bin/tmux-login-menu.sh' "$(customize_plan)"
customize_apply
menu="$WORK/home/jack/.local/bin/tmux-login-menu.sh"
assert_true 'script installed' cmp -s "$ROOT/assets/tmux-login-menu.sh" "$menu"
assert_eq 'script executable' 755 "$(stat -c %a "$menu")"
assert_eq 'directories created' 755 "$(stat -c %a "$WORK/home/jack/.local/bin")"
# shellcheck disable=SC2016 # The literal $HOME is what the block must contain.
assert_contains 'block launches the script' '"$HOME/.local/bin/tmux-login-menu.sh"' "$(cat "$home/.bashrc")"
assert_contains 'only in login shells' 'shopt -q login_shell' "$(cat "$home/.bashrc")"
assert_true 'verify with module file' customize_verify
assert_false 'plan quiet once installed' grep -q 'installazione di' <<<"$(customize_plan)"
printf 'old\n' >"$menu"
customize_apply
assert_true 'modified script replaced' cmp -s "$ROOT/assets/tmux-login-menu.sh" "$menu"
assert_true 'previous script backed up' quiet compgen -G "$JACKTOOLS_BACKUP_ROOT/module-jack-tmux-login-menu.sh-*"
out=$(HOME="$home" bash --norc -i -c "source '$home/.bashrc'" 2>&1 </dev/null || true)
assert_false 'not launched without a terminal or login shell' grep -q 'Sessioni tmux' <<<"$out"
command_exists() { [[ "$1" != tmux ]] && command -v "$1" >/dev/null 2>&1; }
assert_contains 'warning when tmux is missing' 'il modulo tmux-login-menu richiede tmux' "$(customize_plan)"
CFG[PACKAGES]='curl tmux'
assert_false 'no warning when tmux is being installed' grep -q 'richiede tmux' <<<"$(customize_plan)"
unset -f command_exists
source "$ROOT/lib/core/exec.sh"
CFG[PACKAGES]=''

# ---- drin module: command installed as ~/.local/bin/drin, ~/.local/bin added to PATH
CFG[CUSTOM_USERS]=jack CFG["CUSTOM_MODULES:jack"]='drin' CFG["CUSTOM_EXTRAS:jack"]='' CFG[BANNER]=none
assert_contains 'plan announces drin' 'installazione di ~/.local/bin/drin.' "$(customize_plan)"
customize_apply
assert_true 'drin installed' cmp -s "$ROOT/assets/drin.sh" "$WORK/home/jack/.local/bin/drin"
assert_eq 'drin executable' 755 "$(stat -c %a "$WORK/home/jack/.local/bin/drin")"
assert_true 'verify with drin' customize_verify
path_out=$(HOME="$home" PATH=/usr/bin:/bin bash --norc -i -c "source '$home/.bashrc' >/dev/null 2>&1; printf %s \"\$PATH\"" 2>/dev/null </dev/null)
assert_contains 'local bin added to PATH' "$home/.local/bin:" "$path_out"
path_out=$(HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin" bash --norc -i -c "source '$home/.bashrc' >/dev/null 2>&1; printf %s \"\$PATH\"" 2>/dev/null </dev/null)
assert_eq 'PATH not duplicated' "$home/.local/bin:/usr/bin:/bin" "$path_out"
command_exists() { [[ "$1" != at ]] && command -v "$1" >/dev/null 2>&1; }
assert_contains 'warning when at is missing' 'il modulo drin richiede at' "$(customize_plan)"
CFG[PACKAGES]='at'
assert_false 'no warning when at is being installed' grep -q 'richiede at' <<<"$(customize_plan)"
unset -f command_exists
source "$ROOT/lib/core/exec.sh"
CFG[PACKAGES]=''

# ---- powerline-theme module: ~/.config/powerline with the chosen theme, schemes, plcolors
assert_eq 'sixteen themes, read from the generator' 16 "$(pl_themes | wc -l)"
assert_true 'theme valid' valid_pl_theme nord
for bad in '' Nord 'nord;rm' ../x dracula2; do assert_false "theme rejected: $(printf %q "$bad")" valid_pl_theme "$bad"; done
CFG=([CUSTOM_USERS]=jack [CUSTOM_MODULES:jack]='powerline-theme' [CUSTOM_EXTRAS:jack]='' [BANNER]=none)
pl_choose >"$WORK/out" 2>&1 <<<$'\n'
assert_eq 'default theme gruvbox' gruvbox "${CFG[PL_THEME]}"
pl_choose >"$WORK/out" 2>&1 <<<$'2\n'
assert_eq 'theme picked from the list' nord "${CFG[PL_THEME]}"
plan=$(customize_plan)
assert_contains 'plan names the theme' 'tema powerline: nord' "$plan"
assert_contains 'plan warns without the powerline module' 'solo insieme al modulo powerline' "$plan"
assert_contains 'plan announces the schemes' 'schemi di colori powerline' "$plan"
pl_daemon_running() { true; }
reset_commands
customize_apply
pl="$home/.config/powerline"
assert_contains 'config.json with the chosen theme' '"colorscheme": "nord"' "$(cat "$pl/config.json")"
assert_false 'no other theme left in config.json' grep -q gruvbox "$pl/config.json"
assert_true 'tmux theme installed' cmp -s "$ROOT/assets/powerline/themes/tmux/custom.json" "$pl/themes/tmux/custom.json"
assert_eq 'data files 0644' 644 "$(stat -c %a "$pl/segments/sysseg.py")"
assert_eq 'tools 0755' 755 "$(stat -c %a "$pl/tools/tmux-hostname.py")"
assert_eq 'theme menu 0755' 755 "$(stat -c %a "$pl/tools/theme-menu.sh")"
assert_eq 'key summary 0644' 644 "$(stat -c %a "$pl/tools/tmux-keys.txt")"
assert_true 'plcolors installed' cmp -s "$ROOT/assets/plcolors.sh" "$home/.local/bin/plcolors"
assert_eq 'plcolors executable' 755 "$(stat -c %a "$home/.local/bin/plcolors")"
assert_eq 'config dir owned by the user' jack "$(stat -c %U "$home/.config")"
if command -v python3 >/dev/null; then
    assert_true 'colour schemes generated' test -f "$pl/colorschemes/tmux/nord.json"
    assert_eq 'one scheme per theme and part' 48 "$(find "$pl/colorschemes" -type f | wc -l)"
    assert_true 'colors.json generated' test -f "$pl/colors.json"
fi
assert_contains 'running daemon restarted as the user' 'runuser -u jack' "$(commands_run)"
assert_true 'verify with the theme' customize_verify
reset_commands
customize_apply
assert_eq 'second apply changes nothing' '' "$(commands_run)"
assert_contains 'plan: bashrc already up to date' 'già aggiornato' "$(customize_plan)"
assert_false 'plan: schemes already in place' grep -q 'schemi di colori' <<<"$(customize_plan)"
printf '{}\n' >"$pl/colorschemes/tmux/nord.json"
assert_false 'verify notices a changed scheme' customize_verify
customize_apply
assert_true 'scheme restored' customize_verify
unset -f pl_daemon_running
# The path line is written once even with two modules in ~/.local/bin.
CFG["CUSTOM_MODULES:jack"]='powerline-theme drin'
assert_eq 'one PATH line for drin and plcolors' 1 "$(custom_render_block jack | grep -c 'jacktools-path')"
CFG["CUSTOM_MODULES:jack"]='locale'
assert_eq 'no PATH line without commands in ~/.local/bin' 0 "$(custom_render_block jack | grep -c 'jacktools-path')"
CFG=([CUSTOM_USERS]=jack [CUSTOM_MODULES:jack]='powerline powerline-theme' [CUSTOM_EXTRAS:jack]='' [BANNER]=none [PL_THEME]=nord)
assert_false 'no warning with the powerline module' grep -q 'solo insieme' <<<"$(customize_plan)"

# ---- powerline module: warning when the package is neither installed nor selected
CFG[CUSTOM_USERS]=jack CFG["CUSTOM_MODULES:jack"]='powerline' CFG["CUSTOM_EXTRAS:jack"]='' CFG[BANNER]=none
command_exists() { [[ "$1" != powerline ]] && command -v "$1" >/dev/null 2>&1; }
assert_contains 'warning when powerline is missing' 'il modulo powerline richiede powerline' "$(customize_plan)"
CFG[PACKAGES]='curl powerline'
assert_false 'no warning when powerline is being installed' grep -q 'richiede powerline' <<<"$(customize_plan)"
unset -f command_exists
source "$ROOT/lib/core/exec.sh"
CFG[PACKAGES]=''

# ---- history module: bigger history, saved after every command, no bind warnings without a terminal
CFG[CUSTOM_USERS]=jack CFG["CUSTOM_MODULES:jack"]='history' CFG["CUSTOM_EXTRAS:jack"]='' CFG[BANNER]=none
customize_apply
assert_true 'verify with history' customize_verify
hist_out=$(HOME="$home" bash --norc -i -c "PROMPT_COMMAND=pl; source '$home/.bashrc'; source '$home/.bashrc'; printf '%s|%s' \"\$HISTSIZE\" \"\$PROMPT_COMMAND\"" 2>&1 </dev/null)
assert_eq 'history size and PROMPT_COMMAND (once, before the existing one)' '10000|history -a;pl' "$(tail -n1 <<<"$hist_out")"
assert_false 'no bind warning without a terminal' grep -q 'line editing' <<<"$hist_out"

# ---- Custom text banner (figlet)
assert_true 'banner text valid' valid_banner_text 'Server 01'
for bad in '' '   ' "$(printf 'a%.0s' {1..31})" $'tab\there'; do assert_false "banner text rejected: $(printf %q "$bad")" valid_banner_text "$bad"; done
banner_figlet() { printf ' _\n|X| %s\n' "$1"; }
FAKE_FIGLET=0
command_exists() { if [[ "$1" == figlet ]]; then [[ $FAKE_FIGLET == 1 ]]; else command -v "$1" >/dev/null 2>&1; fi; }
APT_UPDATED=1
apt_get() { FAKE_FIGLET=1; run apt-get "$@"; }
reset_commands
# custom entry is right after the 6 file banners: 7. Install figlet, text, change, new text, accept.
banner_choose >"$WORK/out" 2>&1 <<<$'7\ny\nprimo\n2\nIt\'s me\n1'
assert_contains 'figlet installed after confirmation' 'install -- figlet' "$(commands_run)"
assert_contains 'installation announced' 'serve il programma figlet' "$(cat "$WORK/out")"
assert_contains 'preview shows echo lines' "echo '|X| primo'" "$(cat "$WORK/out")"
assert_eq 'custom banner selected' custom "${CFG[BANNER]}"
assert_eq 'changed text kept' "It's me" "${CFG[BANNER_TEXT]}"
CFG["CUSTOM_MODULES:x"]=banner
block=$(custom_render_block x)
assert_contains 'custom banner embedded with escaped quote' "echo '|X| It'\\''s me'" "$block"
assert_eq 'custom banner prints the text' $' _\n|X| It\'s me' "$(bash -c "$(sed -n '/^echo/p' <<<"$block")")"
CFG[CUSTOM_USERS]=''
assert_contains 'plan mentions custom text' "«It's me»" "$(customize_plan)"

# Back from the preview returns to the list; declining figlet returns to the list too.
FAKE_FIGLET=0
banner_choose >/dev/null 2>&1 <<<$'7\nn\n8'
assert_eq 'figlet declined, then no banner' none "${CFG[BANNER]}"
FAKE_FIGLET=1
banner_choose >/dev/null 2>&1 <<<$'7\nciao\n0\n2'
assert_eq 'back from preview, then a file banner' TARS "${CFG[BANNER]}"
JACKTOOLS_DRY_RUN=1 FAKE_FIGLET=0
assert_rc 'no figlet in dry-run' 1 quiet banner_ensure_figlet
JACKTOOLS_DRY_RUN=0
finish_tests
