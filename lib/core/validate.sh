#!/usr/bin/env bash
# Pure input validators: interactive answers and config values go through the same checks.
set -Eeuo pipefail

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

valid_dns_label() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

# Single DNS label: the domain part belongs to search domains, not to the hostname.
valid_hostname() { valid_dns_label "$1"; }

valid_domain() {
    local domain="$1" label
    local -a labels
    (( ${#domain} <= 253 )) && [[ "$domain" == *.* && "$domain" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do valid_dns_label "$label" || return 1; done
}

valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
}

valid_cidr() {
    local value="$1" prefix
    [[ "$value" == */* ]] || return 1
    prefix=${value##*/}
    valid_ipv4 "${value%/*}" && [[ "$prefix" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]
}

# Comma-separated lists; blanks around items are ignored.
valid_ipv4_list() {
    local item
    local -a items
    IFS=, read -r -a items <<<"$1"
    (( ${#items[@]} > 0 )) || return 1
    for item in "${items[@]}"; do valid_ipv4 "${item//[[:space:]]/}" || return 1; done
}

valid_domain_list() {
    local item
    local -a items
    [[ -n "$1" ]] || return 0
    IFS=, read -r -a items <<<"$1"
    for item in "${items[@]}"; do valid_domain "${item//[[:space:]]/}" || return 1; done
}

# IPv4, IPv4/prefix, or IPv6 with optional prefix.
valid_ip_or_cidr() {
    valid_ipv4 "$1" || valid_cidr "$1" || [[ "$1" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]
}

ipv4_to_int() { local a b c d; IFS=. read -r a b c d <<<"$1"; printf '%s' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"; }

# ipv4_in_cidr IP CIDR: IPv4 address inside the network (a plain IP counts as /32).
ipv4_in_cidr() {
    local ip="$1" net="${2%/*}" prefix="${2#*/}" mask
    valid_ipv4 "$ip" && valid_ipv4 "$net" || return 1
    [[ "$2" == */* ]] || prefix=32
    mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( ($(ipv4_to_int "$ip") & mask) == ($(ipv4_to_int "$net") & mask) ))
}

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }

valid_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; }

# Accepts C.UTF-8 and ll[_CC].UTF-8 forms (utf8 spelling included).
valid_locale() { [[ "$1" =~ ^(C|[a-z]{2,3}(_[A-Z]{2})?)\.(UTF-8|utf8)$ ]]; }

valid_timezone() {
    local zone="$1"
    [[ "$zone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && "$zone" != *..* ]] || return 1
    [[ -f "$(root_path "/usr/share/zoneinfo/$zone")" ]]
}

valid_ssh_public_key() {
    local key="$1" type payload rest
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* && "$key" != *$'\t'* ]] || return 1
    [[ "$key" != *'PRIVATE KEY'* ]] || return 1
    read -r type payload rest <<<"$key"
    case "$type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
        sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *) return 1 ;;
    esac
    [[ "$payload" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] && (( ${#payload} >= 20 ))
}

# Hostname, IPv4 or domain accepted as ping/connectivity target.
valid_host_target() { valid_ipv4 "$1" || valid_hostname "$1" || valid_domain "$1"; }

# words_add VAR WORD...: append each WORD to the space-separated list in VAR (a variable or an
# array element such as CFG[KEY]), once.
words_add() {
    local -n words_add_list="$1"
    local words_add_word
    shift
    for words_add_word in "$@"; do
        [[ " $words_add_list " == *" $words_add_word "* ]] || words_add_list+="${words_add_list:+ }$words_add_word"
    done
}
