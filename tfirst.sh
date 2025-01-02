#!/bin/bash

# variable to select local file or remote file
localfile=0

line() {
    l=''
    for i in $(seq $(tput cols)); do
        l="$l═"
    done
    echo $l
}

# Local file (if you have cloned the repository)
bashrc_customization_file="configuration/bashrc_customization.txt"
mypackages_file="configuration/mypackages.txt"
tmux_conf_file="configuration/tmux.conf"

# remote file (if you want to download files from github)
if [ $localfile -ne 1 ]; then

    # create directory for temporary files
    mkdir -p /tmp/jacktools

    # check if files are already downloaded
    if [ -f "/tmp/jacktools/bashrc_customization.txt" ] || [ -f "/tmp/jacktools/mypackages.txt" ] || [ -f "/tmp/jacktools/tmux.conf" ]; then
        echo "Files already downloaded"
        line
        bashrc_customization_file="/tmp/jacktools/bashrc_customization.txt"
        mypackages_file="/tmp/jacktools/mypackages.txt"
        tmux_conf_file="/tmp/jacktools/tmux.conf"
    else
        echo "Downloading configuration files from github"
        # download files from github
        wget https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/configuration/bashrc_customization.txt -O /tmp/jacktools/bashrc_customization.txt
        wget https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/configuration/mypackages.txt -O /tmp/jacktools/mypackages.txt
        wget https://raw.githubusercontent.com/jacklocke/jacktools/refs/heads/main/configuration/tmux.conf -O /tmp/jacktools/tmux.conf
        line
    fi

    bashrc_customization_file="/tmp/jacktools/bashrc_customization.txt"
    mypackages_file="/tmp/jacktools/mypackages.txt"
    tmux_conf_file="/tmp/jacktools/tmux.conf"

    # check if files are downloaded
    if [ ! -f "$bashrc_customization_file" ] || [ ! -f "$mypackages_file" ] || [ ! -f "$tmux_conf_file" ]; then
        echo "Error downloading files"
        exit 1
    fi
fi

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

$(printmagenta '7)') Delete temporary files (/tmp/jacktools)
$(printmagenta '8)') Delete user (es. ubuntu)
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
    7)
        clear
        line
        deleteTempFiles
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
    #read list
    mapfile -t packages <"$mypackages_file"

    for i in "${packages[@]}"; do
        echo "Installing $i"
        sudo apt install -y "$i"
    done
}

addBashrcCustomizations() {
    #ask for confirmation
    echo "This will add customizations to .bashrc file to current user. Continue? (y/n)"
    read -r confirm

    if [ "$confirm" = "y" ]; then

        # comment the row with "alias ll='ls -alF'" if exists without sed
        #TODO: fix this just for keep it clean (I use a different ll alias)
        #if grep -q "alias ll='ls -alF'" ~/.bashrc; then
            # sed -i '/alias ll='ls -alF'/s/^/#/' ~/.bashrc
        #fi

        todaydate=$(date +"%Y-%m-%d")

        #pass parameter for current home directory
        doBashrcAdd ~
    fi

}


# function to add customizations to .bashrc file in che home directory passed as parameter
doBashrcAdd() {

    home=$1

    # if no parameter is passed, do for current user
    if [ -z "$home" ]; then
        home=$HOME
    fi

    echo "" >>$home/.bashrc
    echo "" >>$home/.bashrc

    # Add markers to .bashrc to easily find autoamtic part in the future
    echo "##########START##########" >>$home/.bashrc
    echo "########$todaydate#######" >>$home/.bashrc
    echo "########################" >>$home/.bashrc

    #ask for current configuration
    echo "Insert current_cfg value (default is $(hostname)):"
    read -r current_cfg
    if [ -z "$current_cfg" ]; then
        current_cfg=$(hostname)
    fi

    echo "" >>$home/.bashrc
    echo "current_cfg=$current_cfg" >>$home/.bashrc
    echo "" >>$home/.bashrc

    #add customizations to .bashrc from file bashrc_customization.txt
    cat $bashrc_customization_file >>$home/.bashrc

    # ask for create tmux.conf if not exists
    echo "Create/overwrite also tmux.conf file? (y/n)"
    read -r tmux
    if [ "$tmux" = "y" ]; then
        cp $tmux_conf_file $home/.tmux.conf
    fi
}


deleteTempFiles() {
    # delete temporary files
    rm -rf /tmp/jacktools
    echo "Temporary files deleted."
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
