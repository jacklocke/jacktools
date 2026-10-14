# jt-module: drin | Drin: timer e sveglie da terminale, comando drin (installa ~/.local/bin/drin) | off
# ~/.local/bin is added to PATH only when missing (Ubuntu adds it at login only if it
# already existed), so the drin command works right away.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
esac
