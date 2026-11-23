#!/bin/sh
# acme.sh Deploy-Hook "fleet".
#
# Wird von acme.sh bei der Ausstellung und bei jeder Erneuerung aufgerufen.
# Zielserver kommen aus DEPLOY_GROUP (Gruppe) oder DEPLOY_HOSTS (Liste).
# Eine gesetzte Umgebungsvariable gewinnt - auch leer; sonst gilt der in der
# Domain-Config gespeicherte Wert. Eine Gruppe wird bei jedem Aufruf neu
# gelesen, neue Server in der Gruppe werden also ohne Aenderung am Zertifikat
# mitgenommen.
#
#   DEPLOY_GROUP     Gruppe aus /config/groups/<name>.txt (oder "all")
#   DEPLOY_HOSTS     "host1 host2 host3:2222"
#   DEPLOY_ONLY      nur diese Hosts aus der Zielgruppe (fuer den Sync)
#   DEPLOY_USER      Standard acmepush
#   DEPLOY_NAME      Zielname unter /etc/ssl (Standard: wildcard.<domain> bzw. <domain>)
#   DEPLOY_PATH      Zielverzeichnis, Standard /etc/ssl (siehe README)
#   DEPLOY_PARALLEL  gleichzeitige Verbindungen, Standard 4
#
# Pro Host wird der letzte erfolgreiche Deploy in /data/deploy-state abgelegt.
# Damit kann der Sync genau die Hosts nachziehen, die fehlen oder alt sind.
fleet_deploy() {
    _cd="$1"
    _ckey="$2"
    _ccert="$3"
    _cca="$4"
    _cfull="$5"

    . "${DEPLOY_LIB:-/data/deploy/lib.sh}"

    if [ "${DEPLOY_GROUP+x}" = x ]; then
        _group=$DEPLOY_GROUP
    else
        _group=$(_getdeployconf DEPLOY_GROUP)
    fi
    if [ "${DEPLOY_HOSTS+x}" = x ]; then
        _hosts=$DEPLOY_HOSTS
    else
        _hosts=$(_getdeployconf DEPLOY_HOSTS)
    fi

    _user="${DEPLOY_USER:-$(_getdeployconf DEPLOY_USER)}"
    _user="${_user:-acmepush}"
    _name="${DEPLOY_NAME:-$(_getdeployconf DEPLOY_NAME)}"
    _path="${DEPLOY_PATH:-$(_getdeployconf DEPLOY_PATH)}"
    _only="${DEPLOY_ONLY:-}"

    if [ -z "$_name" ]; then
        case "$_cd" in
            \*.*) _name="wildcard.${_cd#\*.}" ;;
            *)    _name="$_cd" ;;
        esac
    fi
    if ! fleet_valid_name "$_name"; then
        echo "fehler: DEPLOY_NAME ungueltig: $_name"
        return 1
    fi
    case "$_user" in
        ''|*[!a-z0-9_-]*|[!a-z_]*)
            echo "fehler: DEPLOY_USER ungueltig: $_user"
            return 1
            ;;
    esac
    if [ -n "$_path" ]; then
        case "$_path" in
            /*) ;;
            *)
                echo "fehler: DEPLOY_PATH muss absolut sein: $_path"
                return 1
                ;;
        esac
        case "$_path" in
            *[!A-Za-z0-9/._-]*)
                echo "fehler: DEPLOY_PATH ungueltig: $_path"
                return 1
                ;;
        esac
        _path=${_path%/}
    fi

    _all=$(fleet_resolve "$_group" "$_hosts") || return 1
    if [ -z "$_all" ]; then
        echo "fehler: keine Zielserver (DEPLOY_GROUP/DEPLOY_HOSTS)"
        return 1
    fi

    # Nur die vom Sync angefragten Hosts anfassen. Die gespeicherte Zielgruppe
    # darf dabei nicht ueberschrieben werden.
    if [ -n "$_only" ]; then
        _sel=""
        for _h in $(printf '%s' "$_only" | tr ',' ' '); do
            case " $(printf '%s' "$_all" | tr '\n' ' ') " in
                *" $_h "*) _sel="$_sel $_h" ;;
                *)
                    echo "fehler: $_h gehoert nicht zur Zielgruppe von $_cd"
                    return 1
                    ;;
            esac
        done
        _all=${_sel# }
    fi

    if [ -z "$_only" ]; then
        _savedeployconf DEPLOY_GROUP "$_group"
        _savedeployconf DEPLOY_HOSTS "$(printf '%s' "$_all" | tr '\n' ' ' | sed 's/ $//')"
        _savedeployconf DEPLOY_USER "$_user"
        _savedeployconf DEPLOY_NAME "$_name"
        if [ -n "$_path" ]; then
            _savedeployconf DEPLOY_PATH "$_path"
        fi
    fi

    _key="${DEPLOY_KEY:-/keys/acme_ed25519}"
    _known="${DEPLOY_KNOWN_HOSTS:-/config/known_hosts}"
    [ -f "$_key" ] || { echo "fehler: $_key fehlt"; return 1; }
    [ -f "$_known" ] || { echo "fehler: $_known fehlt (./scripts/known-hosts.sh)"; return 1; }

    _tmp=$(mktemp -d) || return 1
    install -m 0600 "$_cfull" "$_tmp/cert.pem" || { rm -rf "$_tmp"; return 1; }
    install -m 0600 "$_cca" "$_tmp/chain.pem" || { rm -rf "$_tmp"; return 1; }
    install -m 0600 "$_ckey" "$_tmp/privkey.pem" || { rm -rf "$_tmp"; return 1; }

    _par=${DEPLOY_PARALLEL:-4}
    case "$_par" in ''|*[!0-9]*|0) _par=1 ;; esac
    [ "$_par" -le 16 ] || _par=16

    # Kein Pathname-Expansion auf der Hostliste.
    set -f
    _n=0
    for _h in $_all; do
        ( _fleet_one "$_h" "$_tmp" "$_cd" "$_name" "$_user" "$_path" "$_key" "$_known" ) &
        _n=$((_n + 1))
        if [ "$_n" -ge "$_par" ]; then
            wait
            _n=0
        fi
    done
    wait

    _okn=0
    _badn=0
    for _h in $_all; do
        _fk=$(printf '%s' "$_h" | tr ':' '_')
        _res=$(cat "$_tmp/.res.$_fk" 2>/dev/null || true)
        case "$_res" in
            ok)
                _okn=$((_okn + 1))
                ;;
            *)
                _badn=$((_badn + 1))
                echo "fehler: $_h hat das Zertifikat nicht angenommen"
                if [ -f "$_tmp/.log.$_fk" ]; then
                    tail -n 3 "$_tmp/.log.$_fk" | sed 's/^/    /'
                fi
                ;;
        esac
    done
    set +f

    echo "deploy: $_name ok $_okn, fehlgeschlagen $_badn"
    rm -rf "$_tmp"
    [ "$_badn" -eq 0 ] || return 1
    return 0
}

# Ein Host. Laeuft in einer Subshell, damit mehrere Verbindungen parallel gehen.
_fleet_one() {
    _h=$1
    _tmp=$2
    _cd=$3
    _name=$4
    _user=$5
    _path=$6
    _key=$7
    _known=$8

    _fk=$(printf '%s' "$_h" | tr ':' '_')
    fleet_split_host "$_h"
    _host=$FH_HOST
    _port=$FH_PORT

    if ! fleet_valid_host "$_h"; then
        echo "fehler: host ungueltig: $_h"
        echo fehler > "$_tmp/.res.$_fk"
        return 1
    fi
    case "$_port" in
        ''|*[!0-9]*)
            echo "fehler: port ungueltig: $_h"
            echo fehler > "$_tmp/.res.$_fk"
            return 1
            ;;
    esac

    _now=$(date +%s)
    fleet_state_read "$_cd" "$_host" "$_port"
    _ok=$FS_OK
    _fails=$FS_FAILS

    echo "deploy: $_name -> ${_user}@${_host}:${_port}"
    if [ -n "$_path" ]; then
        _cmd="install $_name $_path"
    else
        _cmd="install $_name"
    fi

    if tar -C "$_tmp" -czf - ./cert.pem ./chain.pem ./privkey.pem |
        ssh -i "$_key" -p "$_port" \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$_known" \
            -o ConnectTimeout=10 \
            "${_user}@${_host}" "$_cmd" > "$_tmp/.log.$_fk" 2>&1
    then
        fleet_state_write "$_cd" "$_host" "$_port" "$_now" "$_now" 0
        echo "ok: $_h"
        echo ok > "$_tmp/.res.$_fk"
    else
        fleet_state_write "$_cd" "$_host" "$_port" "$_ok" "$_now" "$((_fails + 1))"
        echo fehler > "$_tmp/.res.$_fk"
        return 1
    fi
}
