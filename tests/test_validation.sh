#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tests/test_helper.sh"
JACKTOOLS_TEST_MODE=1 JACKTOOLS_DIR="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/users.sh"
source "$ROOT/lib/network.sh"

assert_true 'hostname valido' valid_hostname server-01
assert_false 'hostname con spazio rifiutato' valid_hostname 'server uno'
assert_false 'hostname con slash rifiutato' valid_hostname 'server/uno'
assert_true 'CIDR valido' valid_cidr 192.168.10.20/24
assert_false 'prefisso CIDR invalido' valid_cidr 192.168.10.20/33
assert_false 'IPv4 fuori intervallo rifiutato' valid_ipv4 192.168.1.999
assert_true 'gateway valido' valid_ipv4 10.0.0.1
assert_true 'DNS multipli validi' valid_dns_list '1.1.1.1,8.8.8.8'
assert_false 'DNS malevolo rifiutato' valid_dns_list '1.1.1.1,-x'
assert_true 'domini ricerca validi' valid_search_domains 'example.org,lab.example.org'
assert_false 'utente corrente non eliminabile' is_removal_session_safe ubuntu ubuntu root
DISCLAIMER_ACCEPTED=0
assert_true 'disclaimer accetta SPAZIO seguito da INVIO' require_disclaimer <<<" "
DISCLAIMER_ACCEPTED=0
assert_false 'disclaimer rifiuta input vuoto' require_disclaimer <<<""
assert_true 'conferma accetta Y' confirm_yes 'Test conferma' <<<Y
assert_true 'conferma accetta y minuscola' confirm_yes 'Test conferma' <<<y
assert_false 'conferma rifiuta N' confirm_yes 'Test conferma' <<<N
assert_false 'conferma rifiuta n minuscola' confirm_yes 'Test conferma' <<<n
assert_true 'target ping IPv4 valido' valid_ping_target 8.8.8.8
assert_true 'target ping DNS valido' valid_ping_target example.org
assert_false 'target ping malevolo rifiutato' valid_ping_target '-c 99'
unset SSH_CONNECTION SSH_CLIENT SSH_TTY
assert_true 'preflight locale termina con successo' preflight_for cleanup
run_cmd() { printf '64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=10 ms\n'; }
ping_output=$(ping_three_times 8.8.8.8)
if grep -Fq '64 bytes from 8.8.8.8' <<<"$ping_output"; then
    pass 'output ping mostrato all utente'
else
    fail 'output ping mostrato all utente'
fi
finish_tests
