#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1091 # Percorso calcolato a runtime.
source "$ROOT/tests/test_helper.sh"
# shellcheck disable=SC2034 # Variabile consumata dalle librerie caricate dinamicamente.
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
# shellcheck disable=SC1091 # Percorso calcolato a runtime.
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091 # Percorso calcolato a runtime.
source "$ROOT/lib/docker.sh"

work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
JACKTOOLS_ROOT="$work/root"
JACKTOOLS_BACKUP_ROOT="$work/backups"
JACKTOOLS_COMMAND_LOG="$work/commands.log"
mkdir -p -- "$JACKTOOLS_BACKUP_ROOT"

generate_docker_sources "$work/docker.sources" noble amd64
assert_true 'repository Docker usa URL ufficiale' grep -Fqx 'URIs: https://download.docker.com/linux/ubuntu' "$work/docker.sources"
assert_true 'repository Docker usa codename Ubuntu' grep -Fqx 'Suites: noble' "$work/docker.sources"
assert_true 'repository Docker usa architettura rilevata' grep -Fqx 'Architectures: amd64' "$work/docker.sources"
assert_true 'repository Docker usa keyring dedicato' grep -Fqx 'Signed-By: /etc/apt/keyrings/docker.asc' "$work/docker.sources"

dpkg-query() { return 1; }
assert_true 'assenza di conflitti Docker non genera errore' installed_docker_conflicts

assert_true 'setup repository Docker simulato riuscito' setup_docker_repository noble amd64
assert_true 'chiave Docker installata nel keyring simulato' test -s "$JACKTOOLS_ROOT/etc/apt/keyrings/docker.asc"
assert_true 'docker.sources installato nella root simulata' test -s "$JACKTOOLS_ROOT/etc/apt/sources.list.d/docker.sources"
assert_true 'setup Docker aggiorna gli indici APT' grep -Fqx 'MOCK: apt-get update' "$JACKTOOLS_COMMAND_LOG"

assert_true 'setup repository Docker idempotente' setup_docker_repository noble amd64
assert_eq 'un solo file docker.sources attivo' 1 "$(find "$JACKTOOLS_ROOT/etc/apt/sources.list.d" -maxdepth 1 -name docker.sources | wc -l | tr -d ' ')"

assert_true 'installazione Compose simulata riuscita' install_docker_compose_plugin
assert_eq 'stato Docker Compose OK' OK "${JT_STATUS[Docker Compose]}"

finish_tests
