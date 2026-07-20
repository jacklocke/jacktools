#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/test_helper.sh"
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/network.sh"
source "$ROOT/lib/ssh.sh"
source "$ROOT/lib/users.sh"
source "$ROOT/lib/docker.sh"
source "$ROOT/lib/packages.sh"
source "$ROOT/lib/cleanup.sh"

work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
JACKTOOLS_ROOT="$work/root"; JACKTOOLS_BACKUP_ROOT="$work/backups"; mkdir -p "$JACKTOOLS_ROOT/etc/netplan" "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d" "$JACKTOOLS_BACKUP_ROOT"
printf 'old: config\n' >"$JACKTOOLS_ROOT/etc/netplan/old.yaml"
mkdir "$work/netplan-backup"; cp "$JACKTOOLS_ROOT/etc/netplan/old.yaml" "$work/netplan-backup/"
printf 'bad: candidate\n' >"$JACKTOOLS_ROOT/etc/netplan/99-jacktools-eth0.yaml"
restore_netplan_backup "$work/netplan-backup"
assert_true 'rollback Netplan elimina candidato' test ! -e "$JACKTOOLS_ROOT/etc/netplan/99-jacktools-eth0.yaml"
assert_true 'rollback Netplan ripristina precedente' grep -Fqx 'old: config' "$JACKTOOLS_ROOT/etc/netplan/old.yaml"
run_cmd() { return 1; }
assert_false 'fallimento applicazione rollback Netplan rilevato' restore_netplan_backup "$work/netplan-backup"
record_netplan_rollback "$work/netplan-backup"
assert_eq 'rollback Netplan non riuscito marcato FALLITO' FALLITO "${JT_STATUS[Configurazione rete]}"
run_cmd() { return 0; }

printf 'ClientAliveInterval 10\n' >"$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf"
printf 'ClientAliveInterval bad\n' >"$work/candidate"
validate_and_reload_ssh() { return 1; }
assert_false 'errore sshd-t segnalato' write_managed_ssh_file "$work/candidate"
assert_true 'configurazione SSH ripristinata' grep -Fqx 'ClientAliveInterval 10' "$JACKTOOLS_ROOT/etc/ssh/sshd_config.d/99-jacktools.conf"
assert_true 'pattern SSH riconosce utente semplice' ssh_value_matches_patterns admin 'admin ops'
assert_true 'pattern SSH riconosce wildcard' ssh_value_matches_patterns admin 'adm* ops'
assert_false 'pattern SSH non inventa utenti' ssh_value_matches_patterns root 'admin ops'

assert_true 'percorso cleanup esatto accettato' safe_cleanup_path /tmp/jacktools
assert_false 'root rifiutata dalla cleanup' safe_cleanup_path /
assert_false '/tmp rifiutata dalla cleanup' safe_cleanup_path /tmp
assert_true 'percorso bootstrap esatto accettato' safe_bootstrap_cleanup_path /tmp/jacktools-bootstrap.sh
assert_false 'bootstrap fuori percorso rifiutato' safe_bootstrap_cleanup_path /tmp/altro.sh
assert_true 'architettura Docker amd64 supportata' docker_supported_architecture amd64
assert_false 'architettura Docker malevola rifiutata' docker_supported_architecture '--privileged'
assert_true 'Ubuntu 24.04 supportato da Docker' docker_supported_ubuntu_version 24.04
assert_false 'Ubuntu obsoleto rifiutato da Docker' docker_supported_ubuntu_version 18.04
finish_tests
