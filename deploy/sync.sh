#!/bin/sh
# Catch existing certificates up on the hosts that need them.
#
# Runs in the container after every renewal round. Instead of re-pushing the
# whole group on a timer, the last successful deploy per certificate and host is
# tracked in /data/deploy-state:
#
#   - host never deployed successfully  -> immediately
#   - last attempt failed               -> retry with backoff (6 h, 12 h, 24 h)
#   - certificate newer than last deploy -> immediately
#   - otherwise                         -> every DEPLOY_SYNC_AGE seconds (24 h)
#
# The last case is the drift check: a rebuilt host, a deleted certificate or a
# missed reload is caught within a day without waiting for the next renewal.
#
# Exit 1 if at least one host failed.
set -u

. "${DEPLOY_LIB:-/data/deploy/lib.sh}"

ACME_SH=${ACME_SH:-/opt/acme/acme.sh}
CERT_HOME=${CERT_HOME:-/data}
LOCK=${ACME_LOCK:-/data/.acme.lock}
AGE=${DEPLOY_SYNC_AGE:-86400}
RETRY=${DEPLOY_SYNC_RETRY:-21600}
MAX_RETRY=${DEPLOY_SYNC_MAX_RETRY:-86400}

case "$AGE" in ''|*[!0-9]*) AGE=86400 ;; esac
case "$RETRY" in ''|*[!0-9]*) RETRY=21600 ;; esac
case "$MAX_RETRY" in ''|*[!0-9]*) MAX_RETRY=86400 ;; esac

[ -d "$CERT_HOME" ] || { echo "sync: $CERT_HOME missing" >&2; exit 1; }

_list=$(mktemp) || exit 1
trap 'rm -f "$_list"' EXIT

for _d in "$CERT_HOME"/*/; do
    [ -d "$_d" ] || continue
    _n=${_d%/}
    _n=${_n##*/}
    _cert=$_n
    _ecc=""
    case "$_n" in
        *_ecc) _cert=${_n%_ecc}; _ecc=--ecc ;;
    esac
    _conf="$_d$_cert.conf"
    [ -f "$_conf" ] || continue
    printf '%s %s %s\n' "$_d" "$_cert" "$_ecc" >> "$_list"
done

# Hosts are already validated; no pathname expansion on the list.
set -f

_checked=0
_due=0
_ok=0
_fail=0

while IFS=' ' read -r _d _cert _ecc; do
    _conf="$_d$_cert.conf"
    _hook=$(fleet_conf_get "$_conf" Le_DeployHook)
    case ",$_hook," in
        *,fleet,*) ;;
        *) continue ;;
    esac

    _group=$(fleet_conf_get "$_conf" SAVED_DEPLOY_GROUP)
    _hosts=$(fleet_conf_get "$_conf" SAVED_DEPLOY_HOSTS)
    _all=$(fleet_resolve "$_group" "$_hosts") || {
        _fail=$((_fail + 1))
        echo "sync: ERROR $_cert: cannot resolve targets"
        continue
    }
    if [ -z "$_all" ]; then
        _fail=$((_fail + 1))
        echo "sync: ERROR $_cert: no target servers stored"
        continue
    fi

    _cer="$_d$_cert.cer"
    _mtime=0
    if [ -f "$_cer" ]; then
        _mtime=$(stat -c %Y "$_cer" 2>/dev/null || echo 0)
    fi
    _checked=$((_checked + 1))

    for _h in $_all; do
        if ! fleet_valid_host "$_h"; then
            _fail=$((_fail + 1))
            echo "sync: ERROR $_cert: invalid host: $_h"
            continue
        fi
        fleet_split_host "$_h"
        _host=$FH_HOST
        _port=$FH_PORT

        fleet_state_read "$_cert" "$_host" "$_port"
        _last_ok=$FS_OK
        _last_try=$FS_TRY
        _fails=$FS_FAILS
        _now=$(date +%s)

        _go=0
        if [ "$_last_try" -gt "$_last_ok" ]; then
            # Last attempt failed: back off, even if a deploy never succeeded.
            # Otherwise a permanently broken host would start over every round.
            _wait=$RETRY
            _i=1
            while [ "$_i" -lt "$_fails" ] && [ "$_wait" -lt "$MAX_RETRY" ]; do
                _wait=$((_wait * 2))
                _i=$((_i + 1))
            done
            [ "$_wait" -gt "$MAX_RETRY" ] && _wait=$MAX_RETRY
            [ $((_now - _last_try)) -ge "$_wait" ] && _go=1
        elif [ "$_last_ok" -eq 0 ]; then
            _go=1
        elif [ "$_mtime" -gt "$_last_ok" ]; then
            _go=1
        elif [ $((_now - _last_ok)) -ge "$AGE" ]; then
            _go=1
        fi
        [ "$_go" -eq 1 ] || continue

        _due=$((_due + 1))
        echo "sync: $_cert -> $_h (due)"
        _out=$(
            exec 9>"$LOCK" 2>&1
            flock 9
            DEPLOY_ONLY="$_h" "$ACME_SH" --home "$CERT_HOME" \
                --deploy --domain "$_cert" --deploy-hook "$_hook" $_ecc
        )
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            _ok=$((_ok + 1))
        else
            _fail=$((_fail + 1))
            echo "sync: FAILED $_cert -> $_h (rc=$_rc)"
            printf '%s\n' "$_out" | tail -n 5 | sed 's/^/    /'
        fi
    done
done < "$_list"

echo "sync: $_checked certificates, $_due due, $_ok ok, $_fail failed"
[ "$_fail" -eq 0 ] || exit 1
exit 0
