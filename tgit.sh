#!/bin/bash

# main
header() {
    line
    echo -ne "Current folder: $(printblue $(pwd)) | "

    # current folder is GIT
    isGIT=$(
        git -C $(pwd) rev-parse 2>/dev/null
        echo $?
    )

    case $isGIT in
    128)
        echo -ne "$(printBGred 'WARNING'): $(printred 'no GIT repository!')
"
        _menu_no_git
        ;;
    0)
        echo -ne "$(printgreen 'GIT ✓')"
        getgitinfo
        echo -ne "
"
        _menu_with_git
        ;;
    esac

}

getgitinfo() {
    # "??" are the untracked (files or folder)
    untrackCounter=( $(git status -s | grep ?? | wc -l))

    # "M " (one space) is modified, not staged; "M  " (two spaces) is also staged ("A  " is staged a new added)
    stagedCounter=($(git status --porcelain | grep "M  \|A  " | wc -l))
    if [[ ! -n "$stagedCounter" ]]
    then
        stagedCounter=0
    fi
    modifiedCounter=$(( $(git status --porcelain | grep "M " | grep --invert-match "M  " |  wc -l) ))

    unpushedCommit=$(( $(git status | grep "Your branch " | grep --invert-match "is up to date" | wc -l ) ))

    if [[ $untrackCounter != 0 || $modifiedCounter != 0 ]]
    then
        echo -n " | $(printred 'Untracked: ')"
        echo -n $(printred $untrackCounter)
        echo -n " | $(printred 'Modified: ')"
        echo -n $(printred $modifiedCounter)
    fi

    if [ $stagedCounter != 0 ]
    then
        echo -ne " | $(printyellow 'Staged:')"
        echo -n $(printyellow $stagedCounter)
    fi

    if [ $unpushedCommit != 0 ]
    then
        echo -ne " | $(printpurple '** Unpushed commits! **')"
    fi

}

# GIT configuration menu
configmenu() {
    line

    echo -ne "
$(printblue 'CONFIGURATION SUBMENU')
$(printgreen '1)') set mail (you@example.com) & set name (Your Name)
$(printmagenta '9)') Go Back to git menu
$(printred '0)') Exit
Choose an option:  "
    read -r ans
    case $ans in
    1)
        echo "What is your user.email 'you@example.com'?"
        read -r urmail
        $(git config --global user.email "$urmail")
        echo "Command: git config --global user.email \"$urmail\""
        echo "What is your user.name 'Your Name'?"
        read -r urname
        git config --global user.email "$urname"
        echo "Command: git config --global user.email \"$urname\""

#TODO doesn't work! please copy result in your terminal...

        pwd
        configmenu
        ;;
    9)
        tgitmenu
        ;;
    0)
        fn_bye
        ;;
    *)
        fn_fail "tgitmenu" $ans
        ;;
    esac
}



# Current Folder is NOT a GIT repository
_menu_no_git() {

    line

    echo -ne "
$(printgreen '1)') Initialize ($(find . -type f -not -path "./.git/*" | wc -l) file/s)

$(printblue ' cd') set directory

$(printmagenta '9)') Go Back to MAIN MENU
$(printred '0)') Exit
Command:  "
    read -r ans
    case $ans in
    1)
        printf "${BGWHITE}"
        git init
        printf "${RESET}\n"
        line
        tgitmenu
        ;;
    9)
        mainmenu
        ;;
    cd*)
        n=${#ans}
        if [ ${n} -gt 3 ]
        then
            _changedirectory "${ans#*cd }"
        else
            _changedirectory
        fi
        ;;
    0)
        fn_bye
        ;;
    *)
        fn_fail "tgitmenu" $ans
        ;;
    esac

}

_menu_with_git() {

    echo -ne "
$(printred '1) Add') all files        | 4) add remote       | 7) git fetch
$(printyellow '2) Commit') all files     | 5) checkout         | 8) git pull
$(printpurple '3) Push') commited files  | 6) git log          | 
$(printblue ' c') Configuration menu   | $(printblue ' reset') git reset    | $(printblue ' cd') set directory
$(printmagenta '9)') Go Back to MAIN MENU | $(printred '0)') Exit

Choose an option:  "
    read -r ans
    case $ans in
    1)
        printf "${BGWHITE}"
        git add -A .
        printf "${RESET}\n"
        tgitmenu
        ;;
    2)
        echo "what's your commit message?  "
        read -r MSG
        printf "${BGWHITE}"
        git commit -m "$MSG"
        printf "${RESET}\n"
        tgitmenu
        ;;
    3)
        printf "${BGWHITE}"
        git push
        printf "${RESET}\n"
        tgitmenu
        ;;
    4)
        _addremote
        ;;
    5)
        _changebranch
        ;;
    6)
        printf "${BGWHITE}"
        git log
        printf "${RESET}\n"
        tgitmenu
        ;;
    7)
        printf "${BGWHITE}"
        git fetch
        printf "${RESET}\n"
        tgitmenu
        ;;
    8)
        printf "${BGWHITE}"
        git pull
        printf "${RESET}\n"
        tgitmenu
        ;;
    'config'|'c'|'C')
        configmenu
        ;;
    'reset')
        read -p "Are you sure to git reset? (y/n)" -n 1 -r
        echo #new line
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
            git reset
        fi
        tgitmenu
        ;;
    cd*)
        n=${#ans}
        if [ ${n} -gt 3 ]
        then
            _changedirectory "${ans#*cd }"
        else
            _changedirectory
        fi
        ;;
    9)
        mainmenu
        ;;
    0)
        fn_bye
        ;;
    *)
        fn_fail "tgitmenu" $ans
        ;;
    esac
}

_addremote() {
    echo "what's remote name? (default: \"origin\")  "
        read -r ORIGIN
        if [[ ! "$ORIGIN" ]]
        then
            ORIGIN="origin"
        fi

        echo "what's remote address of [$ORIGIN]?  "
        read -r REMO

        if [[ "$REMO" =~ ^((git|ssh|http(s)?)|(git@[\w\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)(/)?$ ]]
        then
            printf "${BGWHITE}"
            $(git remote add "$ORIGIN" "${REMO}")
            printf "${RESET}\n"
        else
            printf "${BGRED}"
            echo "Invalid GIT repo URL!"
            printf "${RESET}\n"
        fi

        tgitmenu
}

_changebranch() {

        printf "${BGWHITE}"
        git branch
        printf "${RESET}\n"
        echo "what's new branch name to checkout now? (default: \"main\")  "
        read -r BRANCH
        if [[ ! "$BRANCH" ]]
        then
            BRANCH="main"
        fi

        printf "${BGWHITE}"
        git checkout "$BRANCH"
        printf "${RESET}\n"

        tgitmenu
}

_changedirectory() {

        currentDir="$1"

        ##TODO PARAMS LOST / URGENT
        if [[ ! "$currentDir" ]]
        then
            currentDir="$(pwd)"
        fi

        echo "Change to Directory... (write or hit Enter for: $(printblue $currentDir) )  "
        read -r NEWDIRECTORY
        if [[ ! "$NEWDIRECTORY" ]]
        then
            NEWDIRECTORY="${currentDir}"
        fi

        cd $NEWDIRECTORY
        echo $(pwd)

        tgitmenu
}

tgitmenu() {
    header

}

tgitmenu
