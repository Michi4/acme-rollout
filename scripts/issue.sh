#!/bin/sh
# Issue a certificate and place it on the requested servers.
#
#   ./scripts/issue.sh '*.example.com' web
#   ./scripts/issue.sh '*.example.org' edge
#   ./scripts/issue.sh example.net web1.example.com
#   ./scripts/issue.sh example.net web1.example.com,web2.example.com
#   ./scripts/issue.sh --staging '*.example.com' web
#   ./scripts/issue.sh --force example.net web
#   ./scripts/issue.sh --force --keylength ec-256 example.net web
#
# Second argument: a group from config/groups/<name>.txt, "all" (every group)
# or a comma-separated list of hosts. DNS-01 runs through acme-dns
# (ACMEDNS_BASE_URL); on the first run the domain is registered and the CNAME
# is printed.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/target.sh
. ./scripts/preflight.sh

usage() {
    echo "Usage: $0 [--staging] [--force] [--keylength <2048|3072|4096|ec-256|ec-384|ec-521>] <domain> <group|host[,host...]|all>" >&2
}

[ -f .env ] || { echo ".env missing: cp .env.example .env" >&2; exit 1; }

staging=0
force=0
keylength=2048
while [ $# -gt 0 ]; do
    case "$1" in
        --staging)
            staging=1
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        --keylength)
            [ $# -ge 2 ] || { usage; exit 1; }
            keylength=$2
            shift 2
            ;;
        --keylength=*)
            keylength=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done
[ $# -eq 2 ] || { usage; exit 1; }
case "$keylength" in
    2048|3072|4096|ec-256|ec-384|ec-521) ;;
    *) echo "invalid keylength: $keylength" >&2; exit 1 ;;
esac

domain=$1
target=$2
name=${domain#\*.}
case "$name" in
    ''|.*|*..*|*.|*[!a-z0-9.-]*) echo "invalid domain: $domain" >&2; exit 1 ;;
esac
resolve_target "$target"

creds=config/acme-dns/$name.env

_conf_get() {
    ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

# Read a value from .env without loading the file into this shell.
_env_get() {
    [ -f .env ] || return 0
    sed -n "s/^$1=//p" .env | tail -n 1 |
        sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

use_user=""
use_pass=""
use_sub=""
use_full=""

if [ -f "$creds" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$creds"
    set +a
    use_user=${ACMEDNS_USERNAME:-}
    use_pass=${ACMEDNS_PASSWORD:-}
    use_sub=${ACMEDNS_SUBDOMAIN:-}
    use_full=${ACMEDNS_FULLDOMAIN:-}
fi

# If the env file is missing (or broken), the credentials are still in the
# domain config of the issued certificate. Continue with those instead of
# creating a new acme-dns account and CNAME.
saved_conf="acme/$domain/$domain.conf"
if [ -z "$use_user" ] || [ -z "$use_pass" ] || [ -z "$use_sub" ] || [ -z "$use_full" ]; then
    if [ -f "$saved_conf" ]; then
        [ -n "$use_user" ] || use_user=$(_conf_get "$saved_conf" ACMEDNS_USERNAME)
        [ -n "$use_pass" ] || use_pass=$(_conf_get "$saved_conf" ACMEDNS_PASSWORD)
        [ -n "$use_sub" ] || use_sub=$(_conf_get "$saved_conf" ACMEDNS_SUBDOMAIN)
        [ -n "$use_full" ] || use_full=$(_conf_get "$saved_conf" ACMEDNS_FULLDOMAIN)
    fi
fi

# ACMEDNS_FULLDOMAIN is only needed for the CNAME check; the plugin
# authenticates with username, password and subdomain. Older domain configs
# have no FULLDOMAIN, so build it from the subdomain and the acme-dns host.
if [ -z "$use_full" ] && [ -n "$use_sub" ]; then
    _base=""
    if [ -f "$saved_conf" ]; then
        _base=$(_conf_get "$saved_conf" ACMEDNS_BASE_URL)
    fi
    [ -n "$_base" ] || _base=$(_env_get ACMEDNS_BASE_URL)
    [ -n "$_base" ] || _base=https://auth.example.com
    _base_host=$(printf '%s' "$_base" |
        sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|/.*$||' -e 's|:.*$||')
    if [ -n "$_base_host" ]; then
        use_full="$use_sub.$_base_host"
    fi
fi

if [ -z "$use_user" ] || [ -z "$use_pass" ] || [ -z "$use_sub" ]; then
    # Register only when there is neither an env file nor an issued
    # certificate. Otherwise a new slot and CNAME would be created.
    if [ ! -f "$creds" ] && [ ! -f "$saved_conf" ]; then
        ./scripts/acme-dns-register.sh "$name"
        echo
        echo "Create the CNAME, then run again: $0 '$domain' '$target'" >&2
        exit 1
    fi
    echo "$creds: ACMEDNS_USERNAME, ACMEDNS_PASSWORD or ACMEDNS_SUBDOMAIN missing or empty" >&2
    echo "Delete the file and run ./scripts/acme-dns-register.sh $name again" >&2
    echo "(or check the values in $saved_conf)" >&2
    exit 1
fi

# Before issuing: does the CNAME already point at the slot, and does every host
# have a pinned host key? Otherwise this only shows up after a long validation
# or after a successful issuance.
if [ -n "$use_full" ]; then
    check_cname "$name" "$use_full"
else
    echo "WARN: ACMEDNS_FULLDOMAIN unknown, skipping CNAME check" >&2
fi
check_host_keys "$hosts"

if [ "$staging" = 1 ]; then
    server=letsencrypt_test
    acme_home=/data/staging
else
    server=letsencrypt
    acme_home=/data
fi

echo "== $domain -> $hosts"
echo "   DNS: _acme-challenge.$name CNAME ${use_full:-unknown}"

set -- --issue --dns dns_acmedns --domain "$domain" --keylength "$keylength" --server "$server"
case "$domain" in
    \*.*) set -- "$@" --domain "$name" ;;
esac
if [ "$force" = 1 ]; then
    set -- "$@" --force
fi

rc=0
docker compose run --rm -e ACME_HOME="$acme_home" \
    -e "ACMEDNS_USERNAME=$use_user" \
    -e "ACMEDNS_PASSWORD=$use_pass" \
    -e "ACMEDNS_SUBDOMAIN=$use_sub" \
    acme --locked "$@" || rc=$?
case "$rc" in
    0|2) ;;
    *) echo "issue failed (rc=$rc)" >&2; exit "$rc" ;;
esac

if [ "$staging" = 1 ]; then
    echo "   staging: no deploy."
    exit 0
fi

deploy_ecc=""
case "$keylength" in
    ec-*) deploy_ecc=--ecc ;;
esac

docker compose run --rm -e ACME_HOME=/data \
    -e DEPLOY_GROUP="$group" \
    -e DEPLOY_HOSTS="$hosts" \
    acme --locked --deploy --domain "$domain" --deploy-hook fleet $deploy_ecc
