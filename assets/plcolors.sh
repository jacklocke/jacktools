#!/usr/bin/env bash
#
# plcolors — anteprima e cambio dello schema di colori di powerline (barra tmux + prompt).
#
#   plcolors            galleria: barra e prompt di ogni schema, senza cambiare nulla
#   plcolors <nome>     applica lo schema a tmux e al prompt
#   plcolors --demo     fa scorrere gli schemi sulla barra vera (3 s ciascuno), poi ripristina
#
# Gli schemi sono generati da ~/.config/powerline/tools/gen-colorschemes.py.

PL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/powerline"
CONFIG="$PL_DIR/config.json"
SCHEMES_DIR="$PL_DIR/colorschemes/tmux"
# I segmenti custom vengono cercati in PL_DIR anche se config.json indica ~/.config
PATHS_OPT="common.paths=[\"$PL_DIR/segments\"]"
DEMO_DELAY=3

schemes() {
    local f
    for f in "$SCHEMES_DIR"/*.json; do basename "$f" .json; done
}

current() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ext"]["tmux"]["colorscheme"])' "$CONFIG"
}

# Converte gli attributi tmux #[fg=colourN,bg=colourM,bold] in sequenze ANSI.
tmux_to_ansi() {
    python3 -c '
import re, sys
def color(v, base):
    if v.startswith("colour"):
        return "%d;5;%s" % (base + 8, v[6:])
    if v.startswith("#"):
        return "%d;2;%d;%d;%d" % ((base + 8,) + tuple(int(v[i:i + 2], 16) for i in (1, 3, 5)))
    return str(base + 9)
def attrs(m):
    out = ["0"]
    for a in m.group(1).split(","):
        if a.startswith("fg="):
            out.append(color(a[3:], 30))
        elif a.startswith("bg="):
            out.append(color(a[3:], 40))
        elif a == "bold":
            out.append("1")
    return "\033[" + ";".join(out) + "m"
sys.stdout.write(re.sub(r"#\[([^]]*)\]", attrs, sys.stdin.read()) + "\033[0m")
'
}

gallery() {
    local cur s line cols
    cur=$(current)
    # Riga di separazione tra un tema e l'altro, larga quanto il terminale (max 80)
    cols=$(tput cols 2>/dev/null || echo 80)
    (( cols > 80 )) && cols=80
    printf -v line '%*s' "$cols" ''
    line=${line// /─}
    for s in $(schemes); do
        printf '\n\e[2m%s\e[0m\n  \e[1m%s\e[0m%s\n\n' "$line" "$s" "$([ "$s" = "$cur" ] && printf '  (attivo)')"
        # powerline-render, non il client: il demone riusa in cache il primo override ricevuto
        printf '  '
        powerline-render tmux right -c "$PATHS_OPT" -c "ext.tmux.colorscheme=$s" | tmux_to_ansi
        printf '\n'
        powerline-render shell aboveleft -c "$PATHS_OPT" -c "ext.shell.colorscheme=$s" --last-exit-code 1 --jobnum 1 | sed 's/^/  /'
        printf '\n'
    done
    printf '\n  Applica con: plcolors <nome>    Prova sulla barra: plcolors --demo\n\n'
}

apply() {
    python3 - "$CONFIG" "$1" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["ext"]["tmux"]["colorscheme"] = name
cfg["ext"]["shell"]["colorscheme"] = name
with open(path, "w") as f:
    json.dump(cfg, f, indent="\t")
    f.write("\n")
PY
    powerline-daemon --replace >/dev/null 2>&1
    # Ricaricare la config ricolora anche sessione e hostname (tmux li fissa al caricamento)
    if tmux list-sessions >/dev/null 2>&1; then
        tmux source-file "$HOME/.tmux.conf"
    fi
}

demo() {
    local orig s
    [ -n "${TMUX:-}" ] || { echo "plcolors --demo va lanciato dentro tmux" >&2; exit 1; }
    orig=$(current)
    trap 'apply "$orig"; tmux display-message "Ripristinato: $orig"; exit' INT TERM
    for s in $(schemes); do
        apply "$s"
        tmux display-message -d $((DEMO_DELAY * 1000)) "Schema: $s"
        echo "Schema: $s"
        sleep "$DEMO_DELAY"
    done
    apply "$orig"
    tmux display-message "Ripristinato: $orig"
    echo "Ripristinato: $orig"
}

case "${1:-}" in
    '') gallery ;;
    --demo) demo ;;
    -h | --help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        if [ -f "$SCHEMES_DIR/$1.json" ]; then
            apply "$1"
            echo "Schema attivo: $1"
        else
            echo "Schema sconosciuto: $1. Disponibili: $(schemes | tr '\n' ' ')" >&2
            exit 1
        fi
        ;;
esac
