# jt-module: sysinfo | Riepilogo del sistema all'apertura della shell (non nei pannelli tmux) | on
if [ -z "${TMUX:-}" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "🖥  Hostname        : %s\n" "$(hostname)"
    printf "💻 OS              : %s\n" "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
    printf "⚡ CPU             : %s\n" "$(lscpu 2>/dev/null | awk -F: '/Model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
    printf "🧠 Memory          : %s / %s\n" "$(free -h | awk '/^Mem:/ { print $3 }')" "$(free -h | awk '/^Mem:/ { print $2 }')"
    printf "💾 Root Disk       : %s\n" "$(df -h / | awk 'NR == 2 { printf "%s / %s (%s)", $3, $2, $5 }')"
    printf "⏱  Uptime          : %s\n" "$(uptime -p)"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf "🐳 Docker          : %s running containers\n" "$(docker ps -q | wc -l)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
