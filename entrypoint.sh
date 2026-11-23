#!/bin/sh
# Startet acme.sh mit Argumenten oder - ohne Argumente - die Erneuerungsschleife.
set -eu
if [ "$#" -gt 0 ]; then
    exec /opt/acme/acme.sh --home "${ACME_HOME:-/data}" "$@"
fi
while :; do
    /opt/acme/acme.sh --cron --home /data || true
    sleep 21600
done
