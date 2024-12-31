#!/bin/bash

# variable to select local file or remote file
localfile=1
bashrc_customization_file="configuration/bashrc_customization.txt"
mypackages_file="configuration/mypackages.txt"
tmux_conf_file="configuration/tmux.conf"

if [ $localfile -ne 1 ]; then
    # TODO
    echo "TODO"
fi

line() {
    l=''
    for i in $(seq $(tput cols)); do
        l="$l═"
    done
    echo $l
}


# this colors part is redundant, but I keep it for using tfirst.sh as completly standalone script with remote files

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

    echo -ne " FIRST configuration script
$(printblue '1)') update & upgrade
$(printyellow '2)') create user
$(printmagenta '3)') install common packages
$(printcyan '4)') add bashrc customizations

$(printred 'all)') Run all

$(printgreen '8)') Delete user (es. ubuntu)
$(printmagenta '9)') Go Back to MAIN MENU
$(printred '0)') Exit
Choose an option:  "

    read -r ans
    case $ans in
    1)
        clear
        line
        updateSystem
        line
        tfirstmenu
        ;;
    2)
        clear
        line
        userCreation
        line
        tfirstmenu
        ;;
    3)
        clear
        line
        installCommonPackages
        line
        tfirstmenu
        ;;
    4)
        clear
        line
        addBashrcCustomizations
        line
        tfirstmenu
        ;;
    8)
        clear
        line
        deleteUser
        line
        tfirstmenu
        ;;
    all)
        clear
        line
        updateSystem
        userCreation
        installCommonPackages
        addBashrcCustomizations
        line
        tfirstmenu
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
        fn_fail "tfirstmenu" $ans
        ;;
    esac
}

updateSystem() {
    sudo apt update
    sudo apt upgrade -y
}

userCreation() {
    #ask for username
    echo "Enter username: "
    read -r username
    #ask for password
    echo "Enter password: "
    read -r password
    #create user
    sudo useradd -m -s /bin/bash "$username"
    #set password
    echo "$username:$password" | sudo chpasswd
    #ask for sudo group
    echo "Is a sudo user? (y/n)"
    read -r sudo
    if [ "$sudo" = "y" ]; then
        #add user to sudo group
        sudo usermod -aG sudo "$username"
    fi
    #set bash to user
    sudo chsh -s /bin/bash "$username"
    #clear variables with password
    unset password
}

installCommonPackages() {
    sudo apt update
    #read list in file mypackages.txt
    while IFS= read -r line; do
        sudo apt install -y "$line"
    done <$mypackages_file
}

addBashrcCustomizations() {
    #ask for confirmation
    echo "This will add customizations to .bashrc file. Continue? (y/n)"
    read -r confirm

    if [ "$confirm" = "y" ]; then

        # comment the row with "alias ll='ls -alF'" if exists without sed
        #TODO: fix this just for keep it clean (I use a different ll alias)
        #if grep -q "alias ll='ls -alF'" ~/.bashrc; then
            # sed -i '/alias ll='ls -alF'/s/^/#/' ~/.bashrc
        #fi

        todaydate=$(date +"%Y-%m-%d")

        echo "" >>~/.bashrc
        echo "" >>~/.bashrc

        # Add markers to .bashrc to easily find autoamtic part in the future
        echo "##########START##########" >>~/.bashrc
        echo "########$todaydate#######" >>~/.bashrc
        echo "########################" >>~/.bashrc

        #ask for current configuration
        echo "Insert current_cfg value (default is $(hostname)):"
        read -r current_cfg
        if [ -z "$current_cfg" ]; then
            current_cfg=$(hostname)
        fi

        echo "" >>~/.bashrc
        echo "current_cfg=$current_cfg" >>~/.bashrc
        echo "" >>~/.bashrc

        #add customizations to .bashrc from file bashrc_customization.txt
        while IFS= read -r line; do
            echo "$line" >>~/.bashrc
        done <$bashrc_customization_file

        # ask for create tmux.conf if not exists
        echo "Create tmux.conf file? (y/n)"
        read -r tmux
        if [ "$tmux" = "y" ]; then
            # copy tmux.conf file to home directory
            cp $tmux_conf_file ~/.tmux.conf
        fi
    fi
}

deleteUser() {
    warning
    echo "⚠️ This will $(printred 'delete') the user and its home directory!"
    #ask for username
    echo "Enter username: (default:ubuntu, 0 to exit) "
    read -r username
    if [ "$username" = "0" ]; then
        return
    fi
    if [ -z "$username" ]; then
        username="ubuntu"
    fi
    if [ "$username" = "root" ]; then
        echo "You can't delete root user!"
        return
    fi

    # ask last confirmation
    echo "Are you sure to $(printred 'delete') $username? (y/n)"
    read -r confirm
    if [ "$confirm" != "y" ]; then
        return
    fi

    #delete user
    sudo deluser --remove-home "$username"
}

tfirstmenu() {
    header
}

tfirstmenu
