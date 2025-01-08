#!/bin/bash

tput init # reset colors
clear

### Colors ##
ESC=$(printf '\033') RESET="${ESC}[0m"
BLACK="${ESC}[30m" RED="${ESC}[31m" GREEN="${ESC}[32m" YELLOW="${ESC}[33m"
BLUE="${ESC}[34m" MAGENTA="${ESC}[35m" CYAN="${ESC}[36m" WHITE="${ESC}[37m"
PURPLE="${ESC}[35m"
# background
BGRED="${ESC}[41m" BGBLUE="${ESC}[44m" BGWHITE="${ESC}[47m"

DEFAULT="${ESC}[39m"

### Color Functions ##
printgreen() { printf "${GREEN}%s${RESET}\n" "$1"; }
printblue() { printf "${BLUE}%s${RESET}\n" "$1"; }
printred() { printf "${RED}%s${RESET}\n" "$1"; }
printyellow() { printf "${YELLOW}%s${RESET}\n" "$1"; }
printmagenta() { printf "${MAGENTA}%s${RESET}\n" "$1"; }
printcyan() { printf "${CYAN}%s${RESET}\n" "$1"; }
printpurple() { printf "${PURPLE}%s${RESET}\n" "$1"; }

printBGblue() { printf "${BGBLUE}%s${RESET}\n" "$1"; }
printBGred() { printf "${BGRED}%s${RESET}\n" "$1"; }
printBGwhite() { printf "${BGWHITE}%s${RESET}\n" "$1"; }

### Common function ##
fn_bye() { clear; echo "Bye bye!"; exit 0; }
fn_fail() {
    #echo "Wrong option. [$1]";
    #exit 1;
    line
    read -p "$(printBGred 'Wrong option!') You want to exit and launch [$(printred $2 $3 $4 $5 $6 $7 $8 $9)]? (y/n)" -n 1 -r
    echo #new line
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Bye bye"
        line
        echo
        $2 $3 $4 $5 $6 $7 $8 $9
        echo
        exit 0
    else
        $1 #relaunch menu
    fi
    $2 #relaunch menu
}

### line of width of current terminal ##
line() {
    l=''
    for i in $(seq $(tput cols)); do
        l="$l═"
    done
    echo $l
}

# warning sign
warning() {
echo -ne "
██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗
██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝
██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║
╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝
 ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝
"
}

mainmenu() {
    clear
    logo
    line
        echo -ne "
$(printred '1) Add') GIT tools
$(printmagenta '2)') Tools
$(printmagenta '9)') First Configuration | $(printred '0)') Exit

Choose an option:  "

    read -r ans
    case $ans in
    1)
        clear
        logo
        line
        source ./tgit.sh
        ;;
    2)
        clear
        logo
        line
        source ./ttools.sh
        ;;
    9)
        clear
        logo
        line
        source ./tfirst.sh
        ;;
    0)
        fn_bye
        ;;
    *)
        fn_fail "tmainmenu" $ans
        ;;
    esac

}

logo() {
echo -ne "      /¯/  ____ _  _____   /¯/__ /_¯ __/ ____   ____    /¯/   _____
 __  / /  / __ \`/ / ___/  / //_/  / /   / __ \ / __ \  / /   / ___/
/ /_/ /  / /_/ / / /__   /  <    / /   / /_/ // /_/ / / /   (__  ) 
\____/   \__,_/  \___/  /_/|_|  /_/    \____/ \____/ /_/   /____/
"
}

line
logo
mainmenu
