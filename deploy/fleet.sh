#!/bin/sh
# acme.sh Deploy-Hook "fleet".
#
# Wird von acme.sh bei der Ausstellung und bei jeder Erneuerung aufgerufen.
# Zielserver kommen aus DEPLOY_GROUP (Gruppe) oder DEPLOY_HOSTS (Liste).
# Eine gesetzte Umgebungsvariable gewinnt - auch leer; sonst gilt der in der
# Domain-Config gespeicherte Wert. Eine Gruppe wird bei jeder Erneuerung neu
# gelesen, neue Server in der Gruppe bekommen das Zertifikat also automatisch.
#
#   DEPLOY_GROUP  Gruppe aus /config/groups/<name>.txt (oder "all")
#   DEPLOY_HOSTS  "host1 host2 host3:2222"
#   DEPLOY_USER   Standard acmepush
#   DEPLOY_NAME   Zielname unter /etc/ssl (Standard: wildcard.<domain> bzw. <domain>)
fleet_deploy() {
    _cd="$1"
    _ckey="$2"
    _ccert="$3"
    _cca="$4"
    _cfull="$5"

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
    if [ -z "$_name" ]; then
        case "$_cd" in
            \*.*) _name="wildcard.${_cd#\*.}" ;;
            *)    _name="$_cd" ;;
        esac
    fi
    case "$_name" in
        ''|.*|*..*|*.|*[!a-z0-9.-]*)
            echo "fehler: DEPLOY_NAME ungueltig: $_name"
            return 1
            ;;
    esac
    case "$_user" in
        ''|*[!a-z0-9_-]*|[!a-z_]*)
            echo "fehler: DEPLOY_USER ungueltig: $_user"
            return 1
            ;;
    esac

    _gdir="${DEPLOY_GROUPS_DIR:-/config/groups}"
    if [ -n "$_group" ]; then
        if [ "$_group" = all ]; then
            set -- "$_gdir"/*.txt
            if [ ! -e "$1" ]; then
                echo "fehler: keine Gruppen in $_gdir"
                return 1
            fi
        else
            case "$_group" in
                *[!a-z0-9_-]*)
                    echo "fehler: DEPLOY_GROUP ungueltig: $_group"
                    return 1
                    ;;
            esac
            set -- "$_gdir/$_group.txt"
            if [ ! -f "$1" ]; then
                echo "fehler: Gruppe $_group fehlt ($1)"
                return 1
            fi
        fi
        _hosts=$(awk 'NF && $1 !~ /^#/ { print $1 }' "$@" | awk '!seen[$0]++' | tr '\n' ' ')
    fi
    _hosts=$(printf '%s' "$_hosts" | tr ',' ' ')

    if [ -z "$_hosts" ]; then
        echo "fehler: keine Zielserver (DEPLOY_GROUP/DEPLOY_HOSTS)"
        return 1
    fi

    _savedeployconf DEPLOY_GROUP "$_group"
    _savedeployconf DEPLOY_HOSTS "$_hosts"
    _savedeployconf DEPLOY_USER "$_user"
    _savedeployconf DEPLOY_NAME "$_name"

    _key="${DEPLOY_KEY:-/keys/acme_ed25519}"
    _known="${DEPLOY_KNOWN_HOSTS:-/config/known_hosts}"
    [ -f "$_key" ] || { echo "fehler: $_key fehlt"; return 1; }
    [ -f "$_known" ] || { echo "fehler: $_known fehlt (./scripts/known-hosts.sh)"; return 1; }

    _tmp=$(mktemp -d) || return 1
    _fleet_cleanup() { rm -rf "$_tmp"; }
    install -m 0600 "$_cfull" "$_tmp/cert.pem" || { _fleet_cleanup; return 1; }
    install -m 0600 "$_cca" "$_tmp/chain.pem" || { _fleet_cleanup; return 1; }
    install -m 0600 "$_ckey" "$_tmp/privkey.pem" || { _fleet_cleanup; return 1; }

    _rc=0
    for _h in $_hosts; do
        case "$_h" in
            -*|*[!A-Za-z0-9.:-]*)
                echo "fehler: host ungueltig: $_h"
                _rc=1
                continue
                ;;
        esac
        case "$_h" in
            *:*) _host="${_h%:*}"; _port="${_h##*:}" ;;
            *)   _host="$_h"; _port=22 ;;
        esac
        case "$_port" in
            ''|*[!0-9]*)
                echo "fehler: port ungueltig: $_h"
                _rc=1
                continue
                ;;
        esac

        echo "deploy: $_name -> ${_user}@${_host}:${_port}"
        if tar -C "$_tmp" -czf - . | ssh \
                -i "$_key" -p "$_port" \
                -o BatchMode=yes \
                -o IdentitiesOnly=yes \
                -o StrictHostKeyChecking=yes \
                -o UserKnownHostsFile="$_known" \
                -o ConnectTimeout=10 \
                "${_user}@${_host}" "install $_name"; then
            :
        else
            echo "fehler: $_host hat das Zertifikat nicht angenommen"
            _rc=1
        fi
    done
    _fleet_cleanup
    return "$_rc"
}
