#!/bin/sh
# Fetch host keys for every server in config/groups/*.txt into config/known_hosts.
#
#   ./scripts/known-hosts.sh              # ssh-keyscan (trust on first use)
#   SSH_USER=root SSH_KEY=~/.ssh/bwh ./scripts/known-hosts.sh --from-ssh
#
# --from-ssh reads /etc/ssh/ssh_host_*_key.pub over an already authenticated
# SSH session. Prefer it when the admin machine has root access: it avoids a
# separate trust-on-first-use scan and keeps the existing root trust chain.
#
# Reachable servers are scanned again; unreachable ones keep their existing keys.
# Run once after adding a new server.
set -u
cd "$(dirname "$0")/.."

mode=keyscan
case "${1:-}" in
    --from-ssh) mode=ssh ;;
    -h|--help) echo "Usage: $0 [--from-ssh]" >&2; exit 0 ;;
    '') ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

out=config/known_hosts
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

hosts=$(./scripts/hosts.sh all)
[ -n "$hosts" ] || { echo "no servers in config/groups" >&2; exit 1; }

printf '%s\n' "$hosts" | sort -u | while read -r h; do
    case "$h" in
        *:*) host=${h%:*}; port=${h##*:}; lookup="[$host]:$port" ;;
        *)   host=$h; port=22; lookup=$h ;;
    esac

    if [ "$mode" = ssh ]; then
        user=${SSH_USER:-root}
        key=${SSH_KEY:-}
        set -- ssh -n -o BatchMode=yes -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
            -p "$port"
        [ -n "$key" ] && set -- "$@" -i "$key"
        keys=$("$@" "${user}@${host}" \
            'cat /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub 2>/dev/null' \
            2>/dev/null) || true
        if [ -n "$keys" ]; then
            printf '%s\n' "$keys" | while read -r type value; do
                if [ -n "$type" ] && [ -n "$value" ]; then
                    printf '%s %s %s\n' "$lookup" "$type" "$value"
                fi
            done
        else
            echo "WARN: $host:$port unreachable - keeping existing keys" >&2
            if [ -f "$out" ]; then
                ssh-keygen -F "$lookup" -f "$out" 2>/dev/null | grep -v '^#' || true
            fi
        fi
    else
        keys=$(ssh-keyscan -T 8 -p "$port" -H "$host" 2>/dev/null) || true
        if [ -n "$keys" ]; then
            printf '%s\n' "$keys"
        else
            echo "WARN: $host:$port unreachable - keeping existing keys" >&2
            if [ -f "$out" ]; then
                ssh-keygen -F "$lookup" -f "$out" 2>/dev/null | grep -v '^#' || true
            fi
        fi
    fi
done > "$tmp"

[ -s "$tmp" ] || { echo "no host keys found" >&2; exit 1; }
mv "$tmp" "$out"
echo "$(wc -l < "$out") host keys in $out"
