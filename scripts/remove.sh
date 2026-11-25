#!/bin/sh
# Take a certificate out of renewal, optionally revoke it, and clean up behind
# it: its spec, the group file it generated and its deploy state.
#
#   ./scripts/remove.sh '*.example.com'
#   ./scripts/remove.sh config/certs/hahnenkamm.conf   # takes the cert from the spec
#   ./scripts/remove.sh example.net --revoke
#   ./scripts/remove.sh example.net --check            # show the plan, change nothing
#   ./scripts/remove.sh example.net --host web2.example.net
#
# Without --revoke the certificate and key stay under acme/<domain>/ but are no
# longer renewed. --revoke revokes the certificate with the CA first. Files on
# the target hosts and the CNAME in public DNS are left alone; remove both by
# hand if needed.
#
# The spec in config/certs that describes this certificate is deleted as well,
# so a later new-cert.sh run cannot bring the certificate back. --keep-spec
# leaves the file in place and only warns. A group file is deleted only when it
# was generated for this certificate and no other spec uses it (--keep-group).
set -eu
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

usage() {
    cat >&2 <<'EOF'
Usage: ./scripts/remove.sh <certificate|spec> [options]

  --revoke        revoke the certificate with the CA first
  --host <host>   remove one host from the spec, its group and its deploy state;
                  other than that the certificate stays
  --keep-spec     keep config/certs/<name>.conf
  --keep-group    keep config/groups/<group>.txt
  --purge-dns     also delete config/acme-dns/<domain>.env
  --check         print what would be removed and exit
  -h, --help
EOF
}

[ -f .env ] || { echo ".env missing: cp .env.example .env" >&2; exit 1; }

revoke=0
keep_spec=0
keep_group=0
purge_dns=0
check_only=0
drop_host=""
arg=""

while [ $# -gt 0 ]; do
    case "$1" in
        --revoke)     revoke=1 ;;
        --keep-spec)  keep_spec=1 ;;
        --keep-group) keep_group=1 ;;
        --purge-dns)  purge_dns=1 ;;
        --check)      check_only=1 ;;
        --host)
            [ $# -ge 2 ] || { usage; exit 1; }
            drop_host=$2
            shift
            ;;
        --host=*)     drop_host=${1#*=} ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "unknown option: $1" >&2; usage; exit 1 ;;
        *)
            [ -z "$arg" ] || { echo "unexpected argument: $1" >&2; usage; exit 1; }
            arg=$1
            ;;
    esac
    shift
done

[ -n "$arg" ] || { usage; exit 1; }

# A spec is only taken as a spec when it is named as one; anything else is a
# certificate name. That keeps "./scripts/remove.sh example.com" from picking up
# an unrelated config/certs/example.com.conf that contains a wildcard.
spec=""
case "$arg" in
    *.conf|*/*)
        [ -f "$arg" ] || { echo "spec missing: $arg" >&2; exit 1; }
        spec=$arg
        cert=$(spec_cert "$spec")
        ;;
    *)
        cert=$arg
        ;;
esac

if ! valid_cert_name "$cert"; then
    echo "invalid domain: ${cert:-<empty>}" >&2
    exit 1
fi
base=$(cert_base "$cert")
slug=$(cert_slug "$cert")

# Specs that describe this certificate. With an explicit spec only that file is
# touched, even if another spec happened to claim the same certificate.
if [ -n "$spec" ]; then
    specs=$spec
else
    specs=$(specs_for_cert "$cert")
fi

if [ -n "$drop_host" ]; then
    case "$drop_host" in
        *:*)
            drop_port=${drop_host##*:}
            case "$drop_port" in
                ''|*[!0-9]*) echo "invalid host: $drop_host" >&2; exit 1 ;;
            esac
            drop_name=${drop_host%:*}
            ;;
        *)
            drop_name=$drop_host
            drop_port=22
            ;;
    esac
    if ! valid_hostname "$drop_name"; then
        echo "invalid host: $drop_host" >&2
        exit 1
    fi
    if [ -z "$specs" ]; then
        echo "no spec in config/certs describes $cert" >&2
        echo "(a host can only be removed together with its spec file)" >&2
        exit 1
    fi
    count=$(printf '%s\n' "$specs" | awk 'NF' | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
        echo "$cert is described by more than one spec:" >&2
        printf '%s\n' "$specs" | sed 's/^/  /' >&2
        echo "pass the one to edit, for example: $0 <spec> --host $drop_host" >&2
        exit 1
    fi
    spec=$specs
    group=$(spec_get "$spec" group)
    before=$(spec_get "$spec" hosts | tr ',' ' ')

    found=0
    for h in $before; do
        [ "$h" = "$drop_host" ] && found=1
        [ "$h" = "$drop_name" ] && found=1
    done
    if [ "$found" = 0 ]; then
        echo "$drop_host is not in $spec" >&2
        echo "hosts: ${before:-<none>}" >&2
        exit 1
    fi

    state_file="acme/deploy-state/$slug/${drop_name}_${drop_port}"

    if [ "$check_only" = 1 ]; then
        echo "== would remove host $drop_host from $cert"
        echo "   spec    $spec"
        [ -n "$group" ] && echo "   group   config/groups/$group.txt"
        echo "   state   $state_file"
        exit 0
    fi

    # Keep the rest of the line untouched: only the value changes.
    tmp="$spec.$$"
    awk -v drop="$drop_host" -v drop2="$drop_name" '
        /^[[:space:]]*hosts[[:space:]]*=/ {
            eq = index($0, "=")
            head = substr($0, 1, eq)
            val = substr($0, eq + 1)
            n = split(val, a, /[ ,]+/)
            out = ""
            for (i = 1; i <= n; i++) {
                if (a[i] == "" || a[i] == drop || a[i] == drop2) continue
                out = out (out == "" ? "" : " ") a[i]
            }
            printf "%s%s\n", head, out
            next
        }
        { print }
    ' "$spec" > "$tmp"
    mv "$tmp" "$spec"

    if [ -n "$group" ] && [ -f "config/groups/$group.txt" ]; then
        for m in $drop_host $drop_name; do
            tmp="config/groups/$group.txt.$$"
            awk -v drop="$m" '$1 != drop' "config/groups/$group.txt" > "$tmp"
            mv "$tmp" "config/groups/$group.txt"
        done
    fi

    rm -f "$state_file"
    after=$(spec_get "$spec" hosts | tr ',' ' ')
    echo "removed host: $drop_host ($cert)"
    echo "   spec  $spec -> ${after:-<no hosts left>}"
    [ -n "$after" ] || echo "   WARN: no hosts left; remove the certificate with: $0 '$cert'"
    if [ -n "$after" ] && [ ! -f "$state_file" ]; then
        echo "   the next deploy sync pushes $cert to the remaining hosts"
    fi
    echo "   files on $drop_name are left in place; remove them by hand"
    exit 0
fi

# --- plan ------------------------------------------------------------------

groups=""
hosts=""
for s in $specs; do
    g=$(spec_get "$s" group)
    [ -n "$g" ] && groups="$groups $g"
    hosts="$hosts $(spec_get "$s" hosts | tr ',' ' ')"
done
if [ -z "$hosts" ]; then
    # No spec: the deployed hosts are recorded in the state directory.
    for f in "acme/deploy-state/$slug"/*; do
        [ -f "$f" ] || continue
        n=${f##*/}
        case "$n" in
            *_*) hosts="$hosts ${n%_*}:${n##*_}" ;;
        esac
    done
fi
hosts=$(printf '%s\n' $hosts | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
groups=$(printf '%s\n' $groups | awk 'NF && !seen[$0]++')

group_owned() {
    _ro_g=$1
    _ro_file=config/groups/$_ro_g.txt
    [ -f "$_ro_file" ] || return 1
    _ro_owner=$(sed -n '1s/^# \([^ ]*\) on .*/\1/p' "$_ro_file")
    [ "$_ro_owner" = "$cert" ] || return 1
    # Another spec may reuse the same group on purpose.
    for _ro_spec in config/certs/*.conf; do
        [ -f "$_ro_spec" ] || continue
        case "$_ro_spec" in
            */example.conf) continue ;;
        esac
        [ "$(spec_cert "$_ro_spec")" = "$cert" ] && continue
        [ "$(spec_get "$_ro_spec" group)" = "$_ro_g" ] && return 1
    done
    return 0
}

if [ "$check_only" = 1 ]; then
    echo "== would remove $cert"
    if [ -n "$specs" ]; then
        for s in $specs; do
            if [ "$keep_spec" = 1 ]; then
                echo "   spec    $s (kept, --keep-spec)"
            else
                echo "   spec    $s (deleted)"
            fi
        done
    else
        echo "   spec    none"
    fi
    for g in $groups; do
        if [ "$keep_group" = 1 ]; then
            echo "   group   config/groups/$g.txt (kept, --keep-group)"
        elif group_owned "$g"; then
            echo "   group   config/groups/$g.txt (deleted)"
        else
            echo "   group   config/groups/$g.txt (kept, not generated for $cert)"
        fi
    done
    echo "   state   acme/deploy-state/$slug"
    [ -f "config/acme-dns/$base.env" ] &&
        { [ "$purge_dns" = 1 ] && echo "   dns     config/acme-dns/$base.env (deleted)" ||
          echo "   dns     config/acme-dns/$base.env (kept, --purge-dns)"; }
    [ "$revoke" = 1 ] && echo "   revoke  yes" || echo "   revoke  no"
    echo "   hosts   ${hosts:-unknown} (files stay there, remove by hand)"
    echo "== check only, nothing changed"
    exit 0
fi

# --- act -------------------------------------------------------------------

ecc=""
if [ -d "acme/${cert}_ecc" ]; then
    ecc="--ecc"
fi

rc=0
if [ "$revoke" = 1 ]; then
    if ! docker compose run --rm acme --locked --revoke --domain "$cert" $ecc; then
        echo "WARN: revocation failed, stopping renewal anyway" >&2
        rc=1
    fi
fi
docker compose run --rm acme --locked --remove --domain "$cert" $ecc

rm -rf "acme/deploy-state/$slug"

# A failed revocation leaves a certificate that is still valid on every host.
# Its spec is the only thing that still tracks it, so it is kept.
if [ "$rc" -ne 0 ]; then
    echo "kept spec: $(printf '%s' "$specs" | tr '\n' ' ')(revocation failed)"
else
    for s in $specs; do
        if [ "$keep_spec" = 1 ]; then
            echo "kept spec: $s (new-cert.sh would recreate $cert)"
        else
            # Specs are git-ignored (they name internal hosts), so deletion is
            # otherwise final. Keep a timestamped copy next to the acme data.
            mkdir -p acme/removed-specs
            backup="acme/removed-specs/${s##*/}.$(date +%Y%m%dT%H%M%S)"
            cp "$s" "$backup" 2>/dev/null && echo "kept a copy: $backup"
            rm -f "$s"
            echo "removed spec: $s"
        fi
    done
fi

for g in $groups; do
    if [ "$keep_group" = 1 ]; then
        echo "kept group: config/groups/$g.txt (--keep-group)"
    elif group_owned "$g"; then
        rm -f "config/groups/$g.txt"
        echo "removed group: config/groups/$g.txt"
    else
        echo "kept group: config/groups/$g.txt (not generated for $cert)"
    fi
done

if [ "$purge_dns" = 1 ]; then
    if [ -f "config/acme-dns/$base.env" ]; then
        rm -f "config/acme-dns/$base.env"
        echo "removed acme-dns credentials: config/acme-dns/$base.env"
    fi
else
    [ -f "config/acme-dns/$base.env" ] &&
        echo "kept acme-dns credentials: config/acme-dns/$base.env (--purge-dns)"
fi

if [ "$revoke" = 1 ] && [ "$rc" -eq 0 ]; then
    echo "removed and revoked: $cert"
elif [ "$revoke" = 1 ]; then
    echo "removed: $cert (revocation failed, certificate is valid until expiry)"
else
    echo "removed: $cert (certificate is kept but no longer renewed)"
fi
exit "$rc"
