# JackTools

JackTools è uno strumento interattivo interamente scritto in Bash per preparare in modo coerente un server Ubuntu. Gestisce hostname, Netplan, politiche SSH, utenti amministrativi, personalizzazioni Bash, aggiornamenti APT e pacchetti. Le modifiche critiche sono precedute da conferme esplicite, validate e accompagnate da backup persistenti.

> La configurazione di rete da remoto può interrompere una sessione SSH anche quando il rollback è predisposto. Prima di intervenire assicurarsi di avere accesso alla console del server.

## Sistemi supportati e requisiti

Il target è Ubuntu Server con Bash, systemd, APT, OpenSSH Server e Netplan. `curl` è richiesto dal bootstrap. `dialog` e `whiptail` non sono necessari. JackTools rifiuta sistemi diversi da Ubuntu e deve essere eseguito come root; conserva comunque in `SUDO_USER` l’identità dell’utente che lo ha avviato.

Per le funzioni non pertinenti, i requisiti specifici sono verificati solo quando servono. Ad esempio, Netplan è obbligatorio per `network`, mentre OpenSSH Server è obbligatorio per le operazioni SSH e utenti.

## Struttura

```text
jacktools/
├── bootstrap.sh
├── jacktools.sh
├── README.md
├── assets/
│   ├── header.txt
│   ├── disclaimer.txt
│   ├── packages.txt
│   ├── bashrc_customization
│   └── tmux.conf
├── lib/
│   ├── common.sh
│   ├── hostname.sh
│   ├── network.sh
│   ├── ssh.sh
│   ├── users.sh
│   ├── customization.sh
│   ├── packages.sh
│   └── cleanup.sh
└── tests/
    ├── run_tests.sh
    ├── test_helper.sh
    ├── test_bootstrap_manifest.sh
    ├── test_hostname_transaction.sh
    ├── test_packages_parser.sh
    ├── test_validation.sh
    ├── test_idempotency.sh
    └── test_safety.sh
```

## Avvio

Eseguire direttamente:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/bootstrap.sh \
  -o /tmp/jacktools-bootstrap.sh \
  && sudo bash /tmp/jacktools-bootstrap.sh
```

Il bootstrap rifiuta `/tmp/jacktools` se è un link simbolico, ricrea la directory con permessi `0700`, scarica ogni file con `curl -fsSL` e non avvia contenuti mancanti o vuoti.

## Comandi

```text
menu                  menu interattivo (predefinito)
all                   configurazione completa in ordine sicuro
hostname              hostname e voce /etc/hosts
network               DHCP o IPv4 statico con Netplan
admin-user            amministratore, chiave e sudo
remove-ubuntu-user    rimozione protetta dell’utente ubuntu
bashrc                blocco Bash gestito
packages              aggiornamento e pacchetti selezionati
cleanup               elimina tutte le copie temporanee JackTools
help, --help           guida
version                versione
```

Esempi di singole operazioni:

```bash
sudo bash /tmp/jacktools/jacktools.sh hostname
sudo bash /tmp/jacktools/jacktools.sh network
sudo bash /tmp/jacktools/jacktools.sh packages
```

Il disclaimer è la prima schermata mostrata prima del menu e di ogni comando che può modificare il sistema, ma non viene richiesto per `help`, `--help` e `version`. Per procedere occorre premere SPAZIO e poi INVIO. Le conferme successive accettano `Y/y` oppure `N/n`; un input vuoto annulla la conferma. Durante la verifica Netplan JackTools esegue prima tre ping verso `8.8.8.8`: alla domanda successiva si può rispondere `y`, `n` oppure `check`. Con `check` è possibile indicare un altro IP o nome da sottoporre a tre ping prima di tornare alla domanda.

## Menu di esempio

```text
1. Esegui configurazione completa

2. Configura hostname
3. Configura rete
4. Crea utente amministrativo
5. Elimina utente ubuntu
6. Applica personalizzazione Bash
7. Installa o aggiorna programmi
8. Pulizia file temporanei
0. Esci
```

La checklist pacchetti usa frecce, spazio e Invio su un terminale capace. `q` o Esc annullano. In assenza di terminale interattivo o con `TERM=dumb` viene mostrato il fallback numerico.

## Pacchetti

`assets/packages.txt` accetta commenti, righe vuote e uno dei formati seguenti:

```text
curl default
vim
```

Il primo campo è un nome pacchetto APT validato. L’unico secondo campo ammesso è `default`, che preseleziona la voce. Opzioni e campi arbitrari sono rifiutati. La lista iniziale comprende `zip`, `unzip`, `curl`, `wget`, `powerline`, `tmux` e `nano`. Dopo la conferma JackTools esegue sempre `apt-get update` prima di qualsiasi installazione o upgrade; se questo aggiornamento preliminare fallisce, la funzione si interrompe. La checklist aggiunge “Aggiornamento generale del sistema” seguito dalla versione corrente, per esempio “Ubuntu 24.04 LTS”; questa voce controlla `apt-get upgrade -y` e non esegue automaticamente `dist-upgrade` o `full-upgrade`.

I pacchetti già installati non vengono reinstallati. `tmux` può copiare `assets/tmux.conf` nella home di un utente dopo backup e conferma. Docker è intenzionalmente l’unica funzione incompleta: stampa `TODO questa sezione va completata` e assume lo stato `NON IMPLEMENTATO`; non tenta installazioni parziali.

## Personalizzazione

- Modificare `assets/header.txt` per cambiare l’header ASCII. Il file viene stampato come testo, preservando gli spazi.
- Modificare `assets/disclaimer.txt` per aggiornare l’avviso iniziale.
- Modificare `assets/bashrc_customization` per il blocco `.bashrc`. JackTools lo racchiude tra marcatori, sostituisce la versione precedente e verifica il risultato con `bash -n`.
- Modificare `assets/tmux.conf` per il modello tmux.

I file di asset non vengono eseguiti durante il download o interpretati come comandi dal parser dei pacchetti.

## Backup, log e rollback

Il log persistente è `/var/log/jacktools.log`, con timestamp e senza password o chiavi private. I backup sono conservati sotto `/var/backups/jacktools/` e non vengono cancellati dalla pulizia temporanea.

La pulizia finale elimina `/tmp/jacktools/` e `/tmp/jacktools-bootstrap.sh`, quindi verifica esplicitamente che entrambi non esistano più. Le configurazioni applicate, `/var/log/jacktools.log` e `/var/backups/jacktools/` restano intatti.

Dopo una pulizia effettivamente completata JackTools termina immediatamente, conservando come codice di uscita l’esito delle operazioni precedenti.

Prima di modificare file critici JackTools crea un backup e usa un candidato temporaneo. Le configurazioni SSH sono testate con `sshd -t`; se il test fallisce, viene ripristinato il file precedente e SSH non viene ricaricato. Il servizio viene ricaricato, non riavviato.

Per Netplan viene copiata tutta `/etc/netplan/` in una directory `netplan-YYYYMMDD-HHMMSS`. Il candidato è verificato con `netplan generate`, quindi applicato temporaneamente da `netplan try` con un timeout predefinito di 30 secondi. Il timer parte dopo l’applicazione temporanea e consente il rollback automatico se la sessione cade o la configurazione non viene confermata. Indirizzo, route e DNS vengono verificati; in caso di errore tutti i file YAML precedenti vengono ripristinati, quindi sono eseguiti nuovamente `netplan generate` e `netplan apply`. La presenza del file `99-jacktools-INTERFACCIA.yaml` mantiene la configurazione JackTools separata dai file non correlati.

La rimozione di `ubuntu` è possibile soltanto quando esiste un altro amministratore verificato con metodo di autenticazione. È sempre rifiutata dalla sessione dell’utente `ubuntu` e richiede la frase esatta `ELIMINA ubuntu`. I file esterni alla home vengono soltanto segnalati.

## Riepilogo di esempio

```text
FASE                               STATO
---------------------------------- ----------------
Hostname                           OK
Configurazione rete                OK
Utente amministrativo              OK
Personalizzazione Bash             OK
Aggiornamento sistema              OK
tmux                               OK
docker                             NON IMPLEMENTATO
Eliminazione utente ubuntu         SALTATO
Pulizia temporanei                 NON ESEGUITA

Log: /var/log/jacktools.log
Backup: /var/backups/jacktools
```

Uno stato `FALLITO` produce un codice di uscita diverso da zero. `RIPRISTINATO` segnala un errore dopo il quale la configurazione precedente è stata riapplicata.

## Test e analisi statica

I test usano una radice temporanea e `JACKTOOLS_TEST_MODE=1`; non modificano il sistema reale:

```bash
bash tests/run_tests.sh
```

Coprono manifest e sintassi dei file scaricati dal bootstrap, parser e flag dei pacchetti, input malevoli, validazioni hostname/rete/DNS, idempotenza di `.bashrc` e `authorized_keys`, protezione dell’utente corrente, rollback Netplan, ripristino SSH, percorso di pulizia e stato Docker.

Con ShellCheck installato:

```bash
shellcheck bootstrap.sh jacktools.sh lib/*.sh tests/*.sh
```

Le direttive `source=/dev/null` nel main sono intenzionali: i percorsi delle librerie sono determinati a runtime dalla directory dello script.
