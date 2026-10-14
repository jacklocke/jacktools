#!/usr/bin/env bash
# Step "docker": Docker Engine from the official APT repository, following
# https://docs.docker.com/engine/install/ubuntu/ (conflict removal, keyring, deb822 source),
# with the Compose plugin as a separate choice. Users are never added to the docker group here.
set -Eeuo pipefail

DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCES="/etc/apt/sources.list.d/docker.sources"
DOCKER_ENGINE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
DOCKER_CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
DOCKER_UBUNTU_VERSIONS=" 22.04 24.04 25.10 26.04 "
DOCKER_ARCHITECTURES=" amd64 armhf arm64 s390x ppc64el "

docker_architecture() { dpkg --print-architecture 2>/dev/null; }

# Download the repository key into OUTPUT (replaced in tests).
docker_fetch_key() { curl -fsSL --proto '=https' "$DOCKER_KEY_URL" -o "$1"; }

# Engine health after installation (replaced in tests).
docker_engine_ok() {
    systemctl is-active --quiet docker && docker info >/dev/null 2>&1 && docker run --rm hello-world >/dev/null
}

docker_compose_ok() { docker compose version >/dev/null 2>&1; }

docker_render_sources() {
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
        "$DOCKER_REPO_URL" "$ENV_OS_CODENAME" "$1" "$DOCKER_KEYRING"
}

docker_installed_conflicts() {
    local name
    for name in "${DOCKER_CONFLICTS[@]}"; do apt_is_installed "$name" && printf '%s\n' "$name"; done
    return 0
}

docker_engine_installed() {
    local name
    for name in "${DOCKER_ENGINE_PACKAGES[@]}"; do apt_is_installed "$name" || return 1; done
}

# Supported Ubuntu release and architecture; sets CFG[DOCKER_ARCH].
docker_config_prepare() {
    local arch
    arch=$(docker_architecture)
    if [[ "$DOCKER_UBUNTU_VERSIONS" != *" $ENV_OS_VERSION_ID "* ]]; then ui_error docker.unsupported_version "$ENV_OS_VERSION_ID"; return 1; fi
    if [[ "$DOCKER_ARCHITECTURES" != *" $arch "* ]]; then ui_error docker.unsupported_arch "${arch:-?}"; return 1; fi
    if [[ ! "$ENV_OS_CODENAME" =~ ^[a-z0-9.-]+$ ]]; then ui_error docker.no_codename; return 1; fi
    CFG[DOCKER_ARCH]="$arch"
}

docker_collect() {
    local conflicts
    docker_config_prepare || return 1
    [[ "$ENV_VIRT_KIND" == container ]] && ui_warn docker.container_warning
    ui_warn docker.firewall_warning
    ui_confirm docker.confirm || return 1
    CFG[DOCKER_REMOVE_CONFLICTS]=no
    conflicts=$(docker_installed_conflicts | xargs)
    if [[ -n "$conflicts" ]]; then
        msg docker.conflicts "$conflicts"
        ui_confirm docker.confirm_conflicts || return 1
        CFG[DOCKER_REMOVE_CONFLICTS]=yes
    fi
    CFG[DOCKER_COMPOSE]=no
    ui_confirm docker.confirm_compose && CFG[DOCKER_COMPOSE]=yes
    return 0
}

docker_sources_ok() { [[ -f "$(root_path "$DOCKER_SOURCES")" ]] && cmp -s <(docker_render_sources "${CFG[DOCKER_ARCH]}") "$(root_path "$DOCKER_SOURCES")"; }

docker_plan() {
    local conflicts
    conflicts=$(docker_installed_conflicts | xargs)
    [[ -n "$conflicts" ]] && msg docker.plan_remove "$conflicts"
    docker_sources_ok || msg docker.plan_repo "$DOCKER_SOURCES"
    if docker_engine_installed; then msg docker.plan_engine_present; else msg docker.plan_engine "${DOCKER_ENGINE_PACKAGES[*]}"; fi
    if [[ "${CFG[DOCKER_COMPOSE]}" == yes ]]; then
        if apt_is_installed docker-compose-plugin; then msg docker.plan_compose_present; else msg docker.plan_compose; fi
    fi
    return 0
}

# Install key and source; on any failure restore the previous files and indexes.
docker_setup_repository() {
    local keyring sources key_candidate sources_candidate key_backup sources_backup
    keyring=$(root_path "$DOCKER_KEYRING")
    sources=$(root_path "$DOCKER_SOURCES")
    mkdir -p -- "$(dirname -- "$keyring")" "$(dirname -- "$sources")" || return 1
    fs_mktemp key_candidate
    fs_mktemp sources_candidate
    docker_fetch_key "$key_candidate" || { ui_error docker.key_download_failed; return 1; }
    grep -Fqx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_candidate" || { ui_error docker.key_invalid; return 1; }
    docker_render_sources "${CFG[DOCKER_ARCH]}" >"$sources_candidate" || return 1
    key_backup=$(backup_file "$keyring" docker-key) || return 1
    sources_backup=$(backup_file "$sources" docker-sources) || return 1
    if atomic_install "$key_candidate" "$keyring" 0644 && atomic_install "$sources_candidate" "$sources" 0644 &&
        run apt-get update; then
        APT_UPDATED=1
        return 0
    fi
    if [[ -n "$key_backup" ]]; then cp -a -- "$key_backup" "$keyring"; else rm -f -- "$keyring"; fi
    if [[ -n "$sources_backup" ]]; then cp -a -- "$sources_backup" "$sources"; else rm -f -- "$sources"; fi
    run apt-get update || true
    ui_error docker.repo_failed
    return 1
}

docker_apply() {
    local -a conflicts
    mapfile -t conflicts < <(docker_installed_conflicts)
    if (( ${#conflicts[@]} > 0 )); then
        [[ "${CFG[DOCKER_REMOVE_CONFLICTS]}" == yes ]] || { ui_error docker.conflicts_present; return 1; }
        apt_get remove -- "${conflicts[@]}" || return 1
    fi
    apt_update_once || return 1
    apt_get install -- ca-certificates curl || return 1
    if ! docker_sources_ok || [[ ! -s "$(root_path "$DOCKER_KEYRING")" ]]; then
        docker_setup_repository || return 1
    fi
    if ! docker_engine_installed; then apt_get install -- "${DOCKER_ENGINE_PACKAGES[@]}" || return 1; fi
    run systemctl enable --now docker || return 1
    if [[ "${CFG[DOCKER_COMPOSE]}" == yes ]] && ! apt_is_installed docker-compose-plugin; then
        apt_get install -- docker-compose-plugin || return 1
    fi
    return 0
}

docker_verify() {
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    docker_engine_ok || { ui_error docker.engine_check_failed; return 1; }
    [[ "${CFG[DOCKER_COMPOSE]}" != yes ]] || docker_compose_ok || { ui_error docker.compose_check_failed; return 1; }
}

step_register docker step.docker install 0
