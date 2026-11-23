#!/usr/bin/env bash
# Files: system paths, temporary files, backups, atomic installs and managed blocks.
set -Eeuo pipefail

: "${JACKTOOLS_TEST_MODE:=0}"
: "${JACKTOOLS_DRY_RUN:=0}"
: "${JACKTOOLS_ROOT:=}"
: "${JACKTOOLS_BACKUP_ROOT:=/var/backups/jacktools}"
declare -ga JT_TEMP_PATHS=()
# How to undo the last fs_write_managed: "" nothing, "remove" new file, or the backup path.
FS_UNDO=""
# Per-run cache directory (created by main; empty in tests, where nothing is cached).
: "${JT_CACHE_DIR:=}"

# root_path PATH: system path, relocated under JACKTOOLS_ROOT in tests.
root_path() { printf '%s%s' "$JACKTOOLS_ROOT" "$1"; }

# fs_source FILE: FILE when it exists, /dev/null otherwise (input for renderers).
fs_source() { if [[ -e "$1" ]]; then printf '%s' "$1"; else printf /dev/null; fi; }

# fs_chown OWNER:GROUP PATH...: only when running as root (tests run unprivileged).
fs_chown() { [[ ${EUID} -ne 0 ]] || chown "$@"; }

# fs_mktemp RESULT_VAR [-d]: temporary file (or directory) removed on exit.
fs_mktemp() {
    local -n fs_mktemp_result="$1"
    local fs_mktemp_path
    if [[ "${2:-}" == -d ]]; then fs_mktemp_path=$(mktemp -d); else fs_mktemp_path=$(mktemp); fi
    JT_TEMP_PATHS+=("$fs_mktemp_path")
    fs_mktemp_result="$fs_mktemp_path"
}

fs_cleanup_temps() {
    local path
    for path in "${JT_TEMP_PATHS[@]}"; do rm -rf -- "$path"; done
    JT_TEMP_PATHS=()
}

fs_init_backup_root() {
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    if [[ "$JACKTOOLS_TEST_MODE" == 1 ]]; then
        mkdir -p -- "$JACKTOOLS_BACKUP_ROOT"
    else
        install -d -o root -g root -m 0750 "$JACKTOOLS_BACKUP_ROOT"
    fi
}

# backup_file SOURCE LABEL: copy SOURCE (file or directory) into the backup root and
# print the backup path. Prints nothing when SOURCE is missing or in dry-run.
backup_file() {
    local source="$1" label="$2" destination
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ -e "$source" ]] || return 0
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    fs_init_backup_root
    destination="$JACKTOOLS_BACKUP_ROOT/$label-$(date '+%Y%m%d-%H%M%S-%N')"
    cp -a -- "$source" "$destination"
    log_write INFO "backup $source -> $destination"
    printf '%s' "$destination"
}

# atomic_install CANDIDATE DESTINATION MODE [OWNER] [GROUP]: replace DESTINATION in one rename.
atomic_install() {
    local candidate="$1" destination="$2" mode="$3" owner="${4:-root}" group="${5:-root}" temporary
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    temporary=$(mktemp "$(dirname -- "$destination")/.jacktools.XXXXXX")
    if ! {
        cp -- "$candidate" "$temporary" &&
        chmod "$mode" "$temporary" &&
        { [[ ${EUID} -ne 0 ]] || chown "$owner:$group" "$temporary"; } &&
        mv -f -- "$temporary" "$destination"
    }; then
        rm -f -- "$temporary"
        return 1
    fi
}

# fs_file_matches FILE CMD [ARGS...]: FILE exists and holds exactly the output of CMD.
fs_file_matches() {
    local file="$1"
    shift
    [[ -f "$file" ]] && cmp -s <("$@") "$file"
}

# fs_write_managed FILE LABEL MODE CMD [ARGS...]: write the output of CMD to FILE (a real
# path, already passed through root_path). Nothing happens when FILE already matches;
# otherwise parent directory, backup and atomic install. FS_UNDO tells fs_restore how to
# take the change back.
fs_write_managed() {
    local file="$1" label="$2" mode="$3" candidate backup
    shift 3
    FS_UNDO=""
    fs_mktemp candidate
    "$@" >"$candidate" || return 1
    [[ -f "$file" ]] && cmp -s "$candidate" "$file" && return 0
    [[ "$JACKTOOLS_DRY_RUN" == 1 ]] && return 0
    mkdir -p -- "$(dirname -- "$file")" || return 1
    backup=$(backup_file "$file" "$label") || return 1
    atomic_install "$candidate" "$file" "$mode" || return 1
    FS_UNDO="${backup:-remove}"
}

# fs_restore UNDO FILE: take back a change recorded by fs_write_managed (FS_UNDO).
fs_restore() {
    case "$1" in
        '') return 0 ;;
        remove) rm -f -- "$2" ;;
        *) cp -a -- "$1" "$2" ;;
    esac
}

# cache_get NAME CMD [ARGS...]: output of a slow read-only query, run once per JackTools run
# (stored as a file, so it also survives subshells). Failures are not cached.
cache_get() {
    local name="$1" file rc=0
    shift
    if [[ -z "$JT_CACHE_DIR" ]]; then "$@"; return; fi
    file="$JT_CACHE_DIR/$name"
    if [[ ! -f "$file" ]]; then
        "$@" >"$file.tmp" || rc=$?
        if (( rc == 0 )); then mv -f -- "$file.tmp" "$file"; else cat -- "$file.tmp"; rm -f -- "$file.tmp"; return "$rc"; fi
    fi
    cat -- "$file"
}

# cache_drop NAME...: forget cached answers after a change.
cache_drop() {
    local name
    [[ -n "$JT_CACHE_DIR" ]] || return 0
    for name in "$@"; do rm -f -- "$JT_CACHE_DIR/$name"; done
}

# managed_block_status FILE BEGIN END: 0 one well-formed block, 1 no block, 2 malformed.
managed_block_status() {
    local file="$1" begin="$2" end="$3"
    [[ -f "$file" ]] || return 1
    awk -v b="$begin" -v e="$end" '
        $0 == b { if (open) bad = 1; open = 1; blocks++; next }
        $0 == e { if (!open) bad = 1; open = 0; next }
        END {
            if (open || bad || blocks > 1) exit 2
            exit (blocks == 1 ? 0 : 1)
        }
    ' "$file"
}

# managed_block_render SOURCE BEGIN END CONTENT OUTPUT
# Writes SOURCE to OUTPUT with the block replaced in place, or appended after one blank
# line when absent. Rendering twice gives the same result. A missing SOURCE counts as empty.
managed_block_render() {
    local source="$1" begin="$2" end="$3" content="$4" output="$5" status=0
    if grep -Fxq -e "$begin" -e "$end" -- "$content"; then return 2; fi
    [[ -e "$source" ]] || source=/dev/null
    managed_block_status "$source" "$begin" "$end" || status=$?
    (( status != 2 )) || return 2
    awk -v b="$begin" -v e="$end" -v content="$content" '
        BEGIN { while ((getline line < content) > 0) block[++size] = line; close(content) }
        function emit_block(   i) {
            out[++n] = b
            for (i = 1; i <= size; i++) out[++n] = block[i]
            out[++n] = e
        }
        $0 == b { emit_block(); skipping = 1; done = 1; next }
        skipping { if ($0 == e) skipping = 0; next }
        { out[++n] = $0 }
        END {
            if (!done) {
                while (n > 0 && out[n] == "") n--
                if (n > 0) out[++n] = ""
                emit_block()
            }
            for (i = 1; i <= n; i++) print out[i]
        }
    ' "$source" >"$output"
}
