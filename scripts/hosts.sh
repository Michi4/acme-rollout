#!/bin/sh
# Print the hosts of a group (one server per line).
#
#   ./scripts/hosts.sh web
#   ./scripts/hosts.sh all
#
# Groups live in config/groups/<name>.txt. "all" takes every group.
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "Usage: $0 <group|all>" >&2; exit 1; }
dir=config/groups

case "$1" in
    all)
        set -- "$dir"/*.txt
        [ -e "$1" ] || { echo "no groups in $dir" >&2; exit 1; }
        ;;
    *[!a-z0-9_-]*|'')
        echo "invalid group: $1" >&2
        exit 1
        ;;
    *)
        [ -f "$dir/$1.txt" ] || { echo "group missing: $dir/$1.txt" >&2; exit 1; }
        set -- "$dir/$1.txt"
        ;;
esac

awk '
    NF && $1 !~ /^#/ {
        if ($1 !~ /^[A-Za-z0-9][A-Za-z0-9.:-]*$/) {
            print "invalid host: " $1 > "/dev/stderr"
            bad = 1
            next
        }
        if (!seen[$1]++) print $1
    }
    END { exit bad }
' "$@"
