#!/bin/sh
# Vorhandene Zertifikate auf die Hosts nachziehen, die es brauchen.
#
# Laeuft im Container nach jeder Erneuerungsrunde. Statt die ganze Gruppe
# regelmaessig neu zu bespielen, wird pro Zertifikat und Host der letzte
# erfolgreiche Deploy in /data/deploy-state gefuehrt:
#
#   - Host noch nie erfolgreich beliefert -> sofort
#   - letzter Versuch fehlgeschlagen      -> Retry mit Backoff (6 h, 12 h, 24 h)
#   - Zertifikat neuer als der letzte Deploy -> sofort
#   - sonst                                -> alle DEPLOY_SYNC_AGE Sekunden (24 h)
#
# Der letzte Fall ist die Drift-Pruefung: ein neu gebauter Host, ein
# geloeschtes Zertifikat oder ein verpasster Reload wird so innerhalb eines
# Tages erkannt, ohne auf die naechste Erneuerung zu warten.
#
# Exit 1, wenn mindestens ein Host fehlgeschlagen ist.
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

[ -d "$CERT_HOME" ] || { echo "sync: $CERT_HOME fehlt" >&2; exit 1; }

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

# Hosts sind bereits validiert; keine Pfad-Expansion auf der Liste.
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
        echo "sync: FEHLER $_cert: Ziele nicht aufloesbar"
        continue
    }
    if [ -z "$_all" ]; then
        _fail=$((_fail + 1))
        echo "sync: FEHLER $_cert: keine Zielserver gespeichert"
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
            echo "sync: FEHLER $_cert: host ungueltig: $_h"
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
            # Letzter Versuch fehlgeschlagen: Backoff, auch wenn noch nie ein
            # Deploy geklappt hat. Sonst wuerde ein dauerhaft kaputter Host
            # bei jedem Zyklus neu anlaufen.
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
        echo "sync: $_cert -> $_h (faellig)"
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
            echo "sync: FEHLER $_cert -> $_h (rc=$_rc)"
            printf '%s\n' "$_out" | tail -n 5 | sed 's/^/    /'
        fi
    done
done < "$_list"

echo "sync: $_checked Zertifikate, $_due faellig, $_ok ok, $_fail fehlgeschlagen"
[ "$_fail" -eq 0 ] || exit 1
exit 0
