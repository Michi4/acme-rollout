#!/bin/sh
# Take a certificate out of renewal, optionally revoke it.
#
#   ./scripts/remove.sh '*.example.com'
#   ./scripts/remove.sh example.net --revoke
#
# Without --revoke the certificate and key stay under acme/<domain>/ but are no
# longer renewed. --revoke revokes the certificate with the CA first. Files on
# the target hosts and the CNAME in public DNS are left alone; remove both by
# hand if needed.
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo ".env missing: cp .env.example .env" >&2; exit 1; }
[ $# -ge 1 ] || { echo "Usage: $0 <domain> [--revoke]" >&2; exit 1; }

domain=$1
shift
revoke=0
for arg in "$@"; do
    case "$arg" in
        --revoke) revoke=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

name=${domain#\*.}
case "$name" in
    ''|.*|*..*|*.|*[!a-z0-9.-]*) echo "invalid domain: $domain" >&2; exit 1 ;;
esac

ecc=""
if [ -d "acme/${domain}_ecc" ]; then
    ecc="--ecc"
fi

rc=0
if [ "$revoke" = 1 ]; then
    if ! docker compose run --rm acme --locked --revoke --domain "$domain" $ecc; then
        echo "WARN: revocation failed, stopping renewal anyway" >&2
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
    echo "removed and revoked: $domain"
elif [ "$revoke" = 1 ]; then
    echo "removed: $domain (revocation failed, certificate is valid until expiry)"
else
    echo "removed: $domain (certificate is kept but no longer renewed)"
fi
exit "$rc"
