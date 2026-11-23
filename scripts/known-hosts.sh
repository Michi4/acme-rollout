#!/bin/sh
# Fetch host keys for every server in config/groups/*.txt into config/known_hosts.
# Reachable servers are scanned again; unreachable ones keep their existing keys.
# Run once after adding a new server.
set -eu
cd "$(dirname "$0")/.."

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
    keys=$(ssh-keyscan -T 8 -p "$port" -H "$host" 2>/dev/null) || true
    if [ -n "$keys" ]; then
        printf '%s\n' "$keys"
    else
        echo "WARN: $host:$port unreachable - keeping existing keys" >&2
        if [ -f "$out" ]; then
            ssh-keygen -F "$lookup" -f "$out" 2>/dev/null | grep -v '^#' || true
        fi
    fi
done > "$tmp"

[ -s "$tmp" ] || { echo "no host keys found" >&2; exit 1; }
mv "$tmp" "$out"
echo "$(wc -l < "$out") host keys in $out"
