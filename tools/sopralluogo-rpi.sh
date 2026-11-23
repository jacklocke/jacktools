#!/usr/bin/env bash
# sopralluogo-rpi.sh: read-only survey of a Raspberry Pi OS (or Debian) host before porting
# JackTools to it (CLAUDE.md, roadmap 9.0). It changes nothing on the system: it only reads
# files and runs query commands. The one file it writes is the report, created 0600.
# Secrets found in network files (Wi-Fi keys, 802.1X passwords) are redacted; cloud-init
# user-data is listed, never printed, because it may hold password hashes.
#
# A tool for whoever develops JackTools: not listed in MANIFEST.
#
#   sudo bash sopralluogo-rpi.sh [packages.txt]
set -Eeuo pipefail

SP_HOST=$(hostname 2>/dev/null || printf unknown)
SP_REPORT="/tmp/sopralluogo-${SP_HOST}-$(date +%Y%m%d-%H%M%S).txt"
SP_PACKAGES_FILE="${1:-$(dirname -- "${BASH_SOURCE[0]}")/../assets/packages.txt}"
# Used when packages.txt is not next to the script (script copied alone to the Pi).
SP_PACKAGES_FALLBACK=(zip unzip curl wget nano tmux powerline git htop vim ncdu at figlet bat
    fzf fail2ban cmatrix python3-netifaces)
# Packages the port depends on, beyond packages.txt.
SP_PACKAGES_EXTRA=(ufw unattended-upgrades python3-systemd rsyslog locales network-manager
    netplan.io cloud-init qemu-guest-agent rpi-swap dphys-swapfile systemd-zram-generator
    zram-tools fake-hwclock powerline-gitstatus)

# dpkg-query format: the ${...} fields are expanded by dpkg-query, not by the shell.
# shellcheck disable=SC2016
SP_DPKG_FORMAT='${Package} ${Version} ${Status}\n'

sp_section() { printf '\n==================== %s ====================\n' "$*"; }

# sp_run CMD...: show the command and its output; a failure is reported, never fatal.
sp_run() {
    local rc=0
    printf '\n$ %s\n' "$*"
    if ! command -v -- "$1" >/dev/null 2>&1; then printf '(comando non presente)\n'; return 0; fi
    "$@" 2>&1 || rc=$?
    (( rc == 0 )) || printf '(codice di uscita %d)\n' "$rc"
    return 0
}

# Hide values of secret-looking keys (keyfile "psk=", YAML "password:" ...).
sp_redact() {
    sed -E 's/^([[:space:]]*-?[[:space:]]*"?(psk|password|passwd|secret|private-key|wep-key[0-9]*|leap-password|pin|token)[[:alnum:]_.-]*"?[[:space:]]*[=:]).*/\1 <oscurato>/I'
}

# sp_file PATH [redact]: print a file (or say it is missing), optionally redacted.
sp_file() {
    printf '\n--- %s\n' "$1"
    if [[ -L "$1" ]]; then printf '(link simbolico verso %s)\n' "$(readlink -- "$1")"; fi
    if [[ ! -e "$1" ]]; then printf '(non esiste)\n'; return 0; fi
    if [[ ! -r "$1" ]]; then printf '(non leggibile: lanciare come root)\n'; return 0; fi
    if [[ -d "$1" ]]; then ls -la -- "$1"; return 0; fi
    if [[ "${2:-}" == redact ]]; then sp_redact <"$1"; else cat -- "$1"; fi
}

# sp_dir_files DIR [redact]: listing plus every regular file in DIR.
sp_dir_files() {
    local f
    sp_file "$1"
    [[ -d "$1" && -r "$1" ]] || return 0
    for f in "$1"/*; do [[ -f "$f" ]] && sp_file "$f" "${2:-}"; done
    return 0
}

sp_exists() { if [[ -e "$1" ]]; then printf '%s: presente\n' "$1"; else printf '%s: assente\n' "$1"; fi; }

sp_system() {
    sp_section "Sistema"
    sp_file /etc/os-release
    sp_file /etc/rpi-issue
    sp_file /etc/debian_version
    sp_run uname -a
    sp_run dpkg --print-architecture
    sp_run getconf LONG_BIT
    printf '\n--- modello\n'; tr -d '\0' </proc/device-tree/model 2>/dev/null || printf '(non disponibile)'; printf '\n'
    sp_run systemd-detect-virt
    sp_run systemctl --version
    sp_run df -h /
    sp_run free -m
    sp_run hostnamectl
    sp_file /etc/hostname
    sp_file /etc/hosts
    sp_run vcgencmd version
    sp_run ls /sys/class/thermal
    printf '\n--- sensori di temperatura\n'
    local zone
    for zone in /sys/class/thermal/thermal_zone*; do
        [[ -r "$zone/temp" ]] && printf '%s %s %s\n' "$zone" "$(cat "$zone/type" 2>/dev/null)" "$(cat "$zone/temp" 2>/dev/null)"
    done
    return 0
}

sp_boot() {
    sp_section "Primo avvio (Imager, cloud-init)"
    sp_run ls -la /boot/firmware
    sp_exists /boot/firmware/user-data
    sp_exists /boot/firmware/firstrun.sh
    sp_file /boot/firmware/network-config redact
    sp_file /boot/firmware/meta-data
    sp_run cloud-init status --long
    sp_dir_files /etc/cloud/cloud.cfg.d
    sp_run dpkg-query -W -f "$SP_DPKG_FORMAT" cloud-init netplan.io network-manager
}

sp_network() {
    sp_section "Rete"
    sp_run systemctl is-active NetworkManager systemd-networkd dhcpcd systemd-resolved
    sp_run systemctl is-enabled NetworkManager systemd-networkd dhcpcd systemd-resolved
    sp_run ip -br link
    sp_run ip -br addr
    sp_run ip route
    sp_file /etc/resolv.conf
    sp_run resolvectl status
    sp_dir_files /etc/netplan redact
    sp_run netplan status
    sp_dir_files /etc/systemd/network
    sp_run nmcli --version
    sp_run nmcli general status
    sp_run nmcli -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT,AUTOCONNECT-PRIORITY,FILENAME connection show
    sp_run nmcli device status
    local dev
    while read -r dev; do
        [[ -n "$dev" && "$dev" != lo ]] || continue
        sp_run nmcli -g GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP4.DOMAIN device show "$dev"
    done < <(nmcli -g DEVICE device status 2>/dev/null || true)
    sp_file /etc/NetworkManager/NetworkManager.conf
    sp_dir_files /etc/NetworkManager/conf.d
    sp_dir_files /etc/NetworkManager/system-connections redact
    sp_dir_files /run/NetworkManager/system-connections redact
    # Offline mode prints a keyfile on stdout without talking to the daemon: nothing is saved.
    printf '\n--- prova di nmcli --offline (stampa soltanto, non salva)\n'
    sp_run nmcli --offline connection add type ethernet con-name jacktools-prova ifname eth0 \
        ipv4.method manual ipv4.addresses 192.0.2.10/24 ipv4.gateway 192.0.2.1 ipv4.dns 192.0.2.53
    sp_run systemd-run --version
}

sp_swap() {
    sp_section "Swap"
    sp_run swapon --show
    sp_file /proc/swaps
    sp_run zramctl
    sp_file /etc/fstab
    sp_run dpkg-query -W -f "$SP_DPKG_FORMAT" rpi-swap dphys-swapfile systemd-zram-generator zram-tools
    sp_dir_files /etc/rpi
    sp_dir_files /etc/rpi/swap.conf.d
    sp_file /etc/dphys-swapfile
    sp_file /etc/systemd/zram-generator.conf
    sp_dir_files /usr/lib/systemd/zram-generator.conf.d
    sp_run systemctl list-units --all --no-pager '*swap*' '*zram*'
}

sp_locale_time() {
    sp_section "Locale e ora"
    sp_run locale
    sp_run locale -a
    sp_file /etc/default/locale
    printf '\n--- /etc/locale.gen (righe attive)\n'
    sed -n '/^[^#[:space:]]/p' /etc/locale.gen 2>/dev/null || printf '(non esiste)\n'
    sp_run dpkg -S "$(command -v locale-gen 2>/dev/null || printf locale-gen)"
    printf '\n--- come locale-gen tratta gli argomenti\n'
    sed -n '1,40p' "$(command -v locale-gen 2>/dev/null || printf /nonexistent)" 2>/dev/null || printf '(non disponibile)\n'
    sp_run timedatectl show
    sp_run systemctl is-active systemd-timesyncd chrony ntpsec fake-hwclock
    sp_run ls -la /dev/rtc0
}

sp_motd() {
    sp_section "MOTD e login"
    sp_file /etc/motd
    sp_run ls -la /etc/update-motd.d
    sp_exists /etc/default/motd-news
    printf '\n--- pam_motd in /etc/pam.d/sshd e login\n'
    sed -n '/pam_motd/p' /etc/pam.d/sshd /etc/pam.d/login 2>/dev/null || true
    sp_file /etc/issue
}

sp_ssh() {
    sp_section "SSH"
    sp_run systemctl is-enabled ssh.service ssh.socket
    sp_run systemctl is-active ssh.service ssh.socket
    printf '\n--- Include in sshd_config\n'
    sed -n '/^[[:space:]]*Include/p' /etc/ssh/sshd_config 2>/dev/null || true
    sp_dir_files /etc/ssh/sshd_config.d
    printf '\n$ sshd -T (impostazioni rilevanti)\n'
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>&1 | sed -nE '/^(port|listenaddress|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|allowusers|allowgroups|denyusers|denygroups|authorizedkeysfile|usepam|clientaliveinterval|maxauthtries|x11forwarding) /p' || true
    else
        printf '(sshd non presente)\n'
    fi
}

sp_logs_f2b() {
    sp_section "Log e fail2ban"
    sp_exists /var/log/auth.log
    sp_run systemctl is-active rsyslog
    sp_run journalctl --header --no-pager -n 0
    sp_dir_files /etc/systemd/journald.conf.d
    sp_run journalctl -u ssh --no-pager -n 3
    sp_run apt-cache depends fail2ban
    sp_dir_files /etc/fail2ban/jail.d
    sp_run update-alternatives --query iptables
    sp_run iptables -V
}

sp_users_sudo() {
    sp_section "Utenti e sudo"
    printf 'SUDO_USER=%s\n' "${SUDO_USER:-}"
    printf '\n--- utenti con UID >= 1000\n'
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1, $3, $6, $7 }' || true
    sp_run getent group sudo
    sp_run getent group adm
    sp_run id pi
    sp_dir_files /etc/sudoers.d
    printf '\n--- regole attive in /etc/sudoers\n'
    sed -n '/^[^#[:space:]]/p' /etc/sudoers 2>/dev/null || printf '(non leggibile)\n'
    printf '\n--- UID_MIN e UID_MAX in /etc/login.defs\n'
    sed -n '/^UID_\(MIN\|MAX\)/p' /etc/login.defs 2>/dev/null || true
}

sp_apt() {
    sp_section "APT e unattended-upgrades"
    printf '\n--- ultimo aggiornamento degli indici APT\n'
    ls -ld --time-style=long-iso /var/lib/apt/lists 2>/dev/null || true
    sp_file /etc/apt/sources.list
    local f
    for f in /etc/apt/sources.list.d/*; do [[ -f "$f" ]] && sp_file "$f"; done
    printf '\n--- origini dei repository\n'
    apt-cache policy 2>/dev/null | sed -n '/release /p' | sort -u || true
    sp_run dpkg-query -W -f "$SP_DPKG_FORMAT" unattended-upgrades
    sp_file /etc/apt/apt.conf.d/20auto-upgrades
    printf '\n--- Origins-Pattern in 50unattended-upgrades\n'
    sed -n '/Origins-Pattern/,/};/p' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || printf '(non esiste)\n'
    printf '\n--- Docker: repository debian per questo codename\n'
    local codename
    codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null)
    sp_run curl -fsSI --max-time 10 "https://download.docker.com/linux/debian/dists/${codename:-unknown}/Release"
}

sp_packages() {
    sp_section "Disponibilità dei pacchetti"
    local -a packages=()
    local line name candidate installed
    if [[ -r "$SP_PACKAGES_FILE" ]]; then
        printf 'elenco da %s\n' "$SP_PACKAGES_FILE"
        while read -r line; do
            line=${line%%#*}; read -r name _ <<<"$line"
            [[ -n "${name:-}" ]] && packages+=("$name")
        done <"$SP_PACKAGES_FILE"
    else
        printf 'packages.txt non trovato: uso l elenco incorporato\n'
        packages=("${SP_PACKAGES_FALLBACK[@]}")
    fi
    packages+=("${SP_PACKAGES_EXTRA[@]}")
    printf '\n%-24s %-28s %s\n' PACCHETTO CANDIDATO INSTALLATO
    for name in "${packages[@]}"; do
        candidate=$(apt-cache policy -- "$name" 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p')
        installed=$(apt-cache policy -- "$name" 2>/dev/null | sed -n 's/^[[:space:]]*Installed:[[:space:]]*//p')
        printf '%-24s %-28s %s\n' "$name" "${candidate:-(non disponibile)}" "${installed:--}"
    done
}

sp_main() {
    if (( EUID != 0 )); then
        printf 'Attenzione: senza root alcune sezioni (sshd -T, sudoers, profili di rete) restano incomplete.\n' >&2
    fi
    umask 077
    {
        printf 'Sopralluogo JackTools - %s - %s\n' "$SP_HOST" "$(date -Is)"
        printf 'Script in sola lettura: nessuna modifica al sistema.\n'
        sp_system
        sp_boot
        sp_network
        sp_swap
        sp_locale_time
        sp_motd
        sp_ssh
        sp_logs_f2b
        sp_users_sudo
        sp_apt
        sp_packages
        printf '\nFine del sopralluogo.\n'
    } 2>&1 | tee "$SP_REPORT"
    printf '\nReport salvato in %s (permessi 0600).\n' "$SP_REPORT" >&2
    printf 'Prima di condividerlo, controllalo: contiene nomi utente, indirizzi e configurazioni.\n' >&2
}

sp_main "$@"
