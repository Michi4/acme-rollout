#!/bin/sh
# Run acme.sh with arguments, or without arguments the renewal cycle.
#
# One cycle:
#   1. renew each domain individually (--renew) so a failure names the domain
#   2. deploy/sync.sh: catch up hosts that are missing or stale
#   3. check certificates that expire in less than 21 days
#   4. mail problems (the same report at most once a day)
#
# "acme --locked ..." takes the lock first, so a manual docker compose run
# cannot collide with the cycle.
set -u

ACME_SH=${ACME_SH:-/opt/acme/acme.sh}
# acme.sh resolves its installer/helper files relative to the working
# directory. Always start from the acme.sh home, never from / or /data.
cd "$(dirname "$ACME_SH")" || exit 1
HOME_DIR=${ACME_HOME:-/data}
LOCK=${ACME_LOCK:-/data/.acme.lock}
DEPLOY_DIR=${ACME_DEPLOY_DIR:-/data/deploy}
INTERVAL=${ACME_INTERVAL:-21600}
CYCLES=${ACME_CYCLES:-0}
ALERT_EVERY=${ALERT_EVERY:-86400}
EXPIRY_WARN_DAYS=${EXPIRY_WARN_DAYS:-21}

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=21600 ;; esac
case "$CYCLES" in ''|*[!0-9]*) CYCLES=0 ;; esac
case "$ALERT_EVERY" in ''|*[!0-9]*) ALERT_EVERY=86400 ;; esac
case "$EXPIRY_WARN_DAYS" in ''|*[!0-9]*) EXPIRY_WARN_DAYS=21 ;; esac

# PID 1 must react to docker stop; sleep in the main loop is interruptible.
trap 'exit 0' TERM INT
mkdir -p "$HOME_DIR" 2>/dev/null || true
date +%s > "$HOME_DIR/.started" 2>/dev/null || true

if [ "$#" -gt 0 ]; then
    if [ "$1" = "--locked" ]; then
        shift
        exec flock "$LOCK" "$ACME_SH" --home "$HOME_DIR" "$@"
    fi
    exec "$ACME_SH" --home "$HOME_DIR" "$@"
fi

_conf_get() {
    ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

# Directory, certificate name and --ecc, one line per certificate.
_cert_list() {
    for _d in "$HOME_DIR"/*/; do
        [ -d "$_d" ] || continue
        _n=${_d%/}
        _n=${_n##*/}
        _c=$_n
        _ecc=""
        case "$_n" in
            *_ecc) _c=${_n%_ecc}; _ecc=--ecc ;;
        esac
        [ -f "$_d$_c.conf" ] || continue
        printf '%s %s %s\n' "$_d" "$_c" "$_ecc"
    done
}

_cycle() {
    _report=""
    _problems=0

    _list=$(mktemp) || return 1
    _cert_list > "$_list"

    while IFS=' ' read -r _d _c _ecc; do
        if [ -z "$(_conf_get "$_d$_c.conf" Le_CertCreateTime)" ]; then
            echo "skip: $_c without Le_CertCreateTime"
            continue
        fi
        _out=$(
            exec 9>"$LOCK" 2>&1
            flock 9
            "$ACME_SH" --home "$HOME_DIR" --renew --domain "$_c" $_ecc
        )
        _rc=$?
        printf '%s\n' "$_out"
        case "$_rc" in
            0|2) ;;
            *)
                _problems=1
                _report="${_report}Renewal failed: $_c (rc=$_rc)
$(printf '%s' "$_out" | tail -n 5)
"
                ;;
        esac
    done < "$_list"

    while IFS=' ' read -r _d _c _ecc; do
        _cer="$_d$_c.cer"
        if [ ! -f "$_cer" ]; then
            _problems=1
            _report="${_report}Certificate missing: $_c ($_cer)
"
        elif ! openssl x509 -checkend "$((EXPIRY_WARN_DAYS * 86400))" -noout -in "$_cer" >/dev/null 2>&1; then
            _end=$(openssl x509 -enddate -noout -in "$_cer" 2>/dev/null | sed 's/^notAfter=//')
            _problems=1
            _report="${_report}Certificate $_c expires in less than $EXPIRY_WARN_DAYS days or is unreadable (until ${_end:-unknown})
"
        fi
    done < "$_list"
    rm -f "$_list"

    if [ -x "$DEPLOY_DIR/sync.sh" ]; then
        _sync=$(mktemp) || _sync=""
        if [ -n "$_sync" ]; then
            "$DEPLOY_DIR/sync.sh" > "$_sync" 2>&1
            _src=$?
            cat "$_sync"
            if [ "$_src" -ne 0 ]; then
                _problems=1
                _report="${_report}Deploy sync failed:
$(tail -n 15 "$_sync")
"
            fi
            rm -f "$_sync"
        fi
    fi

    if [ "$_problems" -eq 0 ]; then
        rm -rf "$HOME_DIR/.alert"
        return 0
    fi

    mkdir -p "$HOME_DIR/.alert"
    _now=$(date +%s)
    _sig=$(printf '%s' "$_report" | md5sum | awk '{print $1}')
    _last=0
    if [ -f "$HOME_DIR/.alert/last" ]; then
        _last=$(cat "$HOME_DIR/.alert/last" 2>/dev/null || echo 0)
    fi
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac

    if [ -f "$HOME_DIR/.alert/sig" ] &&
        [ "$(cat "$HOME_DIR/.alert/sig" 2>/dev/null || true)" = "$_sig" ] &&
        [ $((_now - _last)) -lt "$ALERT_EVERY" ]; then
        echo "alert: same report, last sent $_last - no new mail"
        return 0
    fi

    if printf '%s' "$_report" | "$DEPLOY_DIR/notify.sh" "[acme-rollout] problem on $(hostname)"; then
        printf '%s\n' "$_sig" > "$HOME_DIR/.alert/sig"
        printf '%s\n' "$_now" > "$HOME_DIR/.alert/last"
    fi
    return 0
}

_i=0
while :; do
    _cycle
    date +%s > "$HOME_DIR/.last-cycle" 2>/dev/null || true
    _i=$((_i + 1))
    if [ "$CYCLES" -gt 0 ] && [ "$_i" -ge "$CYCLES" ]; then
        break
    fi
    sleep "$INTERVAL" &
    wait $!
done
