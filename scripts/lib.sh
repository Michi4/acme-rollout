#!/bin/sh
# Small helpers shared by the host-side scripts. Sourced, not executed.
#
# The certificate name is the identity everything else hangs off: the acme.sh
# directory, the deploy-state directory and the default spec file name. Keeping
# the mapping in one place is what stops those three from drifting apart.

# *.example.com -> example.com
cert_base() {
    printf '%s' "${1#\*.}"
}

# Certificate name -> deploy-state directory (and default spec file name).
# "*.example.com" becomes "wildcard.example.com" so no "*" ends up in a path.
cert_slug() {
    case "$1" in
        \*.*) printf 'wildcard.%s' "${1#\*.}" ;;
        *)    printf '%s' "$1" ;;
    esac
}

# Deploy-state directory -> certificate name (reverse of cert_slug).
slug_cert() {
    case "$1" in
        wildcard.*) printf '*.%s' "${1#wildcard.}" ;;
        *)          printf '%s' "$1" ;;
    esac
}

# A DNS name: lowercase, at least one dot, no empty label.
valid_hostname() {
    case "$1" in
        ''|.*|*..*|*.|*[!a-z0-9.-]*) return 1 ;;
    esac
    case "$1" in
        *.*) return 0 ;;
    esac
    return 1
}

# A certificate name: a hostname, optionally as "*.example.com".
valid_cert_name() {
    case "$1" in
        \*.*) valid_hostname "${1#\*.}" ;;
        *)    valid_hostname "$1" ;;
    esac
}

# One key from a spec file, without sourcing it. Unknown or missing keys print
# nothing. Trailing comments, surrounding whitespace and quotes are removed the
# same way scripts/new-cert.sh does it.
spec_get() {
    [ -f "$1" ] || return 0
    awk -v key="$2" '
        {
            line = $0
            sub(/[[:space:]]#.*$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ ("^" key "[[:space:]]*=")) {
                sub("^[^=]*=[[:space:]]*", "", line)
                if (line ~ /^".*"$/ || line ~ /^\047.*\047$/) {
                    line = substr(line, 2, length(line) - 2)
                }
                print line
                exit
            }
        }
    ' "$1"
}

# The certificate a spec would create: name= wins, then wildcard=, then domain.
spec_cert() {
    _lib_sc_name=$(spec_get "$1" name)
    if [ -n "$_lib_sc_name" ]; then
        printf '%s' "$_lib_sc_name"
        return 0
    fi
    _lib_sc_domain=$(spec_get "$1" domain)
    case "$(spec_get "$1" wildcard)" in
        0) printf '%s' "$_lib_sc_domain" ;;
        *) printf '*.%s' "$_lib_sc_domain" ;;
    esac
}

# Every spec file that belongs to a certificate, one path per line.
# config/certs/example.conf is the tracked template, never a real certificate.
specs_for_cert() {
    for _lib_sp in config/certs/*.conf; do
        [ -f "$_lib_sp" ] || continue
        case "$_lib_sp" in
            */example.conf) continue ;;
        esac
        [ "$(spec_cert "$_lib_sp")" = "$1" ] || continue
        printf '%s\n' "$_lib_sp"
    done
}
