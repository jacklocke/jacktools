#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_helper.sh"
load_core

check() { # check VALIDATOR EXPECTED(ok|ko) VALUE...
    local validator="$1" expected="$2" value
    shift 2
    for value in "$@"; do
        if [[ "$expected" == ok ]]; then assert_true "$validator accepts $(printf %q "$value")" "$validator" "$value"
        else assert_false "$validator rejects $(printf %q "$value")" "$validator" "$value"; fi
    done
}

check valid_username ok jack admin_1 _svc a-b
check valid_username ko Root 1abc '' 'a b' 'a;b' "$(printf 'a%.0s' {1..33})"
check valid_hostname ok srv1 web-01 A
check valid_hostname ko '' -srv srv- srv.example.com 'srv 1' 'srv;x' "$(printf 'a%.0s' {1..64})"
check valid_domain ok example.com lan.example.org
check valid_domain ko example .example.com example..com -a.com 'a b.com'
check valid_ipv4 ok 0.0.0.0 192.168.1.10 255.255.255.255
check valid_ipv4 ko 256.1.1.1 1.2.3 01.2.3.4 1.2.3.4.5 a.b.c.d ''
check valid_cidr ok 192.168.1.10/24 10.0.0.1/32 10.0.0.1/1
check valid_cidr ko 192.168.1.10 192.168.1.10/0 192.168.1.10/33 192.168.1.10/024
check valid_ipv4_list ok 1.1.1.1 '1.1.1.1, 8.8.8.8'
check valid_ipv4_list ko '' '1.1.1.1,x' '1.1.1.1;8.8.8.8'
check valid_domain_list ok '' lan.example.com 'a.example.com, b.example.com'
check valid_domain_list ko nodot 'a.com,b'
check valid_port ok 22 2222 65535
check valid_port ko 0 65536 022 '' 22a
check valid_package_name ok tmux g++ libc6-dev python3.12
check valid_package_name ko Tmux -rf 'a b' '' 'a;b'
check valid_locale ok C.UTF-8 it_IT.UTF-8 en_US.utf8 ast.UTF-8
check valid_locale ko C it_IT it_IT.ISO-8859-1 'it_IT.UTF-8;x'

mkdir -p "$JACKTOOLS_ROOT/usr/share/zoneinfo/Europe" && touch "$JACKTOOLS_ROOT/usr/share/zoneinfo/Europe/Rome"
check valid_timezone ok Europe/Rome
check valid_timezone ko Europe/Nowhere ../etc/passwd 'Europe/../Rome' ''

key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlongEnoughPayloadForTesting user@host'
check valid_ssh_public_key ok "$key" 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ=='
check valid_ssh_public_key ko '' 'ssh-dss AAAAB3NzaC1kc3MAAACBAP' 'ssh-ed25519 short' $'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlong\nx' '-----BEGIN OPENSSH PRIVATE KEY-----'
check valid_host_target ok 8.8.8.8 gateway example.com
check valid_host_target ko '' '-c 100' 'a;b'
finish_tests
