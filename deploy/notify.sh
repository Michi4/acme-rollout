#!/bin/sh
# Eine Alarm-Mail verschicken.
#
#   printf 'Text\n' | ./deploy/notify.sh "Betreff"
#   ./deploy/notify.sh --test
#
# Ohne SMTP_HOST oder ALERT_EMAIL wird nichts verschickt, sondern die Meldung
# mit einer Warnung ins Log geschrieben. Der Zyklus laeuft dadurch weiter.
set -u

to=${ALERT_EMAIL:-}
host=${SMTP_HOST:-}
port=${SMTP_PORT:-587}
tls=${SMTP_TLS:-starttls}
from=${MAIL_FROM:-${SMTP_USER:-}}

if [ "${1:-}" = "--test" ]; then
    subject="[acme-rollout] Testmail"
    body="Diese Testmail kommt von acme-rollout.
Host: $(hostname)
Zeit: $(date)"
else
    if [ $# -lt 1 ]; then
        echo "Aufruf: $0 <betreff> (Body auf stdin) | $0 --test" >&2
        exit 1
    fi
    subject=$1
    body=$(cat)
fi

if [ -z "$to" ]; then
    echo "notify: ALERT_EMAIL fehlt, Meldung nur im Log" >&2
    printf '%s\n' "$body" >&2
    exit 1
fi
if [ -z "$host" ]; then
    echo "notify: SMTP_HOST fehlt, Meldung nur im Log (siehe .env)" >&2
    printf '%s\n' "$body" >&2
    exit 1
fi
if [ -z "$from" ]; then
    echo "notify: MAIL_FROM oder SMTP_USER fehlt" >&2
    exit 1
fi

_msg=$(mktemp) || exit 1
trap 'rm -f "$_msg"' EXIT
{
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R 2>/dev/null || date)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=utf-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf '\n'
    printf '%s\n' "$body"
} > "$_msg"

_tls_opt=""
case "$tls" in
    smtps)
        _url="smtps://$host:$port"
        ;;
    none)
        _url="smtp://$host:$port"
        ;;
    *)
        _url="smtp://$host:$port"
        _tls_opt="--ssl-reqd"
        ;;
esac

set -- -fsS --max-time 30 $_tls_opt --url "$_url" \
    --mail-from "$from" --mail-rcpt "$to" --upload-file "$_msg"
if [ -n "${SMTP_USER:-}" ]; then
    set -- "$@" --user "$SMTP_USER:${SMTP_PASS:-}"
fi

if curl "$@"; then
    echo "notify: Mail an $to gesendet"
else
    echo "notify: Mailversand an $to fehlgeschlagen" >&2
    exit 1
fi
