#!/usr/bin/env bash
# Menu di tmux con i temi powerline: la voce scelta lancia "plcolors <tema>".
# Lo apre la voce "Cambia tema" del menu col tasto destro sulla barra (~/.tmux.conf).
# $1 = client tmux su cui mostrare il menu.

dir="${XDG_CONFIG_HOME:-$HOME/.config}/powerline/colorschemes/tmux"
keys=(1 2 3 4 5 6 7 8 9 a b c e f g h i j k l)
current=$(sed -n 's/.*"colorscheme": "\([a-z0-9_]*\)".*/\1/p' "${dir%/colorschemes/tmux}/config.json" | head -n 1)

items=()
i=0
for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    label=$name
    [ "$name" = "$current" ] && label="$name  (attivo)"
    items+=("$label" "${keys[$i]:-}" "run-shell '\$HOME/.local/bin/plcolors $name >/dev/null'")
    i=$((i + 1))
done

if [ "${#items[@]}" -eq 0 ]; then
    tmux display-message "Nessun tema powerline installato"
    exit 0
fi
tmux display-menu -c "$1" -T "#[align=centre] Tema powerline " -x C -y C "${items[@]}"
