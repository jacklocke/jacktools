# JackTools 2.2.1

Prepara e mantiene un **Ubuntu Server 22.04+** da un menu in Bash: sistema, programmi, utenti, sicurezza e manutenzione.
Prima di cambiare qualcosa mostra il riepilogo e chiede conferma. Fa sempre un backup e, se qualcosa va storto, torna indietro.
Comandi e scorciatoie da terminale (tmux, copia e incolla, alias): [`README-CLI.md`](README-CLI.md).

## Avvio

```bash
curl -fsSL https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/jtool.sh | sudo bash
```

Con opzioni: `… | sudo bash -s -- --tag v2.0.0 -- all --dry-run`.

`jtool.sh` scarica `bootstrap.sh` e lo avvia, lasciando il terminale al menu. Comando completo equivalente, se preferisci leggere `bootstrap.sh` prima di eseguirlo:

```bash
curl -fsSL https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/bootstrap.sh \
  -o /tmp/jacktools-bootstrap.sh \
  && sudo bash /tmp/jacktools-bootstrap.sh --repo https://github.com/jacklocke/jacktools
```

> **Usarlo dal proprio repository.** `jtool.sh` usa solo il repository scritto al suo interno: per un altro repository serve il comando completo, dove cambiano due cose: l'URL raw di `bootstrap.sh` e `--repo`.
> - GitHub: `https://raw.githubusercontent.com/<utente>/<progetto>/refs/heads/main/bootstrap.sh` e `--repo https://github.com/<utente>/<progetto>`
> - Gitea/Forgejo: `https://<server>/<utente>/<progetto>/raw/branch/main/bootstrap.sh` e `--repo https://<server>/<utente>/<progetto>`
> - GitLab: `https://<server>/<gruppo>/<progetto>/-/raw/main/bootstrap.sh` e `--repo https://<server>/<gruppo>/<progetto>`
>
> **Per pubblicarlo altrove** (fork, Gitea, GitLab): `bash tools/cambia-server-git.sh` chiede il nuovo repository e aggiorna da solo `bootstrap.sh` (`DEFAULT_REPO`), `jtool.sh` e questo README, con anteprima, conferma per ogni file e backup. Con `--dry-run` mostra solo le modifiche, con `--check` verifica che il nuovo server risponda.
> Altre opzioni:
> - `--tag v2.0.0`: usa una versione precisa invece di `main`;
> - `--token-file /root/token`: repository privato (file di root con permessi 0600);
> - `--cacert /root/ca.pem`: server con certificato interno;
> - `--base-url URL`: server web semplice.
>
> Per **aggiornare** JackTools basta rilanciare il comando: scarica ogni volta l'ultima versione.

Le opzioni di JackTools vanno dopo `--`, ad esempio `... --repo <url> -- all --dry-run`.

## Uso

| Comando | Cosa fa |
|---------|---------|
| `menu` | menu interattivo (predefinito) |
| `all` | configurazione completa: una checklist, un riepilogo, una conferma |
| `system` | hostname, lingua, fuso orario, rete, swap, log, MOTD |
| `install` | aggiornamenti, programmi, Docker, aggiornamenti automatici |
| `users` | amministratore e personalizzazioni (shell, banner, tmux) |
| `security` | SSH, firewall UFW, fail2ban |
| `maintenance` | stato, aggiornamenti, fail2ban, utenti e password, firewall, impostazioni SSH, Docker, export della configurazione |
| `status` | stato del sistema, in sola lettura |
| `cleanup` | elimina i file temporanei e, se richiesto, i backup |

Ogni passo si lancia anche da solo, ad esempio `hostname`, `ssh` o `docker` (l'elenco completo è in `jacktools.sh help`).
Opzioni:
- `--dry-run`: fa le domande e mostra cosa cambierebbe, senza applicare nulla;
- `--config FILE`: configurazione completa con le risposte prese dal file;
- `--yes`: con `--config`, nessuna domanda.

**Prima di usarlo da remoto:** tenere a portata di mano la console del server. Per rete e SSH JackTools chiede di confermare che la connessione funzioni ancora; se non arriva conferma, ripristina la configurazione precedente.

## Replicare un server

1. Sul server già configurato: **Manutenzione → Genera il file di configurazione**. Il file finisce in `/root/jacktools-<host>-<data>.conf`. Hostname e rete restano commentati; le password non vengono mai esportate.
2. Copiare il file sul nuovo server: `scp /root/jacktools-*.conf nuovo-server:/root/`
3. Lanciare il comando stampato dall'export, cioè l'avvio qui sopra con in fondo `-- all --config /root/<file>.conf`.

## Powerline

Prompt e barra di tmux con powerline: pacchetto `powerline` (preselezionato tra i programmi), modulo *powerline* e voce `.tmux.conf` nelle personalizzazioni.

- **Font**: di solito non serve installare nulla, perché Windows Terminal recente usa già Cascadia Mono, che ha i simboli. Se vedi quadratini o `?`, installa un Nerd Font **sul computer da cui ti colleghi** (sul server non serve nulla): comandi qui sotto.
- **Senza il pacchetto**: il prompt resta normale e tmux parte senza errori; il riepilogo avvisa se il modulo è scelto ma powerline non verrà installato.

### Tema powerline

Modulo *Tema powerline* in Utenti → Personalizzazioni (non selezionato di default; va insieme al modulo *powerline*).

- **Cosa cambia**: prompt su due righe (utente, cartella, branch git, stato dell'ultimo comando, poi `❯`), barra di tmux con branch git del pane, container Docker (🐳, rosso se uno è unhealthy), IP, temperatura più alta con il nome del componente (🌡 CPU 44°), CPU, RAM, disco, data e ora, hostname colorato prima della sessione.
- **Badge**: ZOOM (pane ingrandito), SYNC (scrittura su tutti i pane), 👥 N (più terminali sulla stessa sessione); compaiono solo quando servono.
- **IP**: serve `python3-netifaces` (tra i programmi, non preselezionato).
- **Tema**: si sceglie dall'elenco (16, predefinito `gruvbox`); *Mostrameli tutti* fa l'anteprima se powerline è già installato.
- **Dove finisce**: `~/.config/powerline` (configurazione e schemi di colori) e il comando `~/.local/bin/plcolors`.
- **Cambiarlo dopo**: `plcolors` mostra la galleria, `plcolors nord` applica un tema, `plcolors --demo` (dentro tmux) li fa scorrere sulla barra.

### Scorciatoie di tmux (`.tmux.conf`)

- **Prefisso**: Ctrl+A. Split: Ctrl+A `_` (affiancati) e Ctrl+A `-` (uno sopra l'altro).
- **Mouse**: clic su pane e finestre, rotella, bordi trascinabili; Shift + selezione per selezionare testo come nel terminale. Il testo copiato in tmux finisce negli appunti del PC.
- **Senza prefisso**: Alt+frecce cambia pane; Alt+i/j/k/l o Alt+Shift+frecce ridimensiona.
- **Popup**: Ctrl+A M htop, Ctrl+A D dockly (se Docker è installato), Ctrl+A t shell al volo nella cartella del pane.
- **Menu**: tasto destro sulla barra (finestre o parte destra): nuova finestra, split, popup, cambia tema, rinomina, chiudi.
- **Riepilogo dei tasti**: Ctrl+A ? (con il tema powerline), Ctrl+A K elenco completo di tmux.
- **Pane e finestre**: i pane inattivi hanno il testo attenuato; una finestra in background si colora quando produce output.
- **Barra** in alto, titolo su ogni pane, finestre e pane numerati da 1.
- **Mac**: Alt è il tasto Option. iTerm2: Settings → Profiles → Keys → Left Option key = Esc+. Terminale: Profili → Tastiera → "Usa Opzione come tasto Meta".

### Installare un Nerd Font (lato client)

Windows (PowerShell, senza privilegi di amministratore), con una delle due:

```powershell
winget install --id DEVCOM.JetBrainsMonoNerdFont -e     # se non lo trova: winget search "Nerd Font"
```

```powershell
scoop bucket add nerd-fonts
scoop install JetBrainsMono-NF
```

Poi in Windows Terminal: Impostazioni → Predefiniti → Aspetto → Tipo di carattere → **JetBrainsMono Nerd Font**, salva e riapri il terminale.

macOS:

```bash
brew install --cask font-jetbrains-mono-nerd-font
```

Linux (desktop):

```bash
mkdir -p ~/.local/share/fonts && cd ~/.local/share/fonts \
  && curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
  && tar -xf JetBrainsMono.tar.xz && rm JetBrainsMono.tar.xz && fc-cache -f
```

Su macOS e Linux, poi, scegli **JetBrainsMono Nerd Font** nelle preferenze del terminale.

## Cronologia dei comandi

Modulo *Cronologia* in Utenti → Personalizzazioni (non selezionato di default).

- **↑/↓**: scrivi l'inizio di un comando (es. `sys`) e scorri solo i comandi che iniziano così.
- **Ctrl-R**: ricerca fuzzy, se è installato `fzf` (proposto tra i programmi).
- **Tab**: mostra subito le alternative e ignora maiuscole/minuscole.
- **Cronologia**: 10000 comandi con data e ora, salvati dopo ogni comando (anche chiudendo un pannello tmux).

## Menu tmux al login

All'accesso propone di riprendere una sessione tmux o di crearne una nuova.

- **Nessuna sessione aperta**: se non premi nulla per qualche secondo, crea la sessione `A` e ti ci collega.
- **Sessioni aperte**: mostra l'elenco e aspetta la tua scelta, senza limite di tempo.

- **Attivarlo**: Utenti → Personalizzazioni, voce *Menu tmux al login* (non selezionata di default). Serve tmux, proposto tra i programmi.
- **Dove finisce**: lo script in `~/.local/bin/tmux-login-menu.sh`; il lancio nel blocco JackTools del `.bashrc`, solo per le shell di login e fuori da tmux.
- **Tasti**: ↑/↓ scegli · → o Invio entra (o crea) · Spazio rinomina la sessione selezionata · ← o Esc resta nella shell · al detach da tmux torni alla shell.
- **Attesa**: `TIMEOUT=5` in testa allo script (`0` = la sessione `A` non parte mai da sola). Premendo un tasto il conto alla rovescia si ferma.
- **Caratteri sporchi** (`^[[?61;…c`): sono risposte del terminale (es. Windows Terminal) alle richieste di tmux. Nelle sessioni create dal menu la prima shell le scarta per `DRAIN=0.3` secondi; quello che scrivi in quell'istante va perso.
- **Disattivarlo**: rilanciare le personalizzazioni togliendo la voce. Lo script resta in `~/.local/bin` ma non parte più.

Non interviene con scp, sftp, rsync o `ssh host comando`: parte solo con un terminale interattivo.

## Drin: timer e sveglie

Comando `drin`: timer e sveglie da terminale, con orologio a cifre grandi. L'avviso compare nel terminale da cui li hai impostati (o su tutti, se è stato chiuso).

- **Attivarlo**: Utenti → Personalizzazioni, voce *Drin* (non selezionata di default). Servono `figlet` e `at`, proposti tra i programmi.
- **Dove finisce**: `~/.local/bin/drin`; il blocco JackTools del `.bashrc` aggiunge `~/.local/bin` al `PATH` se manca.
- **Uso**: `drin` apre il menu (↑/↓ e Invio, oppure il numero; `q` indietro). Per i job in background: `drin --list` e `drin --cancel N`.
- **Formati**: timer `10` (minuti), `90s`, `25m`, `1h30m`; sveglia `HH:MM` o `YYYY-MM-DD HH:MM`.
- **Default**: `DRIN_DEFAULT_TIMER=25m DRIN_DEFAULT_ALARM=07:30 drin`, oppure in testa allo script.

## Personalizzare

| Cosa | File |
|------|------|
| Testi dei messaggi | `messages/it.sh` |
| Banner | `assets/banners/<nome>.txt` (oppure testo libero con figlet dal menu) |
| Moduli del `.bashrc` | `assets/bashrc.d/NN-<nome>.sh` |
| Programmi proposti | `assets/packages.txt` (`nome` oppure `nome default`) |
| tmux | `assets/tmux.conf` |

Ogni file nuovo va aggiunto anche a `MANIFEST`.

## File e percorsi

- Log: `/var/log/jacktools.log`
- Backup: `/var/backups/jacktools/`
- Copia temporanea: `/tmp/jacktools`
