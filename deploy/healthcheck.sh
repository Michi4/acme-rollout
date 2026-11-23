#!/bin/sh
# Fail when the renewal loop has not completed a cycle for too long.
#
# The entrypoint writes /data/.started at boot and /data/.last-cycle after every
# round. Two intervals plus ten minutes are allowed; a hung ACME request or a
# dead loop then shows up in `docker compose ps` instead of silently doing
# nothing.
set -u

home=${ACME_HOME:-/data}
interval=${ACME_INTERVAL:-21600}
case "$interval" in
    ''|*[!0-9]*) interval=21600 ;;
esac

stamp="$home/.last-cycle"
[ -f "$stamp" ] || stamp="$home/.started"
[ -f "$stamp" ] || exit 0

now=$(date +%s)
last=$(cat "$stamp" 2>/dev/null || echo 0)
case "$last" in
    ''|*[!0-9]*) exit 0 ;;
esac

limit=$((interval * 2 + 600))
age=$((now - last))
if [ "$age" -le "$limit" ]; then
    exit 0
fi
echo "last cycle ${age}s ago (limit ${limit}s)"
exit 1
