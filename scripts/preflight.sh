#!/bin/sh
# Loaded by scripts/issue.sh and scripts/deploy.sh.
#
# check_host_keys "<host list>"    every host needs a pinned host key
# check_cname <name> <fulldomain>  _acme-challenge.<name> must point at the
#                                  acme-dns slot
# check_cert_conflicts <domain> "<host list>"
#                                  warn when a host already serves another
#                                  certificate (from acme/deploy-state)
#
# SKIP_PREFLIGHT=1 skips all checks.

. ./scripts/lib.sh

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

# Every target must answer through the forced command with receiver v2 before
# a certificate is issued. This catches a missing recipe, a wrong key or a
# stale authorized_keys entry before Let's Encrypt is involved.
check_receivers() {
    if [ "${SKIP_PREFLIGHT:-0}" = 1 ]; then
        return 0
    fi
    _cr_key=${DEPLOY_KEY:-keys/acme_ed25519}
    _cr_user=${DEPLOY_USER:-acmepush}
    _cr_known=${DEPLOY_KNOWN_HOSTS:-config/known_hosts}
    [ -f "$_cr_key" ] || { echo "deploy key missing: $_cr_key" >&2; return 1; }
    [ -f "$_cr_known" ] || { echo "$_cr_known missing: run ./scripts/known-hosts.sh" >&2; return 1; }

    for _cr_h in $1; do
        case "$_cr_h" in
            *:*) _cr_host=${_cr_h%:*}; _cr_port=${_cr_h##*:} ;;
            *)   _cr_host=$_cr_h; _cr_port=22 ;;
        esac
        _cr_out=$(ssh -i "$_cr_key" -p "$_cr_port" \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$_cr_known" \
            -o ConnectTimeout=8 \
            "${_cr_user}@${_cr_host}" status 2>&1) || {
            echo "receiver ${_cr_h}: $_cr_out" >&2
            return 1
        }
        case "$_cr_out" in
            *"ok=acme-target v2"*) ;;
            *)
                echo "receiver ${_cr_h}: unexpected answer: $_cr_out" >&2
                return 1
                ;;
        esac
    done
    return 0
}

# A host that already carries a different certificate in the deploy state is
# most likely not part of this certificate's site. That is exactly what a group
# file copied from another certificate looks like: the old servers would get
# the new files. Warn instead of stopping - a host may legitimately carry two
# certificates (an exact and a wildcard one, for example).
check_cert_conflicts() {
    if [ "${SKIP_PREFLIGHT:-0}" = 1 ]; then
        return 0
    fi
    _cc_domain=$1
    _cc_hosts=$2
    _cc_state=acme/deploy-state
    if [ ! -d "$_cc_state" ]; then
        return 0
    fi
    _cc_slug=$(cert_slug "$_cc_domain")

    _cc_n=0
    for _cc_h in $_cc_hosts; do
        case "$_cc_h" in
            *:*) _cc_host=${_cc_h%:*}; _cc_port=${_cc_h##*:} ;;
            *)   _cc_host=$_cc_h;      _cc_port=22 ;;
        esac
        for _cc_dir in "$_cc_state"/*/; do
            if [ ! -d "$_cc_dir" ]; then
                continue
            fi
            _cc_dir=${_cc_dir%/}
            _cc_dir=${_cc_dir##*/}
            if [ "$_cc_dir" = "$_cc_slug" ]; then
                continue
            fi
            _cc_file="$_cc_state/$_cc_dir/${_cc_host}_${_cc_port}"
            if [ ! -f "$_cc_file" ]; then
                continue
            fi
            # Only a host that was deployed successfully carries a certificate.
            _cc_ok=$(awk 'NR == 1 { print $1 + 0; exit }' "$_cc_file" 2>/dev/null) || _cc_ok=0
            case "$_cc_ok" in
                ''|0|*[!0-9]*) continue ;;
            esac
            case "$_cc_dir" in
                wildcard.*) _cc_other="*.${_cc_dir#wildcard.}" ;;
                *)          _cc_other=$_cc_dir ;;
            esac
            echo "WARN: $_cc_h already serves $_cc_other (deploy state $_cc_file)" >&2
            _cc_n=$((_cc_n + 1))
        done
    done

    if [ "$_cc_n" -gt 0 ]; then
        echo "WARN: $_cc_domain would be deployed next to those certificates." >&2
        echo "WARN: check config/groups (a copied group file?) so no host gets the wrong one." >&2
    fi
    return 0
}
