#!/bin/sh

## prefs.js cleaner for Linux/Mac
## author: @claustromaniac
## version: 2.2

## special thanks to @overdodactyl and @earthlng for a few snippets that I stol..*cough* borrowed from the updater.sh

## DON'T GO HIGHER THAN VERSION x.9 !! ( because of ASCII comparison in update_prefsCleaner() )

readonly CURRDIR=$(pwd)

## get the full path of this script (readlink for Linux and macOS 12.3+, greadlink for Mac with coreutils installed)
# https://stackoverflow.com/q/29832037: rewriting ${BASH_SOURCE[0]} as $0 only works if script is not sourced.
SCRIPT_FILE=$(readlink -f -- "$0" 2>/dev/null || greadlink -f -- "$0" 2>/dev/null)
## fallback for Macs without coreutils
[ -z "$SCRIPT_FILE" ] && SCRIPT_FILE=$0

AUTOUPDATE=true
QUICKSTART=false

## download method priority: curl -> wget
DOWNLOAD_METHOD=''
if command -v curl >/dev/null; then
    DOWNLOAD_METHOD='curl --max-redirs 3 -so'
elif command -v wget >/dev/null; then
    DOWNLOAD_METHOD='wget --max-redirect 3 --quiet -O'
else
    AUTOUPDATE=false
    printf "No curl or wget detected.\nAutomatic self-update disabled!\n"
fi

fQuit() {
    ## change directory back to the original working directory
    cd "${CURRDIR}"
    [ "$1" -eq 0 ] && printf "\n$2\n" || printf "\n$2\n" >&2
    exit $1
}

fUsage() {
    printf "\nUsage: $0 [-ds]\n"
    printf "
Optional Arguments:
    -s           Start immediately
    -d           Don't auto-update prefsCleaner.sh\n"
}

download_file() { # expects URL as argument ($1)
    readonly tf=$(mktemp)

    $DOWNLOAD_METHOD "${tf}" "$1" >/dev/null 2>&1 && echo "$tf" || echo '' # return the temp-filename or empty string on error
}

fFF_check() {
    # there are many ways to see if firefox is running or not, some more reliable than others
    # this isn't elegant and might not be future-proof but should at least be compatible with any environment
    while [ -e lock ]; do
        printf "\nThis Firefox profile seems to be in use. Close Firefox and try again.\n\n" >&2
        printf "Press any key to continue." >&2
        read -r REPLY
    done
}

## returns the version number of a prefsCleaner.sh file
get_prefsCleaner_version() {
    echo "$(sed -n '5 s/.*[[:blank:]]\([[:digit:]]*\.[[:digit:]]*\)/\1/p' "$1")"
}

## updates the prefsCleaner.sh file based on the latest public version
update_prefsCleaner() {
    readonly tmpfile="$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/prefsCleaner.sh')"
    [ -z "$tmpfile" ] && printf "Error! Could not download prefsCleaner.sh\n" && return 1 # check if download failed

    [ "$(get_prefsCleaner_version "$SCRIPT_FILE")" = "$(get_prefsCleaner_version "$tmpfile")" ] && return 0

    mv "$tmpfile" "$SCRIPT_FILE"
    chmod u+x "$SCRIPT_FILE"
    "$SCRIPT_FILE" "$@" -d
    exit 0
}

fClean() {
    # the magic happens here
    prefexp="user_pref[     ]*\([     ]*[\"']([^\"']+)[\"'][     ]*,"
    known_prefs=$(grep -E "$prefexp" user.js | awk -F'["]' '/user_pref/{ print "\"" $2 "\"" }' | sort | uniq)
    unneeded_prefs=$(echo "$known_prefs" | grep -E -f - "$1" | grep -E -e "^$prefexp")
    grep -v -f - "$1" >prefs.js <<EOF
${unneeded_prefs}
EOF
}

fStart() {
    if [ ! -e user.js ]; then
        fQuit 1 "user.js not found in the current directory."
    elif [ ! -e prefs.js ]; then
        fQuit 1 "prefs.js not found in the current directory."
    fi

    fFF_check
    mkdir -p prefsjs_backups
    bakfile="prefsjs_backups/prefs.js.backup.$(date +"%Y-%m-%d_%H%M")"
    mv prefs.js "${bakfile}" || fQuit 1 "Operation aborted.\nReason: Could not create backup file $bakfile"
    printf "\nprefs.js backed up: $bakfile\n"
    echo "Cleaning prefs.js..."
    fClean "$bakfile"
    fQuit 0 "All done!"
}

while getopts "sd" opt; do
    case $opt in
        s)
            QUICKSTART=true
            ;;
        d)
            AUTOUPDATE=false
            ;;
        \?)
            fUsage
            ;;
    esac
done

## change directory to the Firefox profile directory
cd "$(dirname "${SCRIPT_FILE}")"

# Check if running as root and if any files have the owner as root/wheel.
if [ "$(id -u)" -eq 0 ]; then
    fQuit 1 "You shouldn't run this with elevated privileges (such as with doas/sudo)."
elif [ -n "$(find ./ -user 0)" ]; then
    printf 'It looks like this script was previously run with elevated privileges,
you will need to change ownership of the following files to your user:\n'
    find . -user 0
    fQuit 1
fi

[ "$AUTOUPDATE" = true ] && update_prefsCleaner "$@"

printf "\n\n\n"
echo "                   ╔══════════════════════════╗"
echo "                   ║     prefs.js cleaner     ║"
echo "                   ║    by claustromaniac     ║"
echo "                   ║           v2.2           ║"
echo "                   ╚══════════════════════════╝"
printf "\nThis script should be run from your Firefox profile directory.\n\n"
echo "It will remove any entries from prefs.js that also exist in user.js."
echo "This will allow inactive preferences to be reset to their default values."
printf "\nThis Firefox profile shouldn't be in use during the process.\n\n"

[ "$QUICKSTART" = true ] && fStart

printf "\nIn order to proceed, select a command below by entering its corresponding number.\n\n"

while :; do
    printf '1) Start
2) Help
3) Exit
#? ' >&2
    while read -r REPLY; do
        case "$REPLY" in
            1)
                fStart
                ;;
            2)
                fUsage
                printf "\nThis script creates a backup of your prefs.js file before doing anything.\n"
                printf "It should be safe, but you can follow these steps if something goes wrong:\n\n"
                echo "1. Make sure Firefox is closed."
                echo "2. Delete prefs.js in your profile folder."
                echo "3. Delete Invalidprefs.js if you have one in the same folder."
                echo "4. Rename or copy your latest backup to prefs.js."
                echo "5. Run Firefox and see if you notice anything wrong with it."
                echo "6. If you do notice something wrong, especially with your extensions, and/or with the UI, go to about:support, and restart Firefox with add-ons disabled. Then, restart it again normally, and see if the problems were solved."
                printf "If you are able to identify the cause of your issues, please bring it up on the arkenfox user.js GitHub repository.\n\n"
                ;;
            3)
                fQuit 0
                ;;
            '')
                break
                ;;
            *) ;;

        esac
        printf '#? ' >&2
    done
done

fQuit 0
