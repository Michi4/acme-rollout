#!/bin/sh
# Bereits ausgestelltes Zertifikat erneut auf Server legen.
#
#   ./scripts/deploy.sh '*.example.com' web
#   ./scripts/deploy.sh example.net web1.example.com
set -eu
cd "$(dirname "$0")/.."
. ./scripts/target.sh

[ -f .env ] || { echo ".env fehlt: cp .env.example .env" >&2; exit 1; }
[ $# -eq 2 ] || { echo "Aufruf: $0 <domain> <gruppe|host[,host...]|all>" >&2; exit 1; }

domain=$1
resolve_target "$2"

docker compose run --rm -e ACME_HOME=/data \
    -e DEPLOY_GROUP="$group" \
    -e DEPLOY_HOSTS="$hosts" \
    acme --deploy --domain "$domain" --deploy-hook fleet
