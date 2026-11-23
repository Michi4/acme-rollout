#!/bin/sh
# Shared helpers for deploy/fleet.sh and deploy/sync.sh.
# Sourced, not executed directly.

: "${DEPLOY_STATE_DIR:=/data/deploy-state}"

# Certificate name -> directory name for the deploy state.
# "*.example.com" becomes "wildcard.example.com" so no "*" ends up in paths.
fleet_slug() {
    case "$1" in
        \*.*) printf 'wildcard.%s' "${1#\*.}" ;;
        *)    printf '%s' "$1" ;;
    esac
}

fleet_valid_name() {
    case "$1" in
        ''|.*|*..*|*.|*[!a-z0-9.-]*) return 1 ;;
    esac
    return 0
}

# host or host:port
fleet_valid_host() {
    case "$1" in
        ''|-*|.*|*..*|*.|*[!A-Za-z0-9.:-]*) return 1 ;;
    esac
    return 0
}

# Sets FH_HOST and FH_PORT.
fleet_split_host() {
    case "$1" in
        *:*) FH_HOST=${1%:*}; FH_PORT=${1##*:} ;;
        *)   FH_HOST=$1;      FH_PORT=22 ;;
    esac
}

# Group and/or host list -> one line per target on stdout.
# A group is re-read from /config/groups on every call.
fleet_resolve() {
    _fg=$1
    _fl=$2
    if [ -n "$_fg" ]; then
        _fgd=${DEPLOY_GROUPS_DIR:-/config/groups}
        if [ "$_fg" = all ]; then
            set -- "$_fgd"/*.txt
            if [ ! -e "$1" ]; then
                echo "error: no groups in $_fgd" >&2
                return 1
            fi
        else
            case "$_fg" in
                *[!a-z0-9_-]*)
                    echo "error: DEPLOY_GROUP invalid: $_fg" >&2
                    return 1
                    ;;
            esac
            set -- "$_fgd/$_fg.txt"
            if [ ! -f "$1" ]; then
                echo "error: group $_fg missing ($1)" >&2
                return 1
            fi
        fi
        awk 'NF && $1 !~ /^#/ { print $1 }' "$@" | awk '!seen[$0]++'
    else
        printf '%s' "$_fl" | tr ',' ' ' | tr ' ' '\n' | awk 'NF && !seen[$0]++'
    fi
}

fleet_state_file() {
    printf '%s/%s/%s_%s' "$DEPLOY_STATE_DIR" "$(fleet_slug "$1")" "$2" "$3"
}

# Sets FS_OK (last success), FS_TRY (last attempt), FS_FAILS.
fleet_state_read() {
    FS_OK=0
    FS_TRY=0
    FS_FAILS=0
    _fsf=$(fleet_state_file "$1" "$2" "$3")
    [ -f "$_fsf" ] || return 0
    read -r FS_OK FS_TRY FS_FAILS < "$_fsf" || true
    case "$FS_OK$FS_TRY$FS_FAILS" in
        ''|*[!0-9]*) FS_OK=0; FS_TRY=0; FS_FAILS=0 ;;
    esac
}

# ok try fails
fleet_state_write() {
    _fsf=$(fleet_state_file "$1" "$2" "$3")
    mkdir -p "${_fsf%/*}" || return 0
    printf '%s %s %s\n' "$4" "$5" "$6" > "$_fsf.$$" &&
        mv "$_fsf.$$" "$_fsf"
}

# Read a value from an acme.sh domain config without filling the current shell
# with its variables.
fleet_conf_get() {
    ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}
