#!/usr/bin/env bash
# drin.sh — timer e sveglie da terminale con figlet e at.
#
# - "A video": conto alla rovescia in primo piano, con figlet.
# - "In background": il job viene affidato ad `at` e scatta anche se chiudi
#   il menu; l'output viene scritto sul terminale da cui l'hai programmato
#   (se è ancora aperto), altrimenti inviato con `wall`.
#

set -u

# ------------------------------------------------------------ impostazioni
# Valori proposti di default; si possono cambiare qui o da variabile
# d'ambiente, es.: DRIN_DEFAULT_ALARM=07:30 ./drin.sh
DRIN_DEFAULT_ALARM="${DRIN_DEFAULT_ALARM:-18:00}"          # sveglia: HH:MM
DRIN_DEFAULT_TIMER="${DRIN_DEFAULT_TIMER:-1h}"             # timer: 1h, 25m, 90s...
DRIN_DEFAULT_TEXT="${DRIN_DEFAULT_TEXT:-Drin! Tempo scaduto}"
DRIN_DEFAULT_FIGLET="${DRIN_DEFAULT_FIGLET:-DRIN!}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/drin"
LOG_FILE="$STATE_DIR/drin.log"
OS="$(uname -s)"

if date --version >/dev/null 2>&1; then GNU_DATE=1; else GNU_DATE=0; fi
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- utilità

# epoch_fmt EPOCH FORMATO
epoch_fmt() {
    if [ "$GNU_DATE" = 1 ]; then date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}

# str_to_epoch "YYYY-MM-DD HH:MM"
str_to_epoch() {
    if [ "$GNU_DATE" = 1 ]; then
        date -d "$1" +%s 2>/dev/null
    else
        date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" +%s 2>/dev/null
    fi
}

# Data nel formato di atq ("Sat Oct 10 09:09:00 2026") -> epoch
atq_to_epoch() {
    if [ "$GNU_DATE" = 1 ]; then
        LC_ALL=C date -d "$1" +%s 2>/dev/null
    else
        LC_ALL=C date -j -f "%a %b %d %T %Y" "$1" +%s 2>/dev/null
    fi
}

now() { date +%s; }

# Durata leggibile: 3725 -> 01:02:05, 65 -> 01:05
fmt_dur() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    else
        printf '%02d:%02d' $((s / 60)) $((s % 60))
    fi
}

# Converte "10", "90s", "5m", "1h30m", "1h 5m 30s", "mm:ss", "hh:mm:ss" in secondi.
# Un numero senza unità vale minuti.
parse_duration() {
    local s total=0 n
    s=$(printf '%s' "$1" | tr -d ' \t' | tr 'HMS' 'hms')
    if [[ $s =~ ^[0-9]+$ ]]; then
        total=$((10#$s * 60))
    elif [[ $s =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
        total=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
    elif [[ $s =~ ^([0-9]+):([0-9]{1,2})$ ]]; then
        total=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
    else
        while [[ $s =~ ^([0-9]+)([hms])(.*)$ ]]; do
            n=$((10#${BASH_REMATCH[1]}))
            case ${BASH_REMATCH[2]} in
                h) total=$((total + n * 3600)) ;;
                m) total=$((total + n * 60)) ;;
                s) total=$((total + n)) ;;
            esac
            s=${BASH_REMATCH[3]}
        done
        [ -n "$s" ] && return 1
    fi
    [ "$total" -gt 0 ] || return 1
    echo "$total"
}

# Converte "HH:MM" o "YYYY-MM-DD HH:MM" in epoch. Un orario già passato oggi
# viene interpretato come domani.
parse_alarm() {
    local in day hm t
    in=$(printf '%s' "$1" | sed 's/^ *//; s/ *$//; s/\./:/g')
    if [[ $in =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{1,2}:[0-9]{2})$ ]]; then
        day=${BASH_REMATCH[1]} hm=${BASH_REMATCH[2]}
    elif [[ $in =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
        day=$(date +%Y-%m-%d) hm=$in
    else
        return 1
    fi
    [[ $hm =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    t=$(str_to_epoch "$day $hm") || return 1
    [ -n "$t" ] || return 1
    if [ "$t" -le "$(now)" ]; then
        # Solo HH:MM -> domani; data esplicita nel passato -> errore
        [[ $in =~ ^[0-9]{4}- ]] && return 1
        day=$(epoch_fmt $(($(now) + 86400)) %Y-%m-%d)
        t=$(str_to_epoch "$day $hm") || return 1
    fi
    echo "$t"
}

# Quoting POSIX con apici singoli (il job di at gira con /bin/sh, che su
# Ubuntu è dash: printf %q produrrebbe $'...' non supportato).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

term_cols() { tput cols 2>/dev/null || echo 80; }
term_lines() { tput lines 2>/dev/null || echo 24; }

clock_banner() { figlet -w "$(term_cols)" "$(date +%H:%M)"; }

# --------------------------------------------------------------- interfaccia
# Menu disegnati direttamente in bash (frecce, Invio, oppure il numero della
# voce per sceglierla subito). Le funzioni vengono chiamate dentro $(...):
# tutto ciò che si vede va su stderr, solo la scelta su stdout.

C_REV=$(tput rev 2>/dev/null) C_BOLD=$(tput bold 2>/dev/null) C_OFF=$(tput sgr0 2>/dev/null)

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ui_menu TITOLO TESTO tag voce [tag voce ...]
# Con TESTO "@clock" in testa compare l'orologio figlet, aggiornato ogni secondo.
ui_menu() {
    local title=$1 text=$2 n=0 sel=1 i key rest buf="" exact pref
    local -a tags items
    shift 2
    while [ $# -gt 0 ]; do n=$((n + 1)); tags[n]=$1; items[n]=$2; shift 2; done
    tput civis >&2 2>/dev/null
    clear >&2
    while :; do
        {
            tput cup 0 0 2>/dev/null
            printf '%s== %s ==%s\n\n' "$C_BOLD" "$title" "$C_OFF"
            if [ "$text" = @clock ]; then
                clock_banner
                date '+%A %d %B %Y'
            else
                printf '%s\n' "$text"
            fi
            echo
            for ((i = 1; i <= n; i++)); do
                if [ "$i" = "$sel" ]; then
                    printf '%s > %s) %s %s\n' "$C_REV" "${tags[i]}" "${items[i]}" "$C_OFF"
                else
                    printf '   %s) %s\n' "${tags[i]}" "${items[i]}"
                fi
            done
            printf '\n↑/↓ sposta · Invio conferma · numero = scelta diretta · q indietro\n'
            tput ed 2>/dev/null
        } >&2

        if ! IFS= read -r -s -n 1 -t 1 key; then
            # timeout (ridisegna l'orologio); una scelta numerica in sospeso,
            # es. "1" quando esiste anche "10", viene confermata
            [ -n "$buf" ] && [ "$(lower "${tags[sel]}")" = "$buf" ] && break
            buf=""
            continue
        fi
        case $key in
            "") break ;;                                   # Invio
            $'\e')
                rest=""
                IFS= read -r -s -n 2 -t 1 rest
                case $rest in
                    "[A"|"OA") sel=$((sel > 1 ? sel - 1 : n)) ;;
                    "[B"|"OB") sel=$((sel < n ? sel + 1 : 1)) ;;
                    "") tput cnorm >&2 2>/dev/null; return 1 ;; # Esc da solo
                esac
                buf="" ;;
            k) sel=$((sel > 1 ? sel - 1 : n)); buf="" ;;
            j) sel=$((sel < n ? sel + 1 : 1)); buf="" ;;
            q|Q) tput cnorm >&2 2>/dev/null; return 1 ;;
            *)
                # scelta diretta: confronta con i tag (anche a più cifre)
                buf=$buf$(lower "$key")
                exact=0 pref=0
                for ((i = 1; i <= n; i++)); do
                    case $(lower "${tags[i]}") in
                        "$buf") exact=$i ;;
                        "$buf"*) pref=$((pref + 1)) ;;
                    esac
                done
                if [ "$exact" -gt 0 ] && [ "$pref" -eq 0 ]; then
                    sel=$exact; break                      # univoca: scelta subito
                elif [ "$exact" -gt 0 ]; then
                    sel=$exact                             # attende altra cifra o timeout
                elif [ "$pref" -eq 0 ]; then
                    buf=""                                 # nessuna voce: ignora
                fi ;;
        esac
    done
    tput cnorm >&2 2>/dev/null
    echo "${tags[sel]}"
}

# ui_input TESTO [DEFAULT] — con bash 4+ il default è già scritto e modificabile
ui_input() {
    local v
    printf '\n%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        read -r -e -p "> " -i "$2" v || return 1
    elif [ -n "${2:-}" ]; then
        read -r -e -p "[$2] > " v || return 1
        v=${v:-$2}
    else
        read -r -e -p "> " v || return 1
    fi
    echo "$v"
}

ui_yesno() {
    local a
    printf '\n%s\n' "$1" >&2
    read -r -s -n 1 -p "[s/N] " a || return 1
    echo >&2
    case $a in [sSyY]) return 0 ;; *) return 1 ;; esac
}

ui_msg() {
    printf '\n%s\n\n' "$1" >&2
    read -r -s -n 1 -p "Premi un tasto per continuare..." _
    echo >&2
}

# --------------------------------------------------------------- dipendenze

install_cmd() { # stampa il comando di installazione per i pacchetti dati
    if [ "$OS" = Darwin ]; then
        have brew && echo "brew install $*"
    elif have apt-get; then echo "sudo apt-get install -y $*"
    elif have dnf; then echo "sudo dnf install -y $*"
    elif have pacman; then echo "sudo pacman -S --needed $*"
    elif have zypper; then echo "sudo zypper install -y $*"
    fi
}

check_deps() {
    local missing="" cmd
    have figlet || missing="figlet"
    # macOS ha già `at` di serie; su Linux il pacchetto si chiama "at"
    have at || missing="$missing at"
    missing=${missing# }

    if [ -n "$missing" ]; then
        cmd=$(install_cmd $missing)
        if [ -z "$cmd" ]; then
            echo "Mancano: $missing. Installali con il gestore pacchetti del sistema e riprova." >&2
            exit 1
        fi
        if ui_yesno "Questi programmi non sono installati: $missing

Vuoi installarli ora con:
  $cmd"; then
            clear
            echo "+ $cmd"
            eval "$cmd" || { echo "Installazione non riuscita." >&2; exit 1; }
            hash -r
        else
            echo "drin richiede: $missing. Uscita." >&2
            exit 1
        fi
        for c in figlet at; do
            have "$c" || { echo "$c ancora non disponibile." >&2; exit 1; }
        done
    fi

    check_at_daemon
}

# `at` non serve a nulla se il demone che esegue i job è spento.
check_at_daemon() {
    if [ "$OS" = Darwin ]; then
        # Su macOS atrun è disattivato di default.
        launchctl print system/com.apple.atrun >/dev/null 2>&1 && return
        local cmd="sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.atrun.plist"
        if ui_yesno "Su macOS il servizio atrun (che esegue i job di at) è disattivato.
Senza, timer e sveglie in background non scattano.

Attivarlo ora con:
  $cmd"; then
            clear; echo "+ $cmd"; eval "$cmd"
        fi
    elif have systemctl && [ -d /run/systemd/system ]; then
        systemctl is-active --quiet atd && return
        local cmd="sudo systemctl enable --now atd"
        if ui_yesno "Il servizio atd non è attivo: timer e sveglie in background non scatterebbero.

Avviarlo ora con:
  $cmd"; then
            clear; echo "+ $cmd"; eval "$cmd"
        fi
    fi
}

# ------------------------------------------------------------------ azioni

ACTION_TYPE="" ACTION_ARG="" ACTION_DESC=""

choose_action() {
    local c
    c=$(ui_menu "Azione" "Cosa deve succedere allo scadere?" \
        1 "Mostra un testo (echo)" \
        2 "Mostra un testo grande (figlet)" \
        3 "Esegui un comando") || return 1
    case $c in
        1) ACTION_TYPE="echo"
           ACTION_ARG=$(ui_input "Testo da mostrare:" "$DRIN_DEFAULT_TEXT") || return 1 ;;
        2) ACTION_TYPE="figlet"
           ACTION_ARG=$(ui_input "Testo da mostrare con figlet:" "$DRIN_DEFAULT_FIGLET") || return 1 ;;
        3) ACTION_TYPE="cmd"
           ACTION_ARG=$(ui_input "Comando da eseguire (sintassi bash):") || return 1 ;;
        *) return 1 ;;
    esac
    [ -n "$ACTION_ARG" ] || return 1
    ACTION_DESC="$ACTION_TYPE: $(printf '%s' "$ACTION_ARG" | tr '\n' ' ' | cut -c1-40)"
}

run_action() { # in primo piano
    printf '\a'
    case $ACTION_TYPE in
        echo)   printf '%s\n' "$ACTION_ARG" ;;
        figlet) figlet -w "$(term_cols)" "$ACTION_ARG" ;;
        cmd)    bash -c "$ACTION_ARG" ;;
    esac
}

# ------------------------------------------------------------ primo piano

# countdown_screen TARGET MODO(timer|alarm) ETICHETTA ; ritorna 1 se annullato
countdown_screen() {
    local target=$1 mode=$2 label=$3 t rem k
    tput civis 2>/dev/null
    clear
    while :; do
        t=$(now)
        rem=$((target - t))
        [ "$rem" -le 0 ] && break
        tput cup 0 0 2>/dev/null || clear
        printf '%s\n\n' "$label"
        if [ "$mode" = timer ]; then
            figlet -w "$(term_cols)" "$(fmt_dur "$rem")"
            printf 'Scade alle %s\n' "$(epoch_fmt "$target" %H:%M:%S)"
        else
            figlet -w "$(term_cols)" "$(date +%H:%M:%S)"
            printf 'Sveglia alle %s — mancano %s\n' \
                "$(epoch_fmt "$target" '%H:%M (%d/%m)')" "$(fmt_dur "$rem")"
        fi
        printf '\n[q] annulla\n'
        tput ed 2>/dev/null
        if read -r -s -n 1 -t 1 k; then
            case $k in q|Q) tput cnorm 2>/dev/null; return 1 ;; esac
        fi
    done
    tput cnorm 2>/dev/null
    clear
    run_action
    printf '\n'
    read -r -s -n 1 -p "Premi un tasto per tornare al menu..." k
    return 0
}

live_clock() {
    local k
    tput civis 2>/dev/null
    clear
    while :; do
        tput cup 0 0 2>/dev/null || clear
        figlet -w "$(term_cols)" "$(date +%H:%M:%S)"
        printf '%s\n\n[q] torna al menu\n' "$(date '+%A %d %B %Y')"
        tput ed 2>/dev/null
        if read -r -s -n 1 -t 1 k; then
            case $k in q|Q) tput cnorm 2>/dev/null; return ;; esac
        fi
    done
}

# ------------------------------------------------------------- background

# Testo del job per at (POSIX sh). Il job parte al minuto del target (at ha
# risoluzione al minuto) e poi dorme fino al secondo esatto. Se il file token
# è stato rimosso (annullamento) non fa nulla, anche se stava già dormendo.
build_job() {
    local target=$1 token=$2 desc=$3 tty_dev=$4 action v
    case $ACTION_TYPE in
        echo)   action="printf '%s\\n' $(sq "$ACTION_ARG")" ;;
        figlet) action="$(sq "$(command -v figlet)") -w $(term_cols) $(sq "$ACTION_ARG")" ;;
        cmd)    action="$(sq "$(command -v bash)") -c $(sq "$ACTION_ARG")" ;;
    esac
    echo "# drin: $desc"
    # at non conserva DISPLAY: utile se il comando apre finestre o notifiche
    for v in DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR; do
        [ -n "${!v:-}" ] && echo "$v=$(sq "${!v}"); export $v"
    done
    cat <<EOF
DRIN_TOKEN=$(sq "$token")
DRIN_TTY=$(sq "$tty_dev")
DRIN_LOG=$(sq "$LOG_FILE")
n=\$(date +%s)
[ $target -gt "\$n" ] && sleep \$(($target - n))
[ -e "\$DRIN_TOKEN" ] || exit 0
rm -f "\$DRIN_TOKEN"
drin_action() {
    printf '\\a\\n*** drin — %s ***\\n' "\$(date +%H:%M:%S)"
    $action
}
if [ -n "\$DRIN_TTY" ] && [ -w "\$DRIN_TTY" ]; then
    drin_action > "\$DRIN_TTY" 2>&1
EOF
    if [ "$ACTION_TYPE" = cmd ]; then
        echo 'else'
        echo '    drin_action >> "$DRIN_LOG" 2>&1'
    else
        echo 'else'
        echo '    drin_action 2>&1 | wall'
    fi
    echo 'fi'
}

# schedule_job TARGET DESCRIZIONE
schedule_job() {
    local target=$1 desc=$2 token tty_dev minute out id
    mkdir -p "$STATE_DIR/jobs"
    token="$STATE_DIR/jobs/$target-$$-$RANDOM"
    tty_dev=$(tty 2>/dev/null) || tty_dev=""
    desc="[$(epoch_fmt "$target" '%d/%m %H:%M:%S')] $desc"

    # il token va creato prima: un job molto breve potrebbe partire subito
    printf '?\n%s\n%s\n' "$target" "$desc" > "$token"
    minute=$((target - target % 60))
    if [ "$minute" -le "$(now)" ]; then
        out=$(build_job "$target" "$token" "$desc" "$tty_dev" | at now 2>&1)
    else
        out=$(build_job "$target" "$token" "$desc" "$tty_dev" | at -t "$(epoch_fmt "$minute" %Y%m%d%H%M)" 2>&1)
    fi
    id=$(printf '%s\n' "$out" | sed -n 's/^job \([0-9][0-9]*\) .*/\1/p' | head -n 1)
    if [ -z "$id" ]; then
        rm -f "$token"
        ui_msg "Errore nel programmare il job con at:

$out"
        return 1
    fi
    [ -e "$token" ] && printf '%s\n%s\n%s\n' "$id" "$target" "$desc" > "$token"
    ui_msg "Programmato (job at n. $id):
$desc

L'output comparirà su ${tty_dev:-wall}."
}

# ---------------------------------------------------------- job programmati
#
# Fonti: `atq` (tutti i job at dell'utente, anche non creati da drin) e i
# file token di drin, che coprono anche i job già partiti che stanno
# dormendo fino al secondo esatto (non più cancellabili con il solo atrm).
# Risultato negli array paralleli J_ID J_TGT J_DESC J_TOKEN (indice da 1).

J_N=0
J_ID=() J_TGT=() J_DESC=() J_TOKEN=()

# Primo comando "utile" di un job at non creato da drin
at_job_command() {
    at -c "$1" 2>/dev/null |
        sed -n '/^}$/,$p' | sed '1d' |
        grep -v -e '^\${SHELL' -e '^marcinDELIMITER' -e '^[[:space:]]*$' |
        head -n 1 | cut -c1-60
}

# Aggiunge un job agli array: add_job ID TARGET DESCRIZIONE TOKEN
add_job() {
    J_N=$((J_N + 1))
    J_ID[J_N]=$1 J_TGT[J_N]=$2 J_DESC[J_N]=$3 J_TOKEN[J_N]=$4
}

collect_jobs() {
    local line id f tid target desc t i j found script tmp
    J_N=0 J_ID=() J_TGT=() J_DESC=() J_TOKEN=()
    t=$(now)

    # 1) token di drin (pulendo quelli orfani: job rimosso a mano o scaduto)
    for f in "$STATE_DIR"/jobs/*; do
        [ -f "$f" ] || continue
        tid="" target="" desc=""
        { read -r tid; read -r target; read -r desc; } < "$f"
        if [ "${target:-0}" -lt $((t - 120)) ]; then rm -f "$f"; continue; fi
        add_job "$tid" "$target" "$desc" "$f"
    done

    # 2) job di atq non già coperti da un token: di drin (marcatore nel
    #    testo del job, es. creati da un altro utente/state dir) o esterni
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        id=${line%%[[:space:]]*}
        found=0
        for ((i = 1; i <= J_N; i++)); do
            [ "${J_ID[i]}" = "$id" ] && found=1 && break
        done
        [ "$found" = 1 ] && continue
        script=$(at -c "$id" 2>/dev/null)
        desc=$(printf '%s\n' "$script" | sed -n 's/^# drin: //p' | head -n 1)
        if [ -n "$desc" ]; then
            target=$(printf '%s\n' "$script" | sed -n 's/^\[ \([0-9][0-9]*\) -gt .*/\1/p' | head -n 1)
        else
            desc="(esterno) $(at_job_command "$id")"
            # "Sat Oct 10 09:09:00 2026 a jack" -> data senza coda e utente
            target=$(atq_to_epoch "$(printf '%s' "${line#*[[:space:]]}" | sed 's/ [a-zA-Z=] [^ ]*$//')")
        fi
        add_job "$id" "${target:-0}" "$desc" ""
    done < <(atq 2>/dev/null)

    # 3) ordina per scadenza (insertion sort, pochi elementi)
    for ((i = 2; i <= J_N; i++)); do
        for ((j = i; j > 1; j--)); do
            [ "${J_TGT[j - 1]}" -le "${J_TGT[j]}" ] && break
            tmp=${J_ID[j]};    J_ID[j]=${J_ID[j - 1]};       J_ID[j - 1]=$tmp
            tmp=${J_TGT[j]};   J_TGT[j]=${J_TGT[j - 1]};     J_TGT[j - 1]=$tmp
            tmp=${J_DESC[j]};  J_DESC[j]=${J_DESC[j - 1]};   J_DESC[j - 1]=$tmp
            tmp=${J_TOKEN[j]}; J_TOKEN[j]=${J_TOKEN[j - 1]}; J_TOKEN[j - 1]=$tmp
        done
    done
}

# Riga leggibile per il job i: "#5  10/10 10:16:11 (tra 59:59)  Sveglia → ..."
job_line() {
    local i=$1 t when
    t=$(now)
    if [ "${J_TGT[i]}" -eq 0 ]; then
        when="data sconosciuta"
    elif [ "${J_TGT[i]}" -gt "$t" ]; then
        when="$(epoch_fmt "${J_TGT[i]}" '%d/%m %H:%M:%S') (tra $(fmt_dur $((J_TGT[i] - t))))"
    else
        when="$(epoch_fmt "${J_TGT[i]}" '%d/%m %H:%M:%S') (in corso)"
    fi
    # la descrizione di drin inizia con "[gg/mm hh:mm:ss] ": già in $when
    printf '#%-4s %s  %s' "${J_ID[i]}" "$when" "$(printf '%s' "${J_DESC[i]}" | sed 's/^\[[^]]*\] //')"
}

# cancel_job INDICE
cancel_job() {
    local i=$1
    [ -n "${J_TOKEN[i]}" ] && rm -f "${J_TOKEN[i]}"
    [ "${J_ID[i]}" != "?" ] && atrm "${J_ID[i]}" 2>/dev/null
    return 0
}

# Elenco testuale (anche per --list)
print_jobs() {
    local i
    collect_jobs
    if [ "$J_N" -eq 0 ]; then
        echo "Nessun timer o sveglia programmati."
        return
    fi
    for ((i = 1; i <= J_N; i++)); do
        job_line "$i"; echo
    done
}

# Annulla per numero di job at (per --cancel)
cancel_by_id() {
    local i
    collect_jobs
    for ((i = 1; i <= J_N; i++)); do
        if [ "${J_ID[i]}" = "$1" ]; then
            cancel_job "$i"
            echo "Annullato: $(job_line "$i")"
            return 0
        fi
    done
    echo "Nessun job #$1." >&2
    return 1
}

manage_jobs() {
    local c i n_drin
    while :; do
        collect_jobs
        if [ "$J_N" -eq 0 ]; then
            ui_msg "Nessun timer o sveglia programmati."
            return
        fi
        set --
        n_drin=0
        for ((i = 1; i <= J_N; i++)); do
            set -- "$@" "$i" "$(job_line "$i")"
            case ${J_DESC[i]} in "(esterno)"*) ;; *) n_drin=$((n_drin + 1)) ;; esac
        done
        [ "$n_drin" -gt 1 ] && set -- "$@" "T" "Annulla tutti i job di drin ($n_drin)"
        c=$(ui_menu "Programmati" "Ora: $(date +%H:%M:%S) — seleziona un job per annullarlo:" "$@") || return
        if [ "$c" = T ] || [ "$c" = t ]; then
            ui_yesno "Annullare tutti i $n_drin timer e sveglie di drin?" || continue
            for ((i = 1; i <= J_N; i++)); do
                case ${J_DESC[i]} in "(esterno)"*) ;; *) cancel_job "$i" ;; esac
            done
            continue
        fi
        [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$J_N" ] || continue
        if ui_yesno "Annullare questo job?

$(job_line "$c")"; then
            cancel_job "$c"
        fi
    done
}

# -------------------------------------------------------------------- menu

new_timer() {
    local fg=$1 in secs target
    in=$(ui_input "Durata del timer (es. 10, 90s, 5m, 1h30m, 25:00).
Un numero senza unità vale minuti." "$DRIN_DEFAULT_TIMER") || return
    secs=$(parse_duration "$in") || { ui_msg "Durata non valida: $in"; return; }
    choose_action || return
    target=$(($(now) + secs))
    if [ "$fg" = 1 ]; then
        countdown_screen "$target" timer "Timer $(fmt_dur "$secs") → $ACTION_DESC"
    else
        schedule_job "$target" "Timer $(fmt_dur "$secs") → $ACTION_DESC"
    fi
}

new_alarm() {
    local fg=$1 in target
    in=$(ui_input "Orario della sveglia: HH:MM oppure YYYY-MM-DD HH:MM.
Se l'orario di oggi è già passato, vale per domani." "$DRIN_DEFAULT_ALARM") || return
    target=$(parse_alarm "$in") || { ui_msg "Orario non valido: $in"; return; }
    choose_action || return
    if [ "$fg" = 1 ]; then
        countdown_screen "$target" alarm "Sveglia → $ACTION_DESC"
    else
        schedule_job "$target" "Sveglia → $ACTION_DESC"
    fi
}

main_menu() {
    local c
    while :; do
        c=$(ui_menu "drin" @clock \
            1 "Sveglia in background (at)" \
            2 "Timer in background (at)" \
            3 "Sveglia a video" \
            4 "Timer a video" \
            5 "Vedi / annulla timer e sveglie programmati" \
            6 "Orologio a schermo intero" \
            0 "Esci") || break
        case $c in
            1) new_alarm 0 ;;
            2) new_timer 0 ;;
            3) new_alarm 1 ;;
            4) new_timer 1 ;;
            5) manage_jobs ;;
            6) live_clock ;;
            0) break ;;
        esac
    done
    clear
}

case ${1:-} in
    -h|--help)
        # testo inline: lanciato con `bash <(curl ...)` $0 è /dev/fd/N
        cat <<'EOF'
drin.sh — timer e sveglie da terminale con figlet e at.

Uso: drin.sh [--list | --cancel N]
  (senza opzioni)  menu interattivo
  -l, --list       elenca timer e sveglie programmati
  -c, --cancel N   annulla il job at numero N (vedi --list)
  -h, --help       questo aiuto
EOF
        exit 0 ;;
    -l|--list)
        have at || { echo "at non è installato." >&2; exit 1; }
        print_jobs
        exit 0 ;;
    -c|--cancel)
        have at || { echo "at non è installato." >&2; exit 1; }
        [ -n "${2:-}" ] || { echo "Uso: --cancel N (vedi --list)" >&2; exit 1; }
        cancel_by_id "$2"
        exit ;;
esac

if ! [ -t 0 ] || ! [ -t 1 ]; then
    echo "drin va eseguito in un terminale interattivo." >&2
    echo "Da remoto usa: bash <(curl -fsSL https://raw.githubusercontent.com/jacklocke/Drin.sh/refs/heads/main/drin.sh)" >&2
    exit 1
fi
trap 'tput cnorm 2>/dev/null' EXIT
check_deps
main_menu
