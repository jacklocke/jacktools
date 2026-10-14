# jt-module: useful-aliases | Alias utili: myip (IP pubblico), bat (se installato) | off
alias myip='curl -fsS https://ipinfo.io/ip; echo'
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
    alias bat='batcat'
fi
