#!/bin/bash

line() {
    l=''
    for i in $(seq $(tput cols)); do
        l="$l═"
    done
    echo $l
}

# this colors part is redundant, but I keep it for using this as completly standalone script with remote files

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

# main
header() {

    echo -ne " Tools 
$(printblue '1)') update & upgrade
$(printpurple '2)') check free space (current directory)

$(printgreen '9)') Go Back to MAIN MENU
$(printred '0)') Exit
Choose an option:  "

    read -r ans
    case $ans in
    1)
        clear
        line
        updateSystem
        line
        ttoolsmenu
        ;;
    2)
        clear
        line
        checkFreeSpace
        line
        ttoolsmenu
        ;;
    9)
        mainmenu
        ;;
    0)
        if [ -z "$(type -t fn_bye)" ]; then
            clear
            echo "Bye bye!"
            exit 0
        else
            fn_bye
        fi

        ;;
    *)
        fn_fail "ttoolsmenu" $ans
        ;;
    esac
}

updateSystem() {
    sudo apt update
    sudo apt upgrade -y
}

checkFreeSpace() {
    du -sh ./* | sort -h 
}

ttoolsmenu() {
    header
}

ttoolsmenu
