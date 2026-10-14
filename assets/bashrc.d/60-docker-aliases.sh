# jt-module: docker-aliases | Scorciatoie Docker: dock, dockly, lazydocker (se Docker è installato) | off
if command -v docker >/dev/null 2>&1; then
    alias dock="sudo docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}'"
    alias dockly='sudo docker run -it --rm -v /var/run/docker.sock:/var/run/docker.sock lirantal/dockly'
    alias lazydocker='sudo docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock -v "$HOME/.config/lazydocker:/.config/jesseduffield/lazydocker" lazyteam/lazydocker'
fi
