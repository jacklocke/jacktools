#!/usr/bin/env bash
set -Eeuo pipefail

docker_supported_architecture() {
    case "$1" in amd64|armhf|arm64|s390x|ppc64el) return 0 ;; *) return 1 ;; esac
}

docker_supported_ubuntu_version() {
    case "$1" in 22.04|24.04|25.10|26.04) return 0 ;; *) return 1 ;; esac
}

docker_os_value() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted {value=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release
}

docker_ubuntu_codename() {
    local codename
    codename=$(docker_os_value UBUNTU_CODENAME)
    [[ -n "$codename" ]] || codename=$(docker_os_value VERSION_CODENAME)
    [[ "$codename" =~ ^[a-z0-9.-]+$ ]] || return 1
    printf '%s' "$codename"
}

generate_docker_sources() {
    local output="$1" codename="$2" architecture="$3"
    cat >"$output" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

installed_docker_conflicts() {
    local package
    local -a conflicts=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
    for package in "${conflicts[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq 'install ok installed' && printf '%s\n' "$package"
    done
}

restore_docker_repository_file() {
    local destination="$1" backup="$2" existed="$3"
    if [[ "$existed" == 1 ]]; then cp -a -- "$backup" "$destination"; else rm -f -- "$destination"; fi
}

install_docker_managed_file() {
    local candidate="$1" destination="$2" mode="$3"
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then cp -- "$candidate" "$destination"; chmod "$mode" "$destination"; else atomic_install "$candidate" "$destination" "$mode"; fi
}

setup_docker_repository() {
    local codename="$1" architecture="$2"
    local keyring_dir sources_dir key_file sources_file key_candidate sources_candidate
    local key_backup='' sources_backup='' key_existed=0 sources_existed=0
    keyring_dir=$(root_path /etc/apt/keyrings)
    sources_dir=$(root_path /etc/apt/sources.list.d)
    key_file="$keyring_dir/docker.asc"
    sources_file="$sources_dir/docker.sources"
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        mkdir -p -- "$keyring_dir" "$sources_dir"
    else
        install -d -o root -g root -m 0755 "$keyring_dir" "$sources_dir"
    fi
    [[ -e "$key_file" ]] && { key_existed=1; key_backup=$(backup_file "$key_file" docker-key); }
    [[ -e "$sources_file" ]] && { sources_existed=1; sources_backup=$(backup_file "$sources_file" docker-sources); }

    key_candidate=$(mktemp "$keyring_dir/.docker.asc.XXXXXX")
    sources_candidate=$(mktemp "$sources_dir/.docker.sources.XXXXXX")
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'TEST' '-----END PGP PUBLIC KEY BLOCK-----' >"$key_candidate"
    elif ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_candidate"; then
        rm -f -- "$key_candidate" "$sources_candidate"
        error "download della chiave Docker fallito."
        return 1
    fi
    if ! grep -Fqx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_candidate"; then
        rm -f -- "$key_candidate" "$sources_candidate"
        error "la chiave Docker scaricata non ha un formato valido."
        return 1
    fi
    generate_docker_sources "$sources_candidate" "$codename" "$architecture"

    if ! install_docker_managed_file "$key_candidate" "$key_file" 0644 || ! install_docker_managed_file "$sources_candidate" "$sources_file" 0644; then
        restore_docker_repository_file "$key_file" "$key_backup" "$key_existed" || true
        restore_docker_repository_file "$sources_file" "$sources_backup" "$sources_existed" || true
        rm -f -- "$key_candidate" "$sources_candidate"
        error "impossibile installare la configurazione del repository Docker."
        return 1
    fi
    rm -f -- "$key_candidate" "$sources_candidate"

    if ! run_cmd apt-get update; then
        restore_docker_repository_file "$key_file" "$key_backup" "$key_existed" || true
        restore_docker_repository_file "$sources_file" "$sources_backup" "$sources_existed" || true
        run_cmd apt-get update || true
        error "aggiornamento APT del repository Docker fallito; configurazione precedente ripristinata."
        return 1
    fi
}

verify_docker_engine() {
    if ! run_cmd systemctl enable --now docker; then return 1; fi
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then return 0; fi
    systemctl is-active --quiet docker || return 1
    docker version || return 1
    docker info >/dev/null || return 1
    docker run --rm hello-world || return 1
}

install_docker_compose_plugin() {
    if dpkg-query -W -f='${Status}' docker-compose-plugin 2>/dev/null | grep -Fq 'install ok installed' && docker compose version >/dev/null 2>&1; then
        info "Docker Compose Plugin gia installato."
        docker compose version
        set_status 'Docker Compose' OK
        return 0
    fi
    if ! DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y -- docker-compose-plugin; then
        set_status 'Docker Compose' FALLITO
        return 1
    fi
    if [[ "$JACKTOOLS_TEST_MODE" != 1 ]] && ! docker compose version; then
        set_status 'Docker Compose' FALLITO
        return 1
    fi
    set_status 'Docker Compose' OK
}

install_docker() {
    local architecture version codename
    local -a conflicts=() engine_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
    version=$(docker_os_value VERSION_ID)
    architecture=$(dpkg --print-architecture)
    docker_supported_ubuntu_version "$version" || { error "Docker non supporta ufficialmente Ubuntu $version secondo la guida corrente."; set_status docker FALLITO; return 1; }
    docker_supported_architecture "$architecture" || { error "architettura Docker non supportata: $architecture"; set_status docker FALLITO; return 1; }
    codename=$(docker_ubuntu_codename) || { error "codename Ubuntu non valido."; set_status docker FALLITO; return 1; }

    printf '%s%sATTENZIONE DOCKER%s\n' "$YELLOW" "$BOLD" "$RESET"
    printf 'Le porte pubblicate dai container possono bypassare regole ufw/firewalld. Verificare la politica firewall e la catena DOCKER-USER.\n'
    printf 'Verranno configurati il repository APT ufficiale Docker e i pacchetti: %s\n' "${engine_packages[*]}"
    confirm_yes "Installare o aggiornare Docker Engine?" || { set_status docker ANNULLATO; return 0; }

    mapfile -t conflicts < <(installed_docker_conflicts)
    if ((${#conflicts[@]})); then
        printf 'Pacchetti in conflitto rilevati: %s\n' "${conflicts[*]}"
        confirm_yes "Rimuovere i pacchetti in conflitto come richiesto dalla guida Docker?" || { set_status docker ANNULLATO; return 0; }
        if ! DEBIAN_FRONTEND=noninteractive run_cmd apt-get remove -y -- "${conflicts[@]}"; then set_status docker FALLITO; return 1; fi
    fi

    if ! DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y -- ca-certificates curl; then set_status docker FALLITO; return 1; fi
    setup_docker_repository "$codename" "$architecture" || { set_status docker FALLITO; return 1; }
    if ! DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y -- "${engine_packages[@]}"; then set_status docker FALLITO; return 1; fi
    if ! verify_docker_engine; then error "verifica Docker Engine fallita."; set_status docker FALLITO; return 1; fi
    set_status docker OK

    if confirm_yes "Installare anche Docker Compose Plugin (comando: docker compose)?"; then
        install_docker_compose_plugin
    else
        set_status 'Docker Compose' SALTATO
    fi
}
