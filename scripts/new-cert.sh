#!/bin/sh
# Create or refresh a certificate from one spec file in config/certs.
#
#   ./scripts/new-cert.sh config/certs/example.com.conf
#   ./scripts/new-cert.sh --wizard
#   ./scripts/new-cert.sh --check example.com
#
# Steps, each skipped when it is already done:
#   1. validate the spec
#   2. write config/groups/<group>.txt from its host list
#   3. register the acme-dns slot
#   4. wait until _acme-challenge.<domain> points at that slot
#   5. scan host keys that are still missing into config/known_hosts
#   6. issue and roll out (scripts/issue.sh)
#   7. verify the expiry and the deploy result
set -eu
cd "$(dirname "$0")/.."
. ./scripts/preflight.sh

spec=""
wizard=0
check_only=0
wait_s=0
group_mode=ask
issue_staging=0
issue_force=0
no_issue=0

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/new-cert.sh [options] <spec>

  --wizard          ask for domain, hosts and options, write the spec, continue
  --check           validate the spec and print the plan, change nothing
  --wait <seconds>  poll the CNAME for that long (default: check once)
  --update-group    replace a group file that does not match the spec
  --keep-group      never touch an existing group file
  --staging         issue on the Let's Encrypt staging endpoint
  --force           reissue an existing certificate
  --no-issue        prepare group, acme-dns slot and DNS, stop before issuing
  -h, --help

The spec is config/certs/<name>.conf or the shortcut <name>. See the README
section "Adding a certificate" for every key.
EOF
}

fail() {
    echo "new-cert: $*" >&2
    exit 1
}

valid_domain() {
    case "$1" in
        ''|.*|*..*|*.|*[!a-z0-9.-]*) return 1 ;;
        *.*) return 0 ;;
    esac
    return 1
}

valid_group() {
    case "$1" in
        ''|*[!a-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# host or host:port, the same shape config/groups accepts.
valid_host() {
    case "$1" in
        ''|*[!A-Za-z0-9.:-]*) return 1 ;;
        :*|*:|*::*) return 1 ;;
    esac
    case "$1" in
        *:*)
            _vh_port=${1##*:}
            case "$_vh_port" in
                ''|*[!0-9]*) return 1 ;;
            esac
            if [ "$_vh_port" -lt 1 ] || [ "$_vh_port" -gt 65535 ]; then
                return 1
            fi
            ;;
    esac
    case "$1" in
        .*|*.|*..*) return 1 ;;
    esac
    return 0
}

split_hosts() {
    printf '%s' "$1" | tr ',' '\n' | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

hosts_valid() {
    _hv_all=$(split_hosts "$1")
    [ -n "$_hv_all" ] || return 1
    for _hv_h in $_hv_all; do
        valid_host "$_hv_h" || {
            echo "   invalid host: $_hv_h" >&2
            return 1
        }
    done
    return 0
}

# --- spec ------------------------------------------------------------------

spec_domain=""
spec_wildcard=1
spec_hosts=""
spec_group=""
spec_name=""
spec_deploy_name=""
spec_deploy_path=""
spec_keylength=2048
spec_staging=0

load_spec() {
    [ -f "$1" ] || fail "spec missing: $1 (run --wizard to create one)"
    _ls_line=0
    while IFS= read -r _ls_in || [ -n "$_ls_in" ]; do
        _ls_line=$((_ls_line + 1))
        _ls_in=$(printf '%s' "$_ls_in" |
            sed -e 's/[[:space:]]#.*$//' \
                -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$_ls_in" in
            ''|'#'*) continue ;;
        esac
        case "$_ls_in" in
            *=*) ;;
            *) fail "$1:$_ls_line: expected key=value, got: $_ls_in" ;;
        esac
        _ls_key=$(printf '%s' "${_ls_in%%=*}" | tr 'A-Z' 'a-z')
        _ls_val=$(printf '%s' "${_ls_in#*=}" |
            sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        case "$_ls_key" in
            domain)      spec_domain=$_ls_val ;;
            wildcard)    spec_wildcard=$_ls_val ;;
            hosts)       spec_hosts=$_ls_val ;;
            group)       spec_group=$_ls_val ;;
            name)        spec_name=$_ls_val ;;
            deploy_name) spec_deploy_name=$_ls_val ;;
            deploy_path) spec_deploy_path=$_ls_val ;;
            keylength)   spec_keylength=$_ls_val ;;
            staging)     spec_staging=$_ls_val ;;
            *)
                fail "$1:$_ls_line: unknown key '$_ls_key' (see README, Adding a certificate)"
                ;;
        esac
    done < "$1"
}

cert=""
domain=""
group=""
hosts=""
slug=""
deploy_target=""

derive() {
    [ -n "$spec_domain" ] || fail "domain= is required"
    case "$spec_domain" in
        *\**) fail "domain= must not contain '*': use the base domain and wildcard=1" ;;
    esac
    valid_domain "$spec_domain" || fail "invalid domain: $spec_domain"

    case "$spec_wildcard" in
        1|yes|true) spec_wildcard=1 ;;
        0|no|false) spec_wildcard=0 ;;
        *) fail "wildcard= must be 1 or 0, got: $spec_wildcard" ;;
    esac
    case "$spec_staging" in
        1|yes|true) spec_staging=1 ;;
        0|no|false) spec_staging=0 ;;
        *) fail "staging= must be 1 or 0, got: $spec_staging" ;;
    esac

    domain=$spec_domain
    if [ -n "$spec_name" ]; then
        cert=$spec_name
    elif [ "$spec_wildcard" = 1 ]; then
        cert="*.$domain"
    else
        cert=$domain
    fi
    case "$cert" in
        \*.*) _dv_rest=${cert#\*.} ;;
        *\**) fail "name= may only start with '*.'" ;;
        *) _dv_rest=$cert ;;
    esac
    case "$_dv_rest" in
        ''|.*|*..*|*.|*[!a-z0-9.-]*) fail "invalid name: $cert" ;;
    esac
    case "$_dv_rest" in
        *.*) ;;
        *) fail "invalid name: $cert" ;;
    esac

    if [ -n "$spec_group" ]; then
        group=$spec_group
    else
        # First label: example.com -> example, like the hand-written groups.
        group=${domain%%.*}
        [ -n "$group" ] || group=$domain
    fi
    valid_group "$group" || fail "invalid group: $group (a-z, 0-9, _ and -), set group="

    hosts=$(split_hosts "$spec_hosts")
    [ -n "$hosts" ] || fail "hosts= is required"
    for _dv_h in $hosts; do
        valid_host "$_dv_h" || fail "invalid host: $_dv_h"
    done

    case "$spec_keylength" in
        2048|3072|4096|ec-256|ec-384|ec-521) ;;
        *) fail "invalid keylength: $spec_keylength" ;;
    esac

    if [ -n "$spec_deploy_name" ]; then
        case "$spec_deploy_name" in
            */*|'') fail "invalid deploy_name: $spec_deploy_name" ;;
        esac
    fi
    if [ -n "$spec_deploy_path" ]; then
        case "$spec_deploy_path" in
            /*) ;;
            *) fail "deploy_path must be absolute: $spec_deploy_path" ;;
        esac
        case "$spec_deploy_path" in
            *[!A-Za-z0-9/._-]*) fail "invalid deploy_path: $spec_deploy_path" ;;
        esac
    fi

    slug=$(printf '%s' "$cert" | sed 's/^\*\./wildcard./')
    if [ -n "$spec_deploy_name" ]; then
        deploy_target="$spec_deploy_name"
    elif [ "$cert" != "$domain" ]; then
        deploy_target="wildcard.$domain"
    else
        deploy_target=$cert
    fi
}

# Does the certificate cover this host name? A wildcard covers exactly one
# label, so the check is not a suffix match.
covers_host() {
    _cv_h=$1
    case "$_cv_h" in
        *:*) _cv_h=${_cv_h%:*} ;;
    esac
    case "$_cv_h" in
        *[!0-9.]*) ;;
        *) return 0 ;;                  # IP address, no name check
    esac
    case "$cert" in
        \*.*)
            _cv_base=${cert#\*.}
            case "$_cv_h" in
                "$_cv_base") return 0 ;;
                *."$_cv_base")
                    _cv_pre=${_cv_h%."$_cv_base"}
                    case "$_cv_pre" in
                        *.*) return 1 ;;
                        *) return 0 ;;
                    esac
                    ;;
            esac
            ;;
        *)
            [ "$_cv_h" = "$cert" ] && return 0
            ;;
    esac
    return 1
}

print_plan() {
    echo "== $spec"
    echo "   certificate  $cert"
    echo "   acme-dns     $domain -> config/acme-dns/$domain.env"
    if [ -f "config/groups/$group.txt" ]; then
        echo "   group        $group -> config/groups/$group.txt (exists)"
    else
        echo "   group        $group -> config/groups/$group.txt (new)"
    fi
    echo "   hosts        $(printf '%s' "$hosts" | tr '\n' ' ' | sed 's/ $//')"
    echo "   target       ${spec_deploy_path:-/etc/ssl}/$deploy_target.{crt,key,ca}"
    echo "   keylength    $spec_keylength"
    if [ "$spec_staging" = 1 ]; then
        echo "   staging      yes (no deploy)"
    fi
    for _pp_h in $hosts; do
        if ! covers_host "$_pp_h"; then
            echo "WARN: $_pp_h is not covered by $cert - right host?" >&2
        fi
    done
}

# --- group -----------------------------------------------------------------

write_group() {
    _wg_file=config/groups/$group.txt
    _wg_tmp=$(mktemp)
    _wg_n=$(printf '%s\n' $hosts | wc -l | tr -d ' ')

    {
        printf '# %s on %s host(s), from config/certs/%s.conf\n' "$cert" "$_wg_n" "$slug"
        printf '# generated by scripts/new-cert.sh - edit the spec, not this file\n'
        printf '%s\n' $hosts
    } > "$_wg_tmp"

    if [ -f "$_wg_file" ] && cmp -s "$_wg_file" "$_wg_tmp"; then
        echo "== group $group: unchanged ($_wg_n hosts)"
        rm -f "$_wg_tmp"
        return 0
    fi

    if [ -f "$_wg_file" ]; then
        _wg_owner=$(sed -n '1s/^# \([^ ]*\) on .*/\1/p' "$_wg_file")
        if [ -n "$_wg_owner" ] && [ "$_wg_owner" != "$cert" ]; then
            echo "WARN: config/groups/$group.txt belongs to $_wg_owner" >&2
        fi
        echo "== group $group exists and differs:" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$_wg_file" "$_wg_tmp" | sed 's/^/   /' >&2 || true
        else
            echo "   spec:  $(printf '%s' "$hosts" | tr '\n' ' ')" >&2
            echo "   file:  $(sed '/^#/d' "$_wg_file" | tr '\n' ' ')" >&2
        fi
    fi

    case "$group_mode" in
        update) ;;
        keep)
            rm -f "$_wg_tmp"
            echo "== group $group: kept (--keep-group)"
            return 0
            ;;
        *)
            if [ ! -f "$_wg_file" ]; then
                :
            elif [ "$check_only" = 1 ]; then
                rm -f "$_wg_tmp"
                echo "== group $group: would be rewritten (--check)" >&2
                return 0
            elif [ -t 0 ]; then
                printf 'Replace config/groups/%s.txt with the spec hosts? [y/N]: ' "$group" >&2
                read -r _wg_ans || _wg_ans=n
                case "$_wg_ans" in
                    y|Y|yes|YES) ;;
                    *)
                        rm -f "$_wg_tmp"
                        echo "== group $group: kept"
                        return 0
                        ;;
                esac
            else
                rm -f "$_wg_tmp"
                fail "config/groups/$group.txt differs from the spec: re-run with --update-group or --keep-group"
            fi
            ;;
    esac

    mv "$_wg_tmp" "$_wg_file"
    echo "== group $group: written ($_wg_n hosts)"
}

# --- acme-dns --------------------------------------------------------------

conf_get() {
    ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

acme_dns() {
    ./scripts/acme-dns-register.sh "$domain"
    _ad_file=config/acme-dns/$domain.env
    [ -f "$_ad_file" ] || fail "$_ad_file missing after registration"
    full=$(conf_get "$_ad_file" ACMEDNS_FULLDOMAIN)
    if [ -z "$full" ]; then
        fail "$_ad_file has no ACMEDNS_FULLDOMAIN"
    fi
}

cname_now() {
    dig +short CNAME "_acme-challenge.$domain" 2>/dev/null | head -n 1 |
        sed 's/\.$//' | tr 'A-Z' 'a-z'
}

ensure_cname() {
    _ec_want=$(printf '%s' "$full" | sed 's/\.$//' | tr 'A-Z' 'a-z')
    _ec_got=$(cname_now)
    if [ "$_ec_got" = "$_ec_want" ]; then
        echo "== DNS: _acme-challenge.$domain -> $full"
        return 0
    fi

    cat >&2 <<EOF

== DNS record needed
   _acme-challenge.$domain.  CNAME  $full.

   Create it in public DNS (DNS only, not proxied).
   Current answer: ${_ec_got:-nothing}
EOF

    if [ "$wait_s" -gt 0 ]; then
        _ec_left=$wait_s
        while [ "$_ec_left" -gt 0 ]; do
            sleep 10
            _ec_left=$((_ec_left - 10))
            _ec_got=$(cname_now)
            if [ "$_ec_got" = "$_ec_want" ]; then
                echo "== DNS: _acme-challenge.$domain -> $full (after $((wait_s - _ec_left))s)"
                return 0
            fi
            echo "   waiting, ${_ec_left}s left: ${_ec_got:-nothing}" >&2
        done
        fail "CNAME did not appear within ${wait_s}s: re-run when it is visible"
    fi

    if [ -t 0 ]; then
        while :; do
            printf 'Press Enter to check again (Ctrl-C to stop): ' >&2
            read -r _ec_ans || fail "CNAME check aborted"
            _ec_got=$(cname_now)
            if [ "$_ec_got" = "$_ec_want" ]; then
                echo "== DNS: _acme-challenge.$domain -> $full"
                return 0
            fi
            echo "   still ${_ec_got:-nothing}" >&2
        done
    fi

    fail "CNAME not visible yet: re-run later, or use --wait <seconds>"
}

# --- host keys -------------------------------------------------------------

ensure_host_keys() {
    if check_host_keys "$hosts"; then
        return 0
    fi
    echo "== scanning host keys into config/known_hosts"
    ./scripts/known-hosts.sh || fail "known-hosts.sh failed"
    check_host_keys "$hosts" || fail "host keys still missing after the scan"
}

# --- wizard ----------------------------------------------------------------

wizard_run() {
    echo "== new certificate"
    while :; do
        printf 'Base domain (example.com, no "*"): '
        read -r _wz_in || fail "wizard aborted"
        _wz_in=$(printf '%s' "$_wz_in" | tr 'A-Z' 'a-z' | tr -d ' \t')
        if valid_domain "$_wz_in"; then
            break
        fi
        echo "   not a domain: ${_wz_in:-<empty>}" >&2
    done
    _wz_domain=$_wz_in

    printf 'Wildcard too (*.%s and %s)? [Y/n]: ' "$_wz_domain" "$_wz_domain"
    read -r _wz_in || fail "wizard aborted"
    case "$_wz_in" in
        n|N|no|NO) _wz_wildcard=0 ;;
        *) _wz_wildcard=1 ;;
    esac
    if [ "$_wz_wildcard" = 1 ]; then
        _wz_cert="*.$_wz_domain"
        _wz_name="wildcard.$_wz_domain"
    else
        _wz_cert=$_wz_domain
        _wz_name=$_wz_domain
    fi

    while :; do
        printf 'Hosts for %s (comma or space separated, host[:port]) [%s]: ' \
            "$_wz_cert" "$_wz_domain"
        read -r _wz_in || fail "wizard aborted"
        [ -n "$_wz_in" ] || _wz_in=$_wz_domain
        if hosts_valid "$_wz_in"; then
            break
        fi
    done
    _wz_hosts=$(split_hosts "$_wz_in" | tr '\n' ' ' | sed 's/ $//')

    printf 'Group name [%s]: ' "${_wz_domain%%.*}"
    read -r _wz_in || fail "wizard aborted"
    _wz_group=${_wz_in:-${_wz_domain%%.*}}
    valid_group "$_wz_group" || fail "invalid group: $_wz_group (a-z, 0-9, _ and -)"

    printf 'File name on the hosts [%s]: ' "$_wz_name"
    read -r _wz_in || fail "wizard aborted"
    _wz_deploy_name=${_wz_in:-$_wz_name}

    printf 'Target directory [/etc/ssl]: '
    read -r _wz_in || fail "wizard aborted"
    _wz_deploy_path=${_wz_in:-/etc/ssl}

    printf 'Key length [2048] (3072, 4096, ec-256, ec-384, ec-521): '
    read -r _wz_in || fail "wizard aborted"
    _wz_keylength=${_wz_in:-2048}

    _wz_slug=$(printf '%s' "$_wz_cert" | sed 's/^\*\./wildcard./')
    _wz_file=config/certs/$_wz_slug.conf
    mkdir -p config/certs

    if [ -f "$_wz_file" ]; then
        printf '%s exists. Overwrite? [y/N]: ' "$_wz_file" >&2
        read -r _wz_in || fail "wizard aborted"
        case "$_wz_in" in
            y|Y|yes|YES) ;;
            *) fail "$_wz_file kept, nothing done" ;;
        esac
    fi

    cat > "$_wz_file" <<EOF
# $_wz_cert - written by ./scripts/new-cert.sh --wizard
# The certificate, its group file and its acme-dns slot are derived from here.
domain=$_wz_domain
wildcard=$_wz_wildcard
hosts=$_wz_hosts
group=$_wz_group
deploy_name=$_wz_deploy_name
deploy_path=$_wz_deploy_path
keylength=$_wz_keylength
EOF
    echo "== wrote $_wz_file"
    spec=$_wz_file
    load_spec "$spec"
    derive
}

# --- main ------------------------------------------------------------------

[ $# -gt 0 ] || { usage; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --wizard) wizard=1; shift ;;
        --check) check_only=1; shift ;;
        --wait)
            [ $# -ge 2 ] || { usage; exit 1; }
            wait_s=$2
            shift 2
            ;;
        --wait=*) wait_s=${1#*=}; shift ;;
        --update-group) group_mode=update; shift ;;
        --keep-group) group_mode=keep; shift ;;
        --staging) issue_staging=1; shift ;;
        --force) issue_force=1; shift ;;
        --no-issue) no_issue=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
        *) break ;;
    esac
done
case "$wait_s" in
    ''|*[!0-9]*) fail "invalid --wait: $wait_s" ;;
esac

if [ "$wizard" = 1 ]; then
    [ $# -eq 0 ] || fail "--wizard does not take a spec"
    wizard_run
else
    [ $# -eq 1 ] || { usage; exit 1; }
    spec=$1
    case "$spec" in
        */*) ;;
        *) spec=config/certs/$spec.conf ;;
    esac
    load_spec "$spec"
    derive
fi

[ -f .env ] || fail ".env missing: cp .env.example .env"
print_plan

if [ "$check_only" = 1 ]; then
    check_cert_conflicts "$cert" "$hosts"
    check_host_keys "$hosts"
    if [ -f "acme/$cert/$cert.cer" ] || [ -f "acme/${cert}_ecc/$cert.cer" ]; then
        echo "== certificate: issued already (reissue with --force)"
    else
        echo "== certificate: not issued yet"
    fi
    if command -v dig >/dev/null 2>&1; then
        _ck_full=""
        [ -f "config/acme-dns/$domain.env" ] &&
            _ck_full=$(conf_get "config/acme-dns/$domain.env" ACMEDNS_FULLDOMAIN)
        if [ -f "config/acme-dns/$domain.env" ] && [ -z "$_ck_full" ]; then
            echo "WARN: config/acme-dns/$domain.env has no ACMEDNS_FULLDOMAIN" >&2
        fi
        if [ -n "$_ck_full" ]; then
            _ck_got=$(cname_now)
            _ck_want=$(printf '%s' "$_ck_full" | sed 's/\.$//' | tr 'A-Z' 'a-z')
            if [ "$_ck_got" = "$_ck_want" ]; then
                echo "== DNS: _acme-challenge.$domain -> $_ck_full"
            else
                echo "== DNS: _acme-challenge.$domain. CNAME $_ck_full (current: ${_ck_got:-nothing})"
            fi
        else
            echo "== DNS: acme-dns slot not registered yet"
        fi
    fi
    echo "== check only, nothing changed"
    exit 0
fi

write_group
acme_dns
ensure_cname
ensure_host_keys

if [ "$no_issue" = 1 ]; then
    echo "== prepared: group, acme-dns slot and DNS are in place"
    echo "   issue with: ./scripts/issue.sh '$cert' '$group'"
    exit 0
fi

# The spec can pin the deploy target; issue.sh passes these to the hook.
if [ -n "$spec_deploy_name" ]; then
    DEPLOY_NAME=$spec_deploy_name
    export DEPLOY_NAME
fi
if [ -n "$spec_deploy_path" ]; then
    DEPLOY_PATH=$spec_deploy_path
    export DEPLOY_PATH
fi

issue_args=""
if [ "$issue_staging" = 1 ] || [ "$spec_staging" = 1 ]; then
    issue_args="--staging"
fi
if [ "$issue_force" = 1 ]; then
    issue_args="$issue_args --force"
fi
if [ "$spec_keylength" != 2048 ]; then
    issue_args="$issue_args --keylength $spec_keylength"
fi

# Word splitting is intended: issue_args holds plain flags, no user data.
# shellcheck disable=SC2086
./scripts/issue.sh $issue_args "$cert" "$group"

if [ "$issue_staging" = 1 ] || [ "$spec_staging" = 1 ]; then
    echo "== staging only: no deploy"
    exit 0
fi

echo "== verify"
if [ -f "acme/$cert/$cert.cer" ]; then
    _v_cer="acme/$cert/$cert.cer"
else
    _v_cer="acme/${cert}_ecc/$cert.cer"
fi
if [ -f "$_v_cer" ]; then
    if command -v openssl >/dev/null 2>&1; then
        openssl x509 -noout -subject -enddate -in "$_v_cer" | sed 's/^/   /'
    fi
    echo "   $cert on $(printf '%s\n' $hosts | wc -l | tr -d ' ') host(s): $(printf '%s' "$hosts" | tr '\n' ' ')"
    echo "   renewal is automatic (ARI window, about 30 days before expiry)"
    echo "   more hosts: add them to $spec and run this again"
fi
