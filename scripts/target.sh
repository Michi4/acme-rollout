#!/bin/sh
# Wird von issue.sh und deploy.sh geladen: Ziel in Gruppe und Hostliste trennen.
#
# Setzt:
#   group  Gruppe (auch "all") oder leer bei expliziter Hostliste
#   hosts  Hostliste mit Leerzeichen getrennt

resolve_target() {
    [ -n "${1:-}" ] || { echo "keine Hosts angegeben" >&2; return 1; }
    group=""
    case "$1" in
        all)
            group=all
            ;;
        *[!a-z0-9_-]*)
            ;;                  # Hostliste (enthaelt . , oder :)
        *)
            [ -f "config/groups/$1.txt" ] \
                || { echo "Gruppe fehlt: config/groups/$1.txt" >&2; return 1; }
            group=$1
            ;;
    esac

    if [ -n "$group" ]; then
        hosts=$(./scripts/hosts.sh "$group") || return 1
        hosts=$(printf '%s\n' "$hosts" | tr '\n' ' ')
        hosts=${hosts% }
    else
        hosts=$1
    fi
    [ -n "$hosts" ] \
        || { echo "keine Hosts angegeben${group:+ (Gruppe $group ist leer)}" >&2; return 1; }
}
