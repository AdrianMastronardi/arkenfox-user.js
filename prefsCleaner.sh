#!/bin/sh

## prefs.js cleaner for Linux and macOS
## authors: @claustromaniac, @overdodactyl, @earthlng, @9ao9ai9ar
## version: 2.2

###################################################
#            Common utility functions             #
# (shared between updater.sh and prefsCleaner.sh) #
###################################################

probe_permission() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "You shouldn't run this with elevated privileges (such as with doas/sudo)." >&2
        exit 1
    elif [ -n "$(find ./ -user 0)" ]; then
        echo 'It looks like this script was previously run with elevated privileges.' >&2
        echo 'You will need to change ownership of the following files to your user:' >&2
        find . -user 0
        exit 1
    fi
}

probe_downloader() {
    DOWNLOAD_METHOD=''
    if command -v curl >/dev/null; then
        DOWNLOAD_METHOD='curl --max-redirs 3 -so'
    elif command -v wget2 >/dev/null; then
        DOWNLOAD_METHOD='wget2 --max-redirect 3 -qO'
    elif command -v wget >/dev/null; then
        DOWNLOAD_METHOD='wget --max-redirect 3 -qO'
    else
        printf '%s\n%s\n' 'No curl or wget detected.' 'Automatic self-update disabled!' >&2
        AUTOUPDATE=false
    fi
}

probe_readlink() {
    if command realpath -- . 2>/dev/null; then
        preadlink() {
            command realpath -- "$@"
        }
    elif command readlink -f -- . 2>/dev/null; then
        preadlink() {
            command readlink -f -- "$@"
        }
    elif command greadlink -f -- . 2>/dev/null; then
        preadlink() {
            command greadlink -f -- "$@"
        }
    else
        # https://stackoverflow.com/a/29835459
        rreadlink() (# Execute the function in a *subshell* to localize variables and the effect of `cd`.

            # shellcheck disable=SC1007
            target=$1 fname= targetDir= CDPATH=

            # Try to make the execution environment as predictable as possible:
            # All commands below are invoked via `command`, so we must make sure that `command`
            # itself is not redefined as an alias or shell function.
            # (Note that command is too inconsistent across shells, so we don't use it.)
            # `command` is a *builtin* in bash, dash, ksh, zsh, and some platforms do not even have
            # an external utility version of it (e.g, Ubuntu).
            # `command` bypasses aliases and shell functions and also finds builtins
            # in bash, dash, and ksh. In zsh, option POSIX_BUILTINS must be turned on for that
            # to happen.
            {
                \unalias command
                \unset -f command
            } >/dev/null 2>&1
            # shellcheck disable=SC2034
            [ -n "$ZSH_VERSION" ] && options[POSIX_BUILTINS]=on # make zsh find *builtins* with `command` too.

            while :; do # Resolve potential symlinks until the ultimate target is found.
                [ -L "$target" ] || [ -e "$target" ] || {
                    command printf '%s\n' "ERROR: '$target' does not exist." >&2
                    return 1
                }
                # shellcheck disable=SC2164
                command cd "$(command dirname -- "$target")" # Change to target dir; necessary for correct resolution of target path.
                fname=$(command basename -- "$target")       # Extract filename.
                [ "$fname" = '/' ] && fname=''               # !! curiously, `basename /` returns '/'
                if [ -L "$fname" ]; then
                    # Extract [next] target path, which may be defined
                    # *relative* to the symlink's own directory.
                    # Note: We parse `ls -l` output to find the symlink target
                    #       which is the only POSIX-compliant, albeit somewhat fragile, way.
                    target=$(command ls -l "$fname")
                    target=${target#* -> }
                    continue # Resolve [next] symlink target.
                fi
                break # Ultimate target reached.
            done
            targetDir=$(command pwd -P) # Get canonical dir. path
            # Output the ultimate target's canonical path.
            # Note that we manually resolve paths ending in /. and /.. to make sure we have a normalized path.
            if [ "$fname" = '.' ]; then
                command printf '%s\n' "${targetDir%/}"
            elif [ "$fname" = '..' ]; then
                # Caveat: something like /var/.. will resolve to /private (assuming /var@ -> /private/var), i.e. the '..' is applied
                # AFTER canonicalization.
                command printf '%s\n' "$(command dirname -- "${targetDir}")"
            else
                command printf '%s\n' "${targetDir%/}/$fname"
            fi
        )

        preadlink() {
            if [ $# -le 0 ]; then
                echo 'preadlink: missing operand' >&2
            else
                while [ $# -gt 0 ]; do
                    rreadlink "$1"
                    shift
                done
            fi
        }
    fi
}

download_file() { # expects URL as argument ($1)
    tf=$(mktemp)
    $DOWNLOAD_METHOD "${tf}" "$1" >/dev/null 2>&1 && printf '%s\n' "$tf"
}

get_script_version() {
    sed -n '5 s/.*[[:blank:]]\([[:digit:]]*\.[[:digit:]]*\)/\1/p' "$1"
}

######################################
# prefsCleaner.sh specific functions #
######################################

usage() {
    cat <<EOF

Usage: $0 [-ds]

Optional Arguments:
    -s           Start immediately
    -d           Don't auto-update prefsCleaner.sh
EOF
}

show_banner() {
    cat <<'EOF'



                   ╔══════════════════════════╗
                   ║     prefs.js cleaner     ║
                   ║    by claustromaniac     ║
                   ║           v2.2           ║
                   ╚══════════════════════════╝

This script should be run from your Firefox profile directory.

It will remove any entries from prefs.js that also exist in user.js.
This will allow inactive preferences to be reset to their default values.

This Firefox profile shouldn't be in use during the process.

EOF
}

update_script() {
    tmpfile=$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/prefsCleaner.sh')
    [ -z "$tmpfile" ] && echo 'Error! Could not download prefsCleaner.sh' >&2 && return 1 # check if download failed
    [ "$(get_script_version "$SCRIPT_FILE")" = "$(get_script_version "$tmpfile")" ] && return 0
    mv "$tmpfile" "$SCRIPT_FILE"
    chmod u+x "$SCRIPT_FILE"
    "$SCRIPT_FILE" "$@" -d
    exit 0
}

start() {
    if [ ! -e user.js ]; then
        printf '\n%s\n' 'user.js not found in the current directory.' >&2
        exit 1
    elif [ ! -e prefs.js ]; then
        printf '\n%s\n' 'prefs.js not found in the current directory.' >&2
        exit 1
    fi
    check_firefox_running
    mkdir -p prefsjs_backups
    bakfile="prefsjs_backups/prefs.js.backup.$(date +"%Y-%m-%d_%H%M")"
    mv prefs.js "${bakfile}" || {
        printf '\n%s\n%s\n' 'Operation aborted.' "Reason: Could not create backup file $bakfile" >&2
        exit 1
    }
    printf '\n%s\n' "prefs.js backed up: $bakfile"
    echo 'Cleaning prefs.js...'
    clean "$bakfile"
    printf '\n%s\n' 'All done!'
    exit 0
}

check_firefox_running() {
    # there are many ways to see if firefox is running or not, some more reliable than others
    # this isn't elegant and might not be future-proof but should at least be compatible with any environment
    while [ -e lock ]; do
        printf '\n%s\n\n' 'This Firefox profile seems to be in use. Close Firefox and try again.' >&2
        printf 'Press any key to continue.' >&2
        read -r REPLY
    done
}

# FIXME: should also accept single quotes
clean() {
    prefexp="user_pref[     ]*\([     ]*[\"']([^\"']+)[\"'][     ]*,"
    known_prefs=$(grep -E "$prefexp" user.js | awk -F'["]' '/user_pref/{ print "\"" $2 "\"" }' | sort | uniq)
    unneeded_prefs=$(printf '%s\n' "$known_prefs" | grep -E -f - "$1" | grep -E -e "^$prefexp")
    grep -v -f - "$1" >prefs.js <<EOF
${unneeded_prefs}
EOF
}

################
# Main program #
################

probe_permission
probe_downloader
probe_readlink
SCRIPT_FILE=$(preadlink "$0") && [ -f SCRIPT_FILE ] || exit 1
AUTOUPDATE=true
QUICKSTART=false
while getopts 'sd' opt; do
    case $opt in
        s)
            QUICKSTART=true
            ;;
        d)
            AUTOUPDATE=false
            ;;
        \?)
            usage
            ;;
    esac
done
## change directory to the Firefox profile directory
cd "$(dirname "${SCRIPT_FILE}")" || exit 1
probe_permission
[ "$AUTOUPDATE" = true ] && update_script "$@"
show_banner
[ "$QUICKSTART" = true ] && start
printf '\n%s\n\n' 'In order to proceed, select a command below by entering its corresponding number.'
while :; do
    printf '1) Start
2) Help
3) Exit
#? ' >&2
    while read -r REPLY; do
        case "$REPLY" in
            1)
                start
                ;;
            2)
                usage
                cat <<'EOF'

This script creates a backup of your prefs.js file before doing anything.
It should be safe, but you can follow these steps if something goes wrong:

1. Make sure Firefox is closed.
2. Delete prefs.js in your profile folder.
3. Delete Invalidprefs.js if you have one in the same folder.
4. Rename or copy your latest backup to prefs.js.
5. Run Firefox and see if you notice anything wrong with it.
6. If you do notice something wrong, especially with your extensions, and/or with the UI, go to about:support, and restart Firefox with add-ons disabled. Then, restart it again normally, and see if the problems were solved.
If you are able to identify the cause of your issues, please bring it up on the arkenfox user.js GitHub repository.

EOF
                ;;
            3)
                exit 0
                ;;
            '')
                break
                ;;
            *)
                :
                ;;
        esac
        printf '#? ' >&2
    done
done
exit 0
