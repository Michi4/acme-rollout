#!/bin/sh
# Loaded by scripts/issue.sh and scripts/deploy.sh.
#
# check_host_keys "<host list>"    every host needs a pinned host key
# check_cname <name> <fulldomain>  _acme-challenge.<name> must point at the
#                                  acme-dns slot
#
# SKIP_PREFLIGHT=1 skips both checks.

check_host_keys() {
    if [ "${SKIP_PREFLIGHT:-0}" = 1 ]; then
        return 0
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "WARN: ssh-keygen missing, skipping host key check" >&2
        return 0
    fi
    if [ ! -f config/known_hosts ]; then
        echo "config/known_hosts missing: run ./scripts/known-hosts.sh" >&2
        return 1
    fi
    _hk_missing=""
    for _hk_h in $1; do
        case "$_hk_h" in
            *:*) _hk_lookup="[${_hk_h%:*}]:${_hk_h##*:}" ;;
            *)   _hk_lookup=$_hk_h ;;
        esac
        if ! ssh-keygen -F "$_hk_lookup" -f config/known_hosts >/dev/null 2>&1; then
            _hk_missing="$_hk_missing $_hk_h"
        fi
    done
    if [ -n "$_hk_missing" ]; then
        echo "Host key missing for:$_hk_missing" >&2
        echo "Run ./scripts/known-hosts.sh first." >&2
        return 1
    fi
    return 0
}

check_cname() {
    _cn_name=$1
    _cn_want=$2
    if [ "${SKIP_PREFLIGHT:-0}" = 1 ]; then
        return 0
    fi
    if ! command -v dig >/dev/null 2>&1; then
        echo "WARN: dig missing, skipping CNAME check" >&2
        return 0
    fi
    _cn_got=$(dig +short CNAME "_acme-challenge.$_cn_name" 2>/dev/null | head -n 1)
    if [ -z "$_cn_got" ]; then
        _cn_got=$(dig +short "_acme-challenge.$_cn_name" 2>/dev/null | head -n 1)
    fi
    _cn_got=$(printf '%s' "$_cn_got" | sed 's/\.$//' | tr 'A-Z' 'a-z')
    _cn_want=$(printf '%s' "$_cn_want" | sed 's/\.$//' | tr 'A-Z' 'a-z')
    if [ "$_cn_got" != "$_cn_want" ]; then
        echo "CNAME _acme-challenge.$_cn_name points to '${_cn_got:-nothing}', expected '$_cn_want'." >&2
        echo "Check the DNS record or set SKIP_PREFLIGHT=1." >&2
        return 1
    fi
    return 0
}
