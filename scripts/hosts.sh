#!/bin/sh
# Hosts einer Gruppe ausgeben (eine Zeile pro Server).
#
#   ./scripts/hosts.sh web
#   ./scripts/hosts.sh all
#
# Gruppen liegen in config/groups/<name>.txt. "all" nimmt alle Gruppen.
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "Aufruf: $0 <gruppe|all>" >&2; exit 1; }
dir=config/groups

case "$1" in
    all)
        set -- "$dir"/*.txt
        [ -e "$1" ] || { echo "keine Gruppen in $dir" >&2; exit 1; }
        ;;
    *[!a-z0-9_-]*|'')
        echo "Gruppe ungueltig: $1" >&2
        exit 1
        ;;
    *)
        [ -f "$dir/$1.txt" ] || { echo "Gruppe fehlt: $dir/$1.txt" >&2; exit 1; }
        set -- "$dir/$1.txt"
        ;;
esac

awk '
    NF && $1 !~ /^#/ {
        if ($1 !~ /^[A-Za-z0-9][A-Za-z0-9.:-]*$/) {
            print "host ungueltig: " $1 > "/dev/stderr"
            bad = 1
            next
        }
        if (!seen[$1]++) print $1
    }
    END { exit bad }
' "$@"
