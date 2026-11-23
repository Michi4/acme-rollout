#!/bin/sh
# Loaded by issue.sh and deploy.sh: split the target into group and host list.
#
# Sets:
#   group  group (including "all") or empty for an explicit host list
#   hosts  space separated host list

resolve_target() {
    [ -n "${1:-}" ] || { echo "no hosts given" >&2; return 1; }
    group=""
    case "$1" in
        all)
            group=all
            ;;
        *[!a-z0-9_-]*)
            ;;                  # host list (contains . , or :)
        *)
            [ -f "config/groups/$1.txt" ] \
                || { echo "group missing: config/groups/$1.txt" >&2; return 1; }
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
        || { echo "no hosts given${group:+ (group $group is empty)}" >&2; return 1; }
}
