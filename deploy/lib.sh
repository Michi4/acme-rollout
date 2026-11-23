#!/bin/sh
# Gemeinsame Helfer fuer deploy/fleet.sh und deploy/sync.sh.
# Wird geladen, nicht direkt ausgefuehrt.

: "${DEPLOY_STATE_DIR:=/data/deploy-state}"

# Zertifikatsname -> Verzeichnisname fuer den Deploy-Status.
# "*.example.com" wird zu "wildcard.example.com", damit kein "*" in Pfaden steht.
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

# host oder host:port
fleet_valid_host() {
    case "$1" in
        ''|-*|.*|*..*|*.|*[!A-Za-z0-9.:-]*) return 1 ;;
    esac
    return 0
}

# Setzt FH_HOST und FH_PORT.
fleet_split_host() {
    case "$1" in
        *:*) FH_HOST=${1%:*}; FH_PORT=${1##*:} ;;
        *)   FH_HOST=$1;      FH_PORT=22 ;;
    esac
}

# Gruppe und/oder Hostliste -> eine Zeile pro Ziel auf stdout.
# Eine Gruppe wird bei jedem Aufruf neu aus /config/groups gelesen.
fleet_resolve() {
    _fg=$1
    _fl=$2
    if [ -n "$_fg" ]; then
        _fgd=${DEPLOY_GROUPS_DIR:-/config/groups}
        if [ "$_fg" = all ]; then
            set -- "$_fgd"/*.txt
            if [ ! -e "$1" ]; then
                echo "fehler: keine Gruppen in $_fgd" >&2
                return 1
            fi
        else
            case "$_fg" in
                *[!a-z0-9_-]*)
                    echo "fehler: DEPLOY_GROUP ungueltig: $_fg" >&2
                    return 1
                    ;;
            esac
            set -- "$_fgd/$_fg.txt"
            if [ ! -f "$1" ]; then
                echo "fehler: Gruppe $_fg fehlt ($1)" >&2
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

# Setzt FS_OK (letzter Erfolg), FS_TRY (letzter Versuch), FS_FAILS.
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

# Liest einen Wert aus einer acme.sh-Domain-Config, ohne die aktuelle Shell
# mit deren Variablen zu fuellen.
fleet_conf_get() {
    ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}
