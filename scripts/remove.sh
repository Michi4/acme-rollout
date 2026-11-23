#!/bin/sh
# Zertifikat aus der Erneuerung nehmen, optional widerrufen.
#
#   ./scripts/remove.sh '*.example.com'
#   ./scripts/remove.sh example.net --revoke
#
# Ohne --revoke bleiben Zertifikat und Key unter acme/<domain>/ liegen, werden
# aber nicht mehr erneuert. --revoke widerruft das Zertifikat vorher bei der CA.
# Dateien auf den Zielhosts und der CNAME im oeffentlichen DNS bleiben
# unangetastet; beides muss bei Bedarf von Hand entfernt werden.
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo ".env fehlt: cp .env.example .env" >&2; exit 1; }
[ $# -ge 1 ] || { echo "Aufruf: $0 <domain> [--revoke]" >&2; exit 1; }

domain=$1
shift
revoke=0
for arg in "$@"; do
    case "$arg" in
        --revoke) revoke=1 ;;
        *) echo "unbekannte Option: $arg" >&2; exit 1 ;;
    esac
done

name=${domain#\*.}
case "$name" in
    ''|.*|*..*|*.|*[!a-z0-9.-]*) echo "domain ungueltig: $domain" >&2; exit 1 ;;
esac

ecc=""
if [ -d "acme/${domain}_ecc" ]; then
    ecc="--ecc"
fi

rc=0
if [ "$revoke" = 1 ]; then
    if ! docker compose run --rm acme --locked --revoke --domain "$domain" $ecc; then
        echo "WARN: Widerruf fehlgeschlagen, Erneuerung wird trotzdem gestoppt" >&2
        rc=1
    fi
fi
docker compose run --rm acme --locked --remove --domain "$domain" $ecc

slug=$name
case "$domain" in
    \*.*) slug="wildcard.$name" ;;
esac
rm -rf "acme/deploy-state/$slug"

if [ "$revoke" = 1 ] && [ "$rc" -eq 0 ]; then
    echo "entfernt und widerrufen: $domain"
elif [ "$revoke" = 1 ]; then
    echo "entfernt: $domain (Widerruf fehlgeschlagen, Zertifikat gilt bis zum Ablauf)"
else
    echo "entfernt: $domain (Zertifikat bleibt liegen, wird nicht mehr erneuert)"
fi
exit "$rc"
