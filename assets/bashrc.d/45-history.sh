# jt-module: history | Cronologia: freccia su/giù cerca i comandi che iniziano con quanto scritto, Ctrl-R con fzf (se installato) | off
# Bigger history with timestamps, saved after every command (no loss when a tmux pane is closed).
# Placed after powerline: history -a is prepended to its PROMPT_COMMAND.
HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT='%F %T  '
shopt -s histappend
case ";${PROMPT_COMMAND:-};" in
    *";history -a;"*) ;;
    *) PROMPT_COMMAND="history -a${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
# Line editing only on a real terminal (bind warns otherwise).
if [[ $- == *i* && -t 0 ]]; then
    bind '"\e[A": history-search-backward'
    bind '"\e[B": history-search-forward'
    bind '"\eOA": history-search-backward'
    bind '"\eOB": history-search-forward'
    bind 'set show-all-if-ambiguous on'
    bind 'set completion-ignore-case on'
    if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
        . /usr/share/doc/fzf/examples/key-bindings.bash
    fi
fi
