#!/bin/sh

## arkenfox user.js updater for Linux and macOS
## authors: @overdodactyl, @earthlng, @ema-pe, @claustromaniac, @infinitewarp, @9ao9ai9ar
## version: 4.1

## Make sure the version is of the format major.minor
## and within the first five lines ( because of the way the sed script is written ).

###################################################
#            Common utility functions             #
# (shared between updater.sh and prefsCleaner.sh) #
###################################################

probe_terminal() {
    # Colors used for printing
    if tput setaf >/dev/null && tput sgr0 >/dev/null; then
        RED=$(tput setaf 1)
        BLUE=$(tput setaf 4)
        BBLUE="$(tput bold)$(tput setaf 4)"
        GREEN=$(tput setaf 2)
        ORANGE=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        NC=$(tput sgr0) # No Color
    fi
}

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
        printf '%s\n%s\n' "${RED}This script requires curl or wget." "Process aborted${NC}\n" >&2
        exit 1
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

open_file() { # expects one argument: file_path
    if [ "$(uname)" = 'Darwin' ]; then
        open "$1"
    elif [ "$(uname -s | cut -c -5)" = 'Linux' ]; then
        xdg-open "$1"
    else
        printf '%s\n' "${RED}Error: Sorry, opening files is not supported for your OS.${NC}"
    fi
}

get_script_version() {
    sed -n '5 s/.*[[:blank:]]\([[:digit:]]*\.[[:digit:]]*\)/\1/p' "$1"
}

# read -rN 1 equivalent in POSIX shell: https://unix.stackexchange.com/a/464963
read1() { # arg: <variable-name>
    if [ -t 0 ]; then
        # if stdin is a tty device, put it out of icanon, set min and
        # time to sane value, but don't otherwise touch other input or
        # or local settings (echo, isig, icrnl...). Take a backup of the
        # previous settings beforehand.
        saved_tty_settings=$(stty -g)
        stty -icanon min 1 time 0
    fi
    eval "$1="
    while
        # read one byte, using a work around for the fact that command
        # substitution strips trailing newline characters.
        c=$(
            dd bs=1 count=1 2>/dev/null
            echo .
        )
        c=${c%.}

        # break out of the loop on empty input (eof) or if a full character
        # has been accumulated in the output variable (using "wc -m" to count
        # the number of characters).
        [ -n "$c" ] &&
            eval "$1=\${$1}"'$c
        [ "$(($(printf %s "${'"$1"'}" | wc -m)))" -eq 0 ]'
    do
        continue
    done
    if [ -t 0 ]; then
        # restore settings saved earlier if stdin is a tty device.
        stty "$saved_tty_settings"
    fi
}

#################################
# updater.sh specific functions #
#################################

usage() {
    cat <<EOF

${BLUE}Usage: $0 [-bcdehlnrsuv] [-p PROFILE] [-o OVERRIDE]${NC}

Optional Arguments:
    -h           Show this help message and exit.
    -p PROFILE   Path to your Firefox profile (if different than the dir of this script)
                 IMPORTANT: If the path contains spaces, wrap the entire argument in quotes.
    -l           Choose your Firefox profile from a list
    -u           Update updater.sh and execute silently.  Do not seek confirmation.
    -d           Do not look for updates to updater.sh.
    -s           Silently update user.js.  Do not seek confirmation.
    -b           Only keep one backup of each file.
    -c           Create a diff file comparing old and new user.js within userjs_diffs.
    -o OVERRIDE  Filename or path to overrides file (if different than user-overrides.js).
                 If used with -p, paths should be relative to PROFILE or absolute paths
                 If given a directory, all files inside will be appended recursively.
                 You can pass multiple files or directories by passing a comma separated list.
                     Note: If a directory is given, only files inside ending in the extension .js are appended
                     IMPORTANT: Do not add spaces between files/paths.  Ex: -o file1.js,file2.js,dir1
                     IMPORTANT: If any file/path contains spaces, wrap the entire argument in quotes.
                         Ex: -o "override folder"
    -n           Do not append any overrides, even if user-overrides.js exists.
    -v           Open the resulting user.js file.
    -r           Only download user.js to a temporary file and open it.
    -e           Activate ESR related preferences.

EOF
}

show_banner() {
    cat <<EOF
${BBLUE}
                ############################################################################
                ####                                                                    ####
                ####                          arkenfox user.js                          ####
                ####       Hardening the Privacy and Security Settings of Firefox       ####
                ####           Maintained by @Thorin-Oakenpants and @earthlng           ####
                ####            Updater for macOS and Linux by @overdodactyl            ####
                ####                                                                    ####
                ############################################################################
${NC}

Documentation for this script is available here: ${CYAN}https://github.com/arkenfox/user.js/wiki/5.1-Updater-[Options]#-maclinux${NC}

EOF
}

update_script() {
    [ "$UPDATE" = 'no' ] && return 0 # User signified not to check for updates
    tmpfile=$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/updater.sh')
    [ -z "${tmpfile}" ] && printf '%s\n' "${RED}Error! Could not download updater.sh${NC}" >&2 && return 1 # check if download failed
    local_version=$(get_script_version "$SCRIPT_FILE")
    remote_version=$(get_script_version "${tmpfile}")
    if [ "${local_version%.*}" -eq "${remote_version%.*}" ] && [ "${local_version#*.}" -lt "${remote_version#*.}" ] ||
        [ "${local_version%.*}" -lt "${remote_version%.*}" ]; then
        if [ "$UPDATE" = 'check' ]; then
            printf '%s\n' "There is a newer version of updater.sh available. ${RED}Update and execute Y/N?${NC}"
            read1 REPLY
            printf '\n\n\n'
            [ "$REPLY" != 'Y' ] && [ "$REPLY" != 'y' ] && return 0 # Update available, but user chooses not to update
        fi
    else
        return 0 # No update available
    fi
    mv "${tmpfile}" "$SCRIPT_FILE"
    chmod u+x "$SCRIPT_FILE"
    "$SCRIPT_FILE" "$@" -d
    exit 0
}

get_profile_path() {
    f1=~/Library/Application\ Support/Firefox/profiles.ini
    f2=~/.mozilla/firefox/profiles.ini
    if [ "$PROFILE_PATH" = false ]; then
        PROFILE_PATH=$(dirname "${SCRIPT_FILE}")
    elif [ "$PROFILE_PATH" = 'list' ]; then
        if [ -f "$f1" ]; then
            read_ini_file "$f1" # updates PROFILE_PATH or exits on error
        elif [ -f "$f2" ]; then
            read_ini_file "$f2"
        else
            printf '%s\n' "${RED}Error: Sorry, -l is not supported for your OS${NC}"
            exit 1
        fi
        #    else
        #        : PROFILE_PATH already set by user with -p
    fi
}

read_ini_file() { # expects one argument: absolute path of profiles.ini
    inifile=$1
    # tempIni will contain: [ProfileX], Name=, IsRelative= and Path= (and Default= if present) of the only (if) or the selected (else) profile
    if [ "$(grep -c '^\[Profile' "${inifile}")" -eq '1' ]; then ### only 1 profile found
        tempIni=$(grep '^\[Profile' -A 4 "${inifile}")
    else
        ## cmd-substitution to strip trailing newlines and in quotes to keep internal ones:
        cat <<EOF
Profiles found:
––––––––––––––––––––––––––––––
$(grep --color=never -E 'Default=[^1]|\[Profile[0-9]*\]|Name=|Path=|^$' "${inifile}")
––––––––––––––––––––––––––––––
Select the profile number ( 0 for Profile0, 1 for Profile1, etc ) :
EOF
        read -r REPLY
        case "$REPLY" in
            0 | [1-9] | [1-9][0-9]*)
                tempIni=$(grep "^\[Profile${REPLY}" -A 4 "${inifile}") || {
                    printf '\n\n%s\n' "${RED}Profile${REPLY} does not exist!${NC}" && exit 1
                }
                ;;
            *)
                printf '\n\n%s\n' "${RED}Invalid selection!${NC}" && exit 1
                ;;
        esac
    fi
    # extracting 0 or 1 from the "IsRelative=" line
    pathisrel=$(printf '%s\n' "${tempIni}" | sed -n 's/^IsRelative=\([01]\)$/\1/p')
    # extracting only the path itself, excluding "Path="
    PROFILE_PATH=$(printf '%s\n' "${tempIni}" | sed -n 's/^Path=\(.*\)$/\1/p')
    # update global variable if path is relative
    [ "${pathisrel}" = '1' ] && PROFILE_PATH="$(dirname "${inifile}")/${PROFILE_PATH}"
}

# Applies latest version of user.js and any custom overrides
update_userjs() {
    newfile=$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js')
    [ -z "${newfile}" ] && printf '%s\n' "${RED}Error! Could not download user.js${NC}" && return 1 # check if download failed
    cat <<EOF
Please observe the following information:
    Firefox profile:  ${ORANGE}$(pwd)${NC}
    Available online: ${ORANGE}$(get_userjs_version "$newfile")${NC}
    Currently using:  ${ORANGE}$(get_userjs_version user.js)${NC}


EOF
    if [ "$CONFIRM" = 'yes' ]; then
        printf '%s\n' "This script will update to the latest user.js file and append any custom configurations from user-overrides.js. ${RED}Continue Y/N? ${NC}"
        read1 REPLY
        if [ "$REPLY" != 'Y' ] && [ "$REPLY" != 'y' ]; then
            printf '\n\n%s\n' "${RED}Process aborted${NC}"
            rm "$newfile"
            return 1
        fi
    fi
    # Copy a version of user.js to diffs folder for later comparison
    if [ "$COMPARE" = true ]; then
        mkdir -p userjs_diffs
        cp user.js userjs_diffs/past_user.js >/dev/null 2>&1
    fi
    # backup user.js
    mkdir -p userjs_backups
    bakname="userjs_backups/user.js.backup.$(date +"%Y-%m-%d_%H%M")"
    [ "$BACKUP" = 'single' ] && bakname='userjs_backups/user.js.backup'
    cp user.js "$bakname" >/dev/null 2>&1
    mv "${newfile}" user.js
    printf '\n\n%s\n' "Status: ${GREEN}user.js has been backed up and replaced with the latest version!${NC}"
    if [ "$ESR" = true ]; then
        sed -e 's/\/\* \(ESR[0-9]\{2,\}\.x still uses all.*\)/\/\/ \1/' user.js >user.js.tmp && mv user.js.tmp user.js
        printf '%s\n' "Status: ${GREEN}ESR related preferences have been activated!${NC}"
    fi
    # apply overrides
    if [ "$SKIPOVERRIDE" = false ]; then
        IFS=,
        for FILE in $OVERRIDE; do
            add_override "$FILE"
        done
        unset IFS
    fi
    # create diff
    if [ "$COMPARE" = true ]; then
        pastuserjs='userjs_diffs/past_user.js'
        past_nocomments='userjs_diffs/past_userjs.txt'
        current_nocomments='userjs_diffs/current_userjs.txt'
        remove_comments "$pastuserjs" "$past_nocomments"
        remove_comments user.js "$current_nocomments"
        diffname="userjs_diffs/diff_$(date +"%Y-%m-%d_%H%M").txt"
        diff=$(diff -w -B -U 0 "$past_nocomments" "$current_nocomments")
        if [ -n "$diff" ]; then
            printf '%s\n' "$diff" >"$diffname"
            printf '%s\n' "Status: ${GREEN}A diff file was created:${NC} ${PWD}/${diffname}"
        else
            printf '%s\n' "Warning: ${ORANGE}Your new user.js file appears to be identical.  No diff file was created.${NC}"
            [ "$BACKUP" = 'multiple' ] && rm "$bakname" >/dev/null 2>&1
        fi
        rm "$past_nocomments" "$current_nocomments" "$pastuserjs" >/dev/null 2>&1
    fi
    [ "$VIEW" = true ] && open_file "${PWD}/user.js"
}

get_userjs_version() {
    [ -e "$1" ] && sed -n '4p' "$1" || echo 'Not detected.'
}

add_override() {
    input=$1
    if [ -f "$input" ]; then
        echo >>user.js
        cat "$input" >>user.js
        printf '%s\n' "Status: ${GREEN}Override file appended:${NC} ${input}"
    elif [ -d "$input" ]; then
        SAVEIFS=$IFS
        IFS=$(printf '\n\b')
        # False positive?
        # shellcheck disable=SC2125
        FILES="${input}"/*.js
        for f in $FILES; do
            add_override "$f"
        done
        IFS=$SAVEIFS # restore $IFS
    else
        printf '%s\n' "${ORANGE}Warning: Could not find override file:${NC} ${input}"
    fi
}

remove_comments() { # expects 2 arguments: from-file and to-file
    sed -e '/^\/\*.*\*\/[[:space:]]*$/d' -e '/^\/\*/,/\*\//d' -e 's|^[[:space:]]*//.*$||' -e '/^[[:space:]]*$/d' -e 's|);[[:space:]]*//.*|);|' "$1" >"$2"
}

################
# Main program #
################

probe_terminal
probe_permission
probe_downloader
probe_readlink
SCRIPT_FILE=$(preadlink "$0") && [ -f SCRIPT_FILE ] || exit 1
UPDATE='check'
CONFIRM='yes'
OVERRIDE='user-overrides.js'
BACKUP='multiple'
COMPARE=false
SKIPOVERRIDE=false
VIEW=false
PROFILE_PATH=false
ESR=false
if [ $# != 0 ]; then
    # Display usage if first argument is -help or --help
    if [ "$1" = '--help' ] || [ "$1" = '-help' ]; then
        usage
        exit 0
    else
        while getopts ':hp:ludsno:bcvre' opt; do
            case $opt in
                h)
                    usage
                    exit 0
                    ;;
                p)
                    PROFILE_PATH=${OPTARG}
                    ;;
                l)
                    PROFILE_PATH='list'
                    ;;
                u)
                    UPDATE='yes'
                    ;;
                d)
                    UPDATE='no'
                    ;;
                s)
                    CONFIRM='no'
                    ;;
                n)
                    SKIPOVERRIDE=true
                    ;;
                o)
                    OVERRIDE=${OPTARG}
                    ;;
                b)
                    BACKUP='single'
                    ;;
                c)
                    COMPARE=true
                    ;;
                v)
                    VIEW=true
                    ;;
                e)
                    ESR=true
                    ;;
                r)
                    tfile=$(download_file 'https://raw.githubusercontent.com/arkenfox/user.js/master/user.js')
                    [ -z "${tfile}" ] && printf '%s\n' "${RED}Error! Could not download user.js${NC}" && exit 1 # check if download failed
                    mv "$tfile" "${tfile}.js"
                    printf '%s\n' "${ORANGE}Warning: user.js was saved to temporary file ${tfile}.js${NC}"
                    open_file "${tfile}.js"
                    exit 0
                    ;;
                \?)
                    printf '%s\n' "${RED}\n Error! Invalid option: -$OPTARG${NC}" >&2
                    usage >&2
                    exit 1
                    ;;
                :)
                    printf '%s\n' "${RED}Error! Option -$OPTARG requires an argument.${NC}" >&2
                    exit 2
                    ;;
            esac
        done
    fi
fi
show_banner
update_script "$@"
get_profile_path # updates PROFILE_PATH or exits on error
cd "$PROFILE_PATH" || exit 1
probe_permission
update_userjs
