# jt-module: locale | Lingua UTF-8 se il sistema non ne imposta una (serve a powerline in tmux) | on
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*|*utf-8*) ;;
    *) export LANG=C.UTF-8 ;;
esac
