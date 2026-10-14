# jt-module: tmux-login-menu | Menu tmux al login: riprendi o crea una sessione (installa ~/.local/bin/tmux-login-menu.sh) | off
# Login shells only and outside tmux; the script is executed, never sourced, so it can
# never close the login shell. It exits on its own when tmux is missing.
if shopt -q login_shell && [ -t 0 ] && [ -t 1 ] && [ -z "${TMUX:-}" ] && [ -x "$HOME/.local/bin/tmux-login-menu.sh" ]; then
    "$HOME/.local/bin/tmux-login-menu.sh"
fi
