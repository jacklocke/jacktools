#!/usr/bin/env bash
#
# tmux-login-menu.sh — menu interattivo al login per agganciarsi a una
# sessione tmux esistente o crearne una nuova.
#
# Va ESEGUITO (non "sourced") da ~/.bash_profile: un "exit" qui dentro
# termina solo lo script e non chiude mai la shell di login.
# Dipendenze: solo bash e tmux.

TIMEOUT=5   # senza sessioni: secondi prima di creare e aprire la sessione A (0 = mai)
DRAIN=0.3   # secondi in cui la prima shell di una nuova sessione scarta l'input

# ---------------------------------------------------------------------------
# Avvio della prima shell di una nuova sessione (--pane-start)
# ---------------------------------------------------------------------------
# All'avvio tmux chiede al terminale chi è (ESC[c, ESC[>c). Alcuni terminali,
# per esempio Windows Terminal via SSH, rispondono due volte o in ritardo:
# tmux passa le risposte in più alla shell, che le mostra come caratteri
# sporchi (^[[?61;...c). Qui, senza eco, si attende DRAIN secondi, si scarta
# l'input arrivato e poi si avvia la normale shell di login.
if [ "$1" = --pane-start ]; then
    stty -echo 2>/dev/null
    sleep "$DRAIN" 2>/dev/null
    while IFS= read -rs -t 0.05 -n 4096 _; do :; done
    stty echo 2>/dev/null
    [ -x "${SHELL:-}" ] || SHELL=/bin/bash
    exec -l "$SHELL"
fi

# ---------------------------------------------------------------------------
# Controlli di avvio: se uno fallisce si esce subito e in silenzio
# ---------------------------------------------------------------------------

# 1. stdin e stdout devono essere terminali (niente scp, sftp, rsync,
#    "ssh host comando" o altri accessi non interattivi)
[ -t 0 ] && [ -t 1 ] || exit 0
# 2. non siamo già dentro tmux
[ -z "$TMUX" ] || exit 0
# 3. tmux è installato
command -v tmux >/dev/null 2>&1 || exit 0
# 4. il terminale è utilizzabile
case "$TERM" in '' | dumb) exit 0 ;; esac

# TIMEOUT non numerico: si torna al valore predefinito
[[ $TIMEOUT =~ ^[0-9]+$ ]] || TIMEOUT=3

# ---------------------------------------------------------------------------
# Sequenze di controllo del terminale (ANSI/VT100, equivalenti a tput)
# ---------------------------------------------------------------------------
CSI=$'\e['
EL="${CSI}K"        # cancella fino a fine riga        (tput el)
ED="${CSI}J"        # cancella fino a fine schermo     (tput ed)
REV="${CSI}7m"      # video inverso                    (tput rev)
RST="${CSI}0m"      # attributi normali                (tput sgr0)
HIDE="${CSI}?25l"   # nasconde il cursore              (tput civis)
SHOW="${CSI}?25h"   # mostra il cursore                (tput cnorm)

# Caratteri ammessi nel nome di una sessione
ALLOWED='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'
MAXLEN=32

# ---------------------------------------------------------------------------
# Stato globale
# ---------------------------------------------------------------------------
BLOCK_LINES=0        # righe occupate dal blocco disegnato (il cursore è sull'ultima)
ROWS=24 COLS=80      # dimensioni del terminale
TIMER_ON=0           # 1 = countdown attivo
REMAINING=$TIMEOUT   # secondi rimanenti del countdown
TIMER_JUST_STOPPED=0 # 1 = l'ultimo tasto ha appena fermato il timer
KEY= KEYCHAR=        # ultimo tasto letto
SEL=0 OFFSET=0       # riga selezionata e prima riga visibile del menu
S_NAME=() S_ATT=() S_WIN=()   # sessioni: nome, client collegati, finestre
NAMEW=4 ITEMW=16     # larghezze di colonna del menu

# ---------------------------------------------------------------------------
# Pulizia del terminale
# ---------------------------------------------------------------------------

# Porta il cursore all'inizio della prima riga del blocco
to_top() {
    printf '\r'
    # attenzione: "ESC[0A" in alcuni terminali sale comunque di una riga
    (( BLOCK_LINES > 1 )) && printf '%s%dA' "$CSI" $(( BLOCK_LINES - 1 ))
}

# Cancella le righe del menu e lascia il cursore dove il menu iniziava
clear_block() {
    (( BLOCK_LINES > 0 )) || return 0
    to_top
    printf '%s' "$ED"
    BLOCK_LINES=0
}

# Ripristina cursore e stty e pulisce l'area del menu
cleanup() {
    clear_block
    printf '%s' "$SHOW"
    [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" 2>/dev/null
}

STTY_SAVED=$(stty -g 2>/dev/null)
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Niente eco dei tasti premuti tra una lettura e l'altra
stty -echo 2>/dev/null

# ---------------------------------------------------------------------------
# Disegno
# ---------------------------------------------------------------------------

# Legge le dimensioni del terminale (stty size → "righe colonne")
term_size() {
    local s
    s=$(stty size 2>/dev/null)
    ROWS=${s% *}
    COLS=${s#* }
    [[ $ROWS =~ ^[0-9]+$ ]] && (( ROWS > 0 )) || ROWS=24
    [[ $COLS =~ ^[0-9]+$ ]] && (( COLS > 0 )) || COLS=80
}

# Tronca il testo alla larghezza del terminale (risultato in REPLY),
# così nessuna riga va a capo e il conteggio delle righe resta esatto
fit() {
    REPLY=$1
    (( ${#REPLY} > COLS - 1 )) && REPLY=${REPLY:0:COLS-1}
}

# Disegna un blocco di righe sovrascrivendo quello precedente, riga per
# riga (niente cancellazione completa → niente sfarfallio). Alla fine il
# cursore resta sull'ultima riga.
draw_block() {
    local line first=1
    to_top
    for line in "$@"; do
        (( first )) || printf '\n'
        first=0
        printf '%s%s' "$line" "$EL"
    done
    printf '%s' "$ED"   # elimina eventuali righe avanzate dal blocco precedente
    BLOCK_LINES=$#
}

# Testo del countdown (in REPLY)
countdown_text() {
    fit "La sessione A parte tra ${REMAINING}s — premi un tasto per restare"
}

# Riscrive SOLO la riga del countdown (è sempre l'ultima del blocco)
update_countdown() {
    countdown_text
    printf '\r%s%s' "$REPLY" "$EL"
}

# ---------------------------------------------------------------------------
# Lettura dei tasti
# ---------------------------------------------------------------------------

# Legge un tasto e imposta KEY a: UP DOWN LEFT RIGHT ENTER ESC BACKSPACE
# CHAR (carattere in KEYCHAR) OTHER oppure TIMEOUT.
# $1 = timeout in secondi (facoltativo)
read_key() {
    local k rest status
    if [ -n "$1" ]; then
        IFS= read -rsn1 -t "$1" k
    else
        IFS= read -rsn1 k
    fi
    status=$?
    if (( status > 128 )); then KEY=TIMEOUT; return; fi
    (( status == 0 )) || exit 0   # fine dell'input: terminale chiuso

    case "$k" in
        '' | $'\r' | $'\n') KEY=ENTER ;;
        $'\x7f' | $'\x08')  KEY=BACKSPACE ;;
        $'\e')
            # Esc da solo o inizio di una sequenza (ESC [ A, ESC O A, ...)?
            rest=
            IFS= read -rsn2 -t 0.05 rest
            case "$rest" in
                '')          KEY=ESC ;;
                '[A' | 'OA') KEY=UP ;;
                '[B' | 'OB') KEY=DOWN ;;
                '[C' | 'OC') KEY=RIGHT ;;
                '[D' | 'OD') KEY=LEFT ;;
                *)
                    # altra sequenza (Canc, F1, Alt+x...): si scarta il resto
                    KEY=OTHER
                    while IFS= read -rsn1 -t 0.01 _; do :; done
                    ;;
            esac
            ;;
        *) KEY=CHAR; KEYCHAR=$k ;;
    esac
}

# Attende un tasto gestendo il countdown di inattività.
# Il primo tasto premuto ferma il timer per sempre (TIMER_JUST_STOPPED=1);
# a tempo scaduto KEY=EXPIRED.
wait_key() {
    TIMER_JUST_STOPPED=0
    if (( ! TIMER_ON )); then
        read_key
        return
    fi
    while :; do
        read_key 1
        if [ "$KEY" != TIMEOUT ]; then
            TIMER_ON=0
            TIMER_JUST_STOPPED=1
            return
        fi
        (( REMAINING-- ))
        if (( REMAINING <= 0 )); then TIMER_ON=0; KEY=EXPIRED; return; fi
        update_countdown
    done
}

# ---------------------------------------------------------------------------
# Sessioni tmux
# ---------------------------------------------------------------------------

# Carica l'elenco delle sessioni e calcola le larghezze di colonna
load_sessions() {
    local name att win txt
    S_NAME=() S_ATT=() S_WIN=()
    while IFS=$'\t' read -r name att win; do
        [ -n "$name" ] || continue
        S_NAME+=("$name") S_ATT+=("$att") S_WIN+=("$win")
    done < <(tmux list-sessions -F $'#{session_name}\t#{session_attached}\t#{session_windows}' 2>/dev/null)

    NAMEW=4
    for name in "${S_NAME[@]}"; do
        (( ${#name} > NAMEW )) && NAMEW=${#name}
    done
    (( NAMEW > MAXLEN )) && NAMEW=$MAXLEN

    ITEMW=16   # lunghezza di "+ Nuova sessione"
    for (( i = 0; i < ${#S_NAME[@]}; i++ )); do
        item_text "$i"; txt=$REPLY
        (( ${#txt} > ITEMW )) && ITEMW=${#txt}
    done
}

# Testo della riga di menu numero $1 (in REPLY)
item_text() {
    if (( $1 < ${#S_NAME[@]} )); then
        printf -v REPLY '%-*s   finestre: %-3s client collegati: %s' \
            "$NAMEW" "${S_NAME[$1]}" "${S_WIN[$1]}" "${S_ATT[$1]}"
    else
        REPLY='+ Nuova sessione'
    fi
}

# Prima lettera maiuscola A–Z non usata come nome di sessione (in REPLY,
# vuota se sono tutte occupate)
default_name() {
    local l n used
    for l in {A..Z}; do
        used=0
        for n in "${S_NAME[@]}"; do
            [ "$n" = "$l" ] && { used=1; break; }
        done
        (( used )) || { REPLY=$l; return; }
    done
    REPLY=
}

# Percorso assoluto di questo script, per --pane-start
SELF=$(readlink -f -- "$0" 2>/dev/null) || SELF=

# Crea la sessione $1 (o si collega se esiste già) con la prima shell avviata
# da --pane-start
new_session() {
    if [ -n "$SELF" ] && [ -x "$SELF" ]; then
        start_tmux new-session -A -s "$1" "$SELF" --pane-start
    fi
    start_tmux new-session -A -s "$1"
}

# Lancia tmux con gli argomenti dati dopo aver ripulito il terminale.
# Niente exec: al detach (o alla fine della sessione) lo script termina
# e si torna alla normale shell bash.
start_tmux() {
    clear_block
    printf '%s' "$SHOW"
    [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" 2>/dev/null
    tmux "$@"
    exit $?
}

# ---------------------------------------------------------------------------
# Caso A: nessuna sessione esistente
# ---------------------------------------------------------------------------
screen_empty() {
    local need=1 lines
    while :; do
        if (( need )); then
            term_size
            lines=()
            fit "Nessuna sessione tmux."; lines+=("$REPLY")
            fit "Premi → o Invio per creare la sessione A, ← o Esc per uscire."; lines+=("$REPLY")
            (( TIMER_ON )) && { countdown_text; lines+=("$REPLY"); }
            draw_block "${lines[@]}"
            need=0
        fi
        wait_key
        (( TIMER_JUST_STOPPED )) && need=1   # rimuove la riga del countdown
        case "$KEY" in
            # -A: se nel frattempo A è stata creata, ci si collega
            RIGHT | ENTER | EXPIRED) new_session A ;;
            LEFT | ESC)    exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Caso B: menu delle sessioni
# ---------------------------------------------------------------------------
draw_list() {
    local n fixed vis i title lines
    term_size
    n=$(( ${#S_NAME[@]} + 1 ))

    # righe disponibili per la lista: tolte titolo, aiuto, countdown e una
    # riga di margine, così il blocco non supera mai l'altezza del terminale
    fixed=3
    (( TIMER_ON )) && (( fixed++ ))
    vis=$(( ROWS - fixed ))
    (( vis < 1 )) && vis=1
    (( vis > n )) && vis=$n

    # scorrimento: la selezione resta sempre visibile
    (( SEL < OFFSET )) && OFFSET=$SEL
    (( SEL >= OFFSET + vis )) && OFFSET=$(( SEL - vis + 1 ))
    (( OFFSET > n - vis )) && OFFSET=$(( n - vis ))
    (( OFFSET < 0 )) && OFFSET=0

    lines=()
    title="Sessioni tmux"
    (( vis < n )) && title+=" ($(( SEL + 1 ))/$n)"
    fit "$title:"; lines+=("$REPLY")

    for (( i = OFFSET; i < OFFSET + vis; i++ )); do
        item_text "$i"
        printf -v REPLY ' %-*s ' "$ITEMW" "$REPLY"   # larghezza uniforme per l'evidenziazione
        fit "$REPLY"
        if (( i == SEL )); then
            lines+=("$REV$REPLY$RST")
        else
            lines+=("$REPLY")
        fi
    done

    fit "↑/↓ scegli · → o Invio conferma · ← o Esc esci"; lines+=("$REPLY")
    (( TIMER_ON )) && { countdown_text; lines+=("$REPLY"); }
    draw_block "${lines[@]}"
}

screen_list() {
    local need=1 n
    while :; do
        n=$(( ${#S_NAME[@]} + 1 ))
        (( SEL > n - 1 )) && SEL=$(( n - 1 ))
        if (( need )); then
            printf '%s' "$HIDE"
            draw_list
            need=0
        fi
        wait_key
        (( TIMER_JUST_STOPPED )) && need=1   # rimuove la riga del countdown
        case "$KEY" in
            UP)   (( SEL > 0 ))     && { (( SEL-- )); need=1; } ;;
            DOWN) (( SEL < n - 1 )) && { (( SEL++ )); need=1; } ;;
            RIGHT | ENTER)
                if (( SEL < n - 1 )); then
                    start_tmux attach-session -t "=${S_NAME[SEL]}"
                fi
                input_name   # ritorna solo se l'utente torna al menu
                load_sessions
                need=1
                ;;
            LEFT | ESC) exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Inserimento del nome di una nuova sessione
# ---------------------------------------------------------------------------
input_name() {
    local name= warn= def final lines
    load_sessions
    default_name; def=$REPLY
    printf '%s' "$SHOW"

    while :; do
        term_size
        lines=()
        fit "Nuova sessione tmux — lettere, cifre, _ e - (max $MAXLEN caratteri)"; lines+=("$REPLY")
        fit "Invio conferma · Esc torna al menu (anche ← a campo vuoto)"; lines+=("$REPLY")
        # riga dedicata agli avvisi (vuota se non ce ne sono)
        if [ -n "$warn" ]; then fit "! $warn"; else REPLY=; fi
        lines+=("$REPLY")
        # il prompt è l'ultima riga: il cursore resta subito dopo il testo
        if [ -n "$def" ]; then
            fit "Nome (Invio a vuoto = $def): $name"
        else
            fit "Nome: $name"
        fi
        lines+=("$REPLY")
        draw_block "${lines[@]}"

        read_key
        warn=
        case "$KEY" in
            ESC) return ;;
            LEFT) [ -z "$name" ] && return ;;   # con testo ← è ignorata
            BACKSPACE) name=${name%?} ;;
            ENTER)
                final=${name:-$def}
                if [ -z "$final" ]; then
                    warn="Inserisci un nome: le lettere A–Z sono già tutte usate."
                elif tmux has-session -t "=$final" 2>/dev/null; then
                    warn="Esiste già una sessione \"$final\": scegli un altro nome."
                else
                    new_session "$final"
                fi
                ;;
            CHAR)
                if [[ $ALLOWED != *"$KEYCHAR"* ]]; then
                    warn="Non ammesso: solo lettere, cifre, _ e - (tmux rifiuta . e :, spazi no)"
                elif (( ${#name} >= MAXLEN )); then
                    warn="Lunghezza massima: $MAXLEN caratteri."
                else
                    name+=$KEYCHAR
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Avvio
# ---------------------------------------------------------------------------
printf '%s' "$HIDE"
load_sessions
if (( ${#S_NAME[@]} == 0 )); then
    # countdown solo senza sessioni: con l'elenco si attende senza limite
    (( TIMEOUT > 0 )) && TIMER_ON=1
    screen_empty
else
    screen_list
fi
