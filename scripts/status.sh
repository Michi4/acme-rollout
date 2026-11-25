#!/bin/sh
# Show whether specs, certificates, groups, host keys, DNS and deploy state
# still agree with each other. Read-only, safe to run at any time.
#
#   ./scripts/status.sh
#   ./scripts/status.sh --quiet     # only problems and the summary
#
# Exit code 0: everything consistent. 1: at least one problem was printed.
#
# The pairs this checks are exactly the ones that drift in practice:
#   spec without certificate     certificate without spec
#   spec group missing           group file nobody owns
#   spec hosts not covered       host key missing
#   acme-dns slot missing        deploy state for a certificate that is gone
set -u
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

quiet=0
for arg in "$@"; do
    case "$arg" in
        --quiet) quiet=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

problems=0
say() {
    [ "$quiet" = 1 ] && return 0
    echo "$@"
}
warn() {
    problems=$((problems + 1))
    echo "WARN: $*"
}
error() {
    problems=$((problems + 1))
    echo "ERROR: $*"
}

# The certificate that covers a host. A wildcard covers exactly one label.
covers() {
    _st_cert=$1
    _st_host=${2%%:*}
    case "$_st_cert" in
        \*.*)
            _st_base=${_st_cert#\*.}
            case "$_st_host" in
                "$_st_base") return 0 ;;
                *."$_st_base")
                    _st_pre=${_st_host%."$_st_base"}
                    case "$_st_pre" in
                        *.*) return 1 ;;
                        '') return 1 ;;
                        *) return 0 ;;
                    esac
                    ;;
            esac
            return 1
            ;;
        *)
            [ "$_st_host" = "$_st_cert" ]
            ;;
    esac
}

cert_dir() {
    if [ -d "acme/$1" ]; then
        printf 'acme/%s' "$1"
    elif [ -d "acme/${1}_ecc" ]; then
        printf 'acme/%s_ecc' "$1"
    fi
}

host_state_file() {
    _st_slug=$(cert_slug "$1")
    _st_h=$2
    case "$_st_h" in
        *:*) printf 'acme/deploy-state/%s/%s_%s' "$_st_slug" "${_st_h%:*}" "${_st_h##*:}" ;;
        *)   printf 'acme/deploy-state/%s/%s_22' "$_st_slug" "$_st_h" ;;
    esac
}

# --- specs -> certificate --------------------------------------------------

specs=0
for spec in config/certs/*.conf; do
    [ -f "$spec" ] || continue
    case "$spec" in
        */example.conf) continue ;;
    esac
    specs=$((specs + 1))
    cert=$(spec_cert "$spec")
    domain=$(spec_get "$spec" domain)
    hosts=$(spec_get "$spec" hosts | tr ',' ' ')
    group=$(spec_get "$spec" group)

    if [ -z "$domain" ]; then
        error "$spec: domain= is missing"
        continue
    fi
    if [ -z "$hosts" ]; then
        error "$spec: hosts= is missing"
        continue
    fi
    if ! valid_cert_name "$cert"; then
        error "$spec: invalid certificate name '$cert' (domain=$domain wildcard=$(spec_get "$spec" wildcard))"
        continue
    fi

    dir=$(cert_dir "$cert")
    if [ -z "$dir" ]; then
        error "$spec: $cert is not issued (no acme/$cert or acme/${cert}_ecc)"
        say "      run: ./scripts/new-cert.sh $spec"
    elif [ ! -f "$dir/$cert.conf" ]; then
        error "$spec: $cert has no acme.sh config ($dir/$cert.conf) - it is not renewed"
        say "      reissue with ./scripts/new-cert.sh $spec, or remove it with ./scripts/remove.sh $spec"
    elif [ ! -f "$dir/$cert.cer" ]; then
        error "$spec: $cert has no certificate file ($dir/$cert.cer)"
    else
        say "ok:   $spec -> $cert"
    fi

    if [ -n "$group" ]; then
        gfile=config/groups/$group.txt
        if [ ! -f "$gfile" ]; then
            error "$spec: group file $gfile is missing (new-cert.sh would create it)"
        else
            owner=$(sed -n '1s/^# \([^ ]*\) on .*/\1/p' "$gfile")
            if [ -n "$owner" ] && [ "$owner" != "$cert" ]; then
                error "$gfile belongs to $owner, but $spec names it"
            fi
            # Hosts in the file that the spec does not list are intentional for
            # hand-written groups; hosts in the spec that are missing are not.
            for h in $hosts; do
                grep -qxF "$h" "$gfile" ||
                    warn "$gfile does not contain $h from $spec"
            done
        fi
    fi

    for h in $hosts; do
        if ! covers "$cert" "$h"; then
            warn "$h is not covered by $cert ($spec)"
        fi
        if [ -f config/known_hosts ] && command -v ssh-keygen >/dev/null 2>&1; then
            case "$h" in
                *:*) lookup="[${h%:*}]:${h##*:}" ;;
                *)   lookup=$h ;;
            esac
            ssh-keygen -F "$lookup" -f config/known_hosts >/dev/null 2>&1 ||
                warn "no host key for $h (run ./scripts/known-hosts.sh)"
        fi
        state=$(host_state_file "$cert" "$h")
        if [ -f "$state" ]; then
            read -r ok _try _fails < "$state" || ok=0
            case "${ok:-0}" in
                ''|*[!0-9]*) ok=0 ;;
            esac
            if [ "$ok" -eq 0 ]; then
                warn "$h has no successful deploy yet ($state)"
            fi
        else
            warn "$h was never deployed for $cert (no $state)"
        fi
    done

    dns=config/acme-dns/$domain.env
    if [ ! -f "$dns" ]; then
        warn "no acme-dns credentials for $domain ($dns)"
    fi
done

# --- certificates -> spec --------------------------------------------------

certs=0
for dir in acme/*/; do
    [ -d "$dir" ] || continue
    name=${dir%/}
    name=${name##*/}
    case "$name" in
        deploy-state|staging|.*) continue ;;
    esac
    cert=$name
    case "$name" in
        *_ecc) cert=${name%_ecc} ;;
    esac
    if [ ! -f "$dir$cert.conf" ]; then
        # Certificate files without a domain config: acme.sh no longer renews
        # this one (remove.sh, a failed issuance, a manual --remove).
        if [ -f "$dir$cert.cer" ]; then
            certs=$((certs + 1))
            error "$cert: no acme.sh config ($dir$cert.conf), so it is not renewed"
            [ -n "$(specs_for_cert "$cert")" ] ||
                say "      no spec either; remove it with ./scripts/remove.sh '$cert'"
        fi
        continue
    fi
    certs=$((certs + 1))
    hook=$(sed -n "s/^Le_DeployHook='\{0,1\}\([^',]*\).*/\1/p" "$dir$cert.conf" | head -n 1)
    [ -n "$hook" ] || hook=$(sed -n 's/^Le_DeployHook=//p' "$dir$cert.conf" | head -n 1 | tr -d "'\"")
    if [ -z "$hook" ]; then
        warn "$cert has no deploy hook (only the certificate is renewed)"
        continue
    fi
    if [ -z "$(specs_for_cert "$cert")" ]; then
        warn "$cert has no spec in config/certs (group is $(
            sed -n "s/^SAVED_DEPLOY_GROUP='\{0,1\}\([^',]*\).*/\1/p" "$dir$cert.conf" | head -n 1
        )) - a leftover spec cannot exist, but edits have no home"
    fi
done

# --- orphans ---------------------------------------------------------------

for dir in acme/deploy-state/*/; do
    [ -d "$dir" ] || continue
    slug=${dir%/}
    slug=${slug##*/}
    [ -n "$(cert_dir "$(slug_cert "$slug")")" ] && continue
    error "deploy state for $slug, but no such certificate (left over from remove?)"
done

for dns in config/acme-dns/*.env; do
    [ -f "$dns" ] || continue
    base=${dns##*/}
    base=${base%.env}
    if [ -z "$(cert_dir "$base")" ] && [ -z "$(cert_dir "*.$base")" ]; then
        warn "acme-dns credentials for $base, but no certificate uses them"
    fi
done

for gfile in config/groups/*.txt; do
    [ -f "$gfile" ] || continue
    owner=$(sed -n '1s/^# \([^ ]*\) on .*/\1/p' "$gfile")
    [ -n "$owner" ] || continue
    if [ -z "$(cert_dir "$owner")" ] && [ -z "$(specs_for_cert "$owner")" ]; then
        warn "$gfile was generated for $owner, which no longer exists"
    fi
done

if [ "$specs" -eq 0 ] && [ "$certs" -eq 0 ]; then
    say "nothing to check: no specs in config/certs and no certificates in acme/"
fi
echo "status: $specs spec(s), $certs certificate(s), $problems problem(s)"
[ "$problems" -eq 0 ] || exit 1
exit 0
