#!/bin/sh
# Roll an existing certificate out to servers again.
#
#   ./scripts/deploy.sh '*.example.com' web
#   ./scripts/deploy.sh example.net web1.example.com
set -eu
cd "$(dirname "$0")/.."
. ./scripts/target.sh
. ./scripts/preflight.sh

case "${1:-}" in
    -h|--help)
        echo "Usage: $0 <domain> <group|host[,host...]|all>"
        exit 0
        ;;
esac

[ -f .env ] || { echo ".env missing: cp .env.example .env" >&2; exit 1; }
[ $# -eq 2 ] || { echo "Usage: $0 <domain> <group|host[,host...]|all>" >&2; exit 1; }

domain=$1
resolve_target "$2"

ecc=""
if [ -d "acme/${domain}_ecc" ]; then
    ecc=--ecc
fi

# --deploy only works on a certificate that already exists. A registered
# acme-dns slot is not a certificate; acme.sh would only answer "is not a cert
# name". Point at the command that issues it instead.
if [ ! -f "acme/$domain/$domain.cer" ] && [ ! -f "acme/${domain}_ecc/$domain.cer" ]; then
    echo "certificate $domain is not issued yet: run ./scripts/issue.sh '$domain' '$2'" >&2
    exit 1
fi

check_cert_conflicts "$domain" "$hosts"
check_host_keys "$hosts"
check_receivers "$hosts"

# DEPLOY_NAME, DEPLOY_PATH and DEPLOY_USER from the environment (spec file or
# .env) win over the values stored in the domain config.
deploy_env=""
if [ -n "${DEPLOY_NAME:-}" ]; then
    deploy_env="$deploy_env -e DEPLOY_NAME"
fi
if [ -n "${DEPLOY_PATH:-}" ]; then
    deploy_env="$deploy_env -e DEPLOY_PATH"
fi
if [ -n "${DEPLOY_USER:-}" ]; then
    deploy_env="$deploy_env -e DEPLOY_USER"
fi

# shellcheck disable=SC2086
docker compose run --rm $deploy_env -e ACME_HOME=/data \
    -e DEPLOY_GROUP="$group" \
    -e DEPLOY_HOSTS="$hosts" \
    acme --locked --deploy --domain "$domain" --deploy-hook fleet $ecc
