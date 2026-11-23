#!/bin/sh
# Hostkeys aller Server aus config/groups/*.txt nach config/known_hosts holen.
# Erreichbare Server werden neu gescannt; fuer nicht erreichbare Server bleiben
# die vorhandenen Keys erhalten. Nach jedem neuen Server einmal ausfuehren.
set -eu
cd "$(dirname "$0")/.."

out=config/known_hosts
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

hosts=$(./scripts/hosts.sh all)
[ -n "$hosts" ] || { echo "keine Server in config/groups" >&2; exit 1; }

printf '%s\n' "$hosts" | sort -u | while read -r h; do
    case "$h" in
        *:*) host=${h%:*}; port=${h##*:}; lookup="[$host]:$port" ;;
        *)   host=$h; port=22; lookup=$h ;;
    esac
    keys=$(ssh-keyscan -T 8 -p "$port" -H "$host" 2>/dev/null) || true
    if [ -n "$keys" ]; then
        printf '%s\n' "$keys"
    else
        echo "WARN: $host:$port nicht erreichbar - vorhandene Keys bleiben" >&2
        if [ -f "$out" ]; then
            ssh-keygen -F "$lookup" -f "$out" 2>/dev/null | grep -v '^#' || true
        fi
    fi
done > "$tmp"

[ -s "$tmp" ] || { echo "keine Hostkeys gefunden" >&2; exit 1; }
mv "$tmp" "$out"
echo "$(wc -l < "$out") Hostkeys in $out"
