#!/bin/sh
# acme.sh deploy hook "fleet".
#
# Called by acme.sh on issuance and on every renewal. Target servers come from
# DEPLOY_GROUP (group) or DEPLOY_HOSTS (list). A variable set in the
# environment wins - even when empty; otherwise the value stored in the domain
# config is used. A group is re-read on every call, so new servers in the group
# are picked up without touching the certificate.
#
#   DEPLOY_GROUP     group from /config/groups/<name>.txt (or "all")
#   DEPLOY_HOSTS     "host1 host2 host3:2222"
#   DEPLOY_ONLY      only these hosts from the target group (used by the sync)
#   DEPLOY_USER      default acmepush
#   DEPLOY_NAME      target name under /etc/ssl (default wildcard.<domain> or <domain>)
#   DEPLOY_PATH      target directory, default /etc/ssl (see README)
#   DEPLOY_PARALLEL  concurrent connections, default 4
#
# The last successful deploy per host is stored in /data/deploy-state, so the
# sync can push exactly the hosts that are missing or stale.
fleet_deploy() {
    _cd="$1"
    _ckey="$2"
    _ccert="$3"
    _cca="$4"
    _cfull="$5"

    . "${DEPLOY_LIB:-/data/deploy/lib.sh}"

    # Stored values live as SAVED_* in the domain config. acme.sh's own
    # _getdeployconf is not used here: it assigns the variable and prints
    # nothing (so $(...) would be empty), and its unquoted eval breaks on a
    # host list with spaces. Reading the config directly is exact.
    _conf=${DOMAIN_CONF:-}
    _stored() {
        [ -n "$_conf" ] || return 0
        fleet_conf_get "$_conf" "SAVED_$1"
    }

    # An environment variable wins, even when it is empty: that is how
    # issue.sh and deploy.sh override a stored group for one run.
    if [ "${DEPLOY_GROUP+x}" = x ]; then
        _group=$DEPLOY_GROUP
    else
        _group=$(_stored DEPLOY_GROUP)
    fi
    if [ "${DEPLOY_HOSTS+x}" = x ]; then
        _hosts=$DEPLOY_HOSTS
    else
        _hosts=$(_stored DEPLOY_HOSTS)
    fi

    _user="${DEPLOY_USER:-$(_stored DEPLOY_USER)}"
    _user="${_user:-acmepush}"
    _name="${DEPLOY_NAME:-$(_stored DEPLOY_NAME)}"
    _path="${DEPLOY_PATH:-$(_stored DEPLOY_PATH)}"
    _only="${DEPLOY_ONLY:-}"

    if [ -z "$_name" ]; then
        case "$_cd" in
            \*.*) _name="wildcard.${_cd#\*.}" ;;
            *)    _name="$_cd" ;;
        esac
    fi
    if ! fleet_valid_name "$_name"; then
        echo "error: DEPLOY_NAME invalid: $_name"
        return 1
    fi
    case "$_user" in
        ''|*[!a-z0-9_-]*|[!a-z_]*)
            echo "error: DEPLOY_USER invalid: $_user"
            return 1
            ;;
    esac
    if [ -n "$_path" ]; then
        case "$_path" in
            /*) ;;
            *)
                echo "error: DEPLOY_PATH must be absolute: $_path"
                return 1
                ;;
        esac
        case "$_path" in
            *[!A-Za-z0-9/._-]*)
                echo "error: DEPLOY_PATH invalid: $_path"
                return 1
                ;;
        esac
        _path=${_path%/}
    fi

    _all=$(fleet_resolve "$_group" "$_hosts") || _all=""
    if [ -z "$_all" ] && [ -n "$_only" ]; then
        # The sync already resolved this host from the same stored config.
        # Deploying the one host it asked for is strictly better than failing
        # the round, in particular when only the group file went missing.
        echo "WARN: no targets for $_cd, deploying the requested host only"
        _all=$(printf '%s' "$_only" | tr ',' '\n' | awk 'NF && !seen[$0]++')
    fi
    if [ -z "$_all" ]; then
        echo "error: no target servers for $_cd"
        echo "    DEPLOY_GROUP='${_group}' DEPLOY_HOSTS='${_hosts}'"
        echo "    config: ${_conf:-not set (deploy outside acme.sh?)}"
        if [ -n "$_group" ]; then
            echo "    the group is resolved on every deploy; check config/groups/$_group.txt"
        else
            echo "    store one with ./scripts/issue.sh '<cert>' '<group|hosts>'"
        fi
        return 1
    fi

    # Touch only the hosts the sync asked for. The stored target group must not
    # be overwritten in the process.
    if [ -n "$_only" ]; then
        _sel=""
        for _h in $(printf '%s' "$_only" | tr ',' ' '); do
            case " $(printf '%s' "$_all" | tr '\n' ' ') " in
                *" $_h "*) _sel="$_sel $_h" ;;
                *)
                    echo "error: $_h is not in the target group of $_cd"
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
    [ -f "$_key" ] || { echo "error: $_key missing"; return 1; }
    [ -f "$_known" ] || { echo "error: $_known missing (./scripts/known-hosts.sh)"; return 1; }

    _tmp=$(mktemp -d) || return 1
            command install -m 0600 "$_cfull" "$_tmp/cert.pem" || { rm -rf "$_tmp"; return 1; }
        command install -m 0600 "$_cca" "$_tmp/chain.pem" || { rm -rf "$_tmp"; return 1; }
        command install -m 0600 "$_ckey" "$_tmp/privkey.pem" || { rm -rf "$_tmp"; return 1; }

    _par=${DEPLOY_PARALLEL:-4}
    case "$_par" in ''|*[!0-9]*|0) _par=1 ;; esac
    [ "$_par" -le 16 ] || _par=16

    # No pathname expansion on the host list.
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
                echo "error: $_h did not accept the certificate"
                if [ -f "$_tmp/.log.$_fk" ]; then
                    tail -n 3 "$_tmp/.log.$_fk" | sed 's/^/    /'
                fi
                ;;
        esac
    done
    set +f

    echo "deploy: $_name ok $_okn, failed $_badn"
    rm -rf "$_tmp"
    [ "$_badn" -eq 0 ] || return 1
    return 0
}

# One host. Runs in a subshell so several connections can run in parallel.
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
        echo "error: invalid host: $_h"
        echo failed > "$_tmp/.res.$_fk"
        return 1
    fi
    case "$_port" in
        ''|*[!0-9]*)
            echo "error: invalid port: $_h"
            echo failed > "$_tmp/.res.$_fk"
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
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=4 \
            "${_user}@${_host}" "$_cmd" > "$_tmp/.log.$_fk" 2>&1
    then
        fleet_state_write "$_cd" "$_host" "$_port" "$_now" "$_now" 0
        echo "ok: $_h"
        echo ok > "$_tmp/.res.$_fk"
    else
        fleet_state_write "$_cd" "$_host" "$_port" "$_ok" "$_now" "$((_fails + 1))"
        echo failed > "$_tmp/.res.$_fk"
        return 1
    fi
}
