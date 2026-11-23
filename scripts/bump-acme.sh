#!/bin/sh
# acme.sh im Dockerfile auf die neueste Version ziehen.
#
# Laedt die neueste Release von GitHub, berechnet beide SHA256-Summen und
# schreibt Version, Summen und das Image-Tag neu. Danach:
#
#   docker compose up -d --build
set -eu
cd "$(dirname "$0")/.."

api=https://api.github.com/repos/acmesh-official/acme.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tag=$(curl -fsSL -m 20 "$api/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)
[ -n "$tag" ] || { echo "neueste acme.sh-Version nicht ermittelbar" >&2; exit 1; }

base="https://raw.githubusercontent.com/acmesh-official/acme.sh/$tag"
curl -fsSL -m 30 "$base/acme.sh" -o "$work/acme.sh"
curl -fsSL -m 30 "$base/dnsapi/dns_acmedns.sh" -o "$work/dns_acmedns.sh"

head -c 2 "$work/acme.sh" | grep -q '#!' \
    || { echo "acme.sh: Download sieht nicht wie ein Skript aus" >&2; exit 1; }
head -c 2 "$work/dns_acmedns.sh" | grep -q '#!' \
    || { echo "dns_acmedns.sh: Download sieht nicht wie ein Skript aus" >&2; exit 1; }

sha_acme=$(sha256sum "$work/acme.sh" | awk '{print $1}')
sha_dns=$(sha256sum "$work/dns_acmedns.sh" | awk '{print $1}')

sed -i \
    -e "s|^ARG ACME_VERSION=.*|ARG ACME_VERSION=$tag|" \
    -e "s|^ARG ACME_SHA256=.*|ARG ACME_SHA256=$sha_acme|" \
    -e "s|^ARG DNS_ACMEDNS_SHA256=.*|ARG DNS_ACMEDNS_SHA256=$sha_dns|" \
    Dockerfile
sed -i "s|^    image: acme-rollout:.*|    image: acme-rollout:$tag|" docker-compose.yml

echo "acme.sh $tag"
echo "  acme.sh        $sha_acme"
echo "  dns_acmedns.sh $sha_dns"
echo
echo "Jetzt: docker compose up -d --build"
