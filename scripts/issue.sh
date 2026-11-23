#!/bin/sh
# Ein Zertifikat ausstellen und auf die gewuenschten Server legen.
#
#   ./scripts/issue.sh '*.example.com' web
#   ./scripts/issue.sh '*.example.org' edge
#   ./scripts/issue.sh example.net web1.example.com
#   ./scripts/issue.sh example.net web1.example.com,web2.example.com
#   ./scripts/issue.sh --staging '*.example.com' web
#
# Zweites Argument: Gruppe aus config/groups/<name>.txt, "all" (alle Gruppen)
# oder eine Komma-Liste von Hosts. DNS-01 laeuft ueber acme-dns (ACMEDNS_BASE_URL);
# beim ersten Mal wird die Domain registriert und der CNAME ausgegeben.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/target.sh

[ -f .env ] || { echo ".env fehlt: cp .env.example .env" >&2; exit 1; }

staging=0
if [ "${1:-}" = "--staging" ]; then
    staging=1
    shift
fi
[ $# -eq 2 ] || { echo "Aufruf: $0 [--staging] <domain> <gruppe|host[,host...]|all>" >&2; exit 1; }

domain=$1
target=$2
name=${domain#\*.}
case "$name" in
    ''|.*|*..*|*.|*[!a-z0-9.-]*) echo "domain ungueltig: $domain" >&2; exit 1 ;;
esac
resolve_target "$target"

creds=config/acme-dns/$name.env
if [ ! -f "$creds" ]; then
    ./scripts/acme-dns-register.sh "$name"
    echo
    echo "CNAME anlegen, dann erneut: $0 '$domain' '$target'" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1090
. "$creds"
set +a

# Fehlt Username/Passwort, legt das Plugin selbst ein neues Konto an und wartet
# auf Enter; ein leerer Subdomain laesst nur das Update scheitern. Beides soll
# hier klar abbrechen. FULLDOMAIN wird fuer die CNAME-Ausgabe gebraucht.
for v in ACMEDNS_USERNAME ACMEDNS_PASSWORD ACMEDNS_SUBDOMAIN ACMEDNS_FULLDOMAIN; do
    eval "value=\${$v:-}"
    [ -n "$value" ] || {
        echo "$creds: $v fehlt oder ist leer" >&2
        echo "Datei loeschen und ./scripts/acme-dns-register.sh $name erneut ausfuehren" >&2
        exit 1
    }
done
unset v value

if [ "$staging" = 1 ]; then
    server=letsencrypt_test
    acme_home=/data/staging
else
    server=letsencrypt
    acme_home=/data
fi

echo "== $domain -> $hosts"
echo "   DNS: _acme-challenge.$name CNAME $ACMEDNS_FULLDOMAIN"

set -- --issue --dns dns_acmedns --domain "$domain" --keylength 2048 --server "$server"
case "$domain" in
    \*.*) set -- "$@" --domain "$name" ;;
esac

rc=0
docker compose run --rm -e ACME_HOME="$acme_home" \
    -e "ACMEDNS_USERNAME=$ACMEDNS_USERNAME" \
    -e "ACMEDNS_PASSWORD=$ACMEDNS_PASSWORD" \
    -e "ACMEDNS_SUBDOMAIN=$ACMEDNS_SUBDOMAIN" \
    acme "$@" || rc=$?
case "$rc" in
    0|2) ;;
    *) echo "issue fehlgeschlagen (rc=$rc)" >&2; exit "$rc" ;;
esac

if [ "$staging" = 1 ]; then
    echo "   staging: kein Deploy."
    exit 0
fi

docker compose run --rm -e ACME_HOME=/data \
    -e DEPLOY_GROUP="$group" \
    -e DEPLOY_HOSTS="$hosts" \
    acme --deploy --domain "$domain" --deploy-hook fleet
