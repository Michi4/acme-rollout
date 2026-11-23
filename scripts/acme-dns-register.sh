#!/bin/sh
# Domain bei acme-dns registrieren.
#
#   ./scripts/acme-dns-register.sh example.com
#
# Legt config/acme-dns/<domain>.env an (0600) und gibt den CNAME aus, der
# im oeffentlichen DNS angelegt werden muss:
#
#   _acme-challenge.example.com. CNAME <id>.auth.example.com.
#
# Danach issue.sh erneut ausfuehren.
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "Aufruf: $0 <domain>" >&2; exit 1; }
domain=${1#\*.}
case "$domain" in
    ''|.*|*..*|*.|*[!a-z0-9.-]*) echo "domain ungueltig: $1" >&2; exit 1 ;;
esac

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi
base=${ACMEDNS_BASE_URL:-https://auth.example.com}
dir=config/acme-dns
file=$dir/$domain.env

if [ -f "$file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a
    echo "vorhanden: $file"
    printf '%s\n' "_acme-challenge.$domain. CNAME $ACMEDNS_FULLDOMAIN."
    exit 0
fi

resp=$(curl -fsS -m 15 -X POST "$base/register") \
    || { echo "acme-dns nicht erreichbar: $base" >&2; exit 1; }
flat=$(printf '%s' "$resp" | tr -d '\n')
field() { printf '%s' "$flat" | sed -n "s/.*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }

user=$(field username)
pass=$(field password)
sub=$(field subdomain)
full=$(field fulldomain)
for v in "$user" "$pass" "$sub" "$full"; do
    case "$v" in
        ''|*[!A-Za-z0-9._+/=-]*) echo "acme-dns Antwort unerwartet: $flat" >&2; exit 1 ;;
    esac
done

umask 077
mkdir -p "$dir"
cat > "$file" <<EOF
# acme-dns fuer $domain - erzeugt von acme-dns-register.sh
ACMEDNS_USERNAME=$user
ACMEDNS_PASSWORD=$pass
ACMEDNS_SUBDOMAIN=$sub
ACMEDNS_FULLDOMAIN=$full
EOF
chmod 600 "$file"

echo "registriert: $file"
echo
echo "CNAME jetzt im DNS anlegen:"
printf '  _acme-challenge.%s.  CNAME  %s.\n' "$domain" "$full"
echo
echo "Danach issue.sh erneut ausfuehren."
