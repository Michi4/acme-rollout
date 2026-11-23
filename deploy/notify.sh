#!/bin/sh
# Eine Alarm-Mail verschicken.
#
#   printf 'Text\n' | ./deploy/notify.sh "Betreff"
#   ./deploy/notify.sh --test
#
# NOTIFY_BACKEND=smtp     SMTP_HOST, SMTP_PORT, SMTP_TLS, SMTP_USER, SMTP_PASS
# NOTIFY_BACKEND=postfix  Host-MTA ueber host.docker.internal:25, ohne TLS/Login
#
# Ohne ALERT_EMAIL oder ohne Versandweg wird nichts verschickt, sondern die
# Meldung mit einer Warnung ins Log geschrieben. Der Zyklus laeuft weiter und
# versucht es in der naechsten Runde erneut.
set -u

backend=${NOTIFY_BACKEND:-smtp}
to=${ALERT_EMAIL:-}
host=${SMTP_HOST:-}
port=${SMTP_PORT:-}
tls=${SMTP_TLS:-}
from=${MAIL_FROM:-}

case "$backend" in
    smtp)
        port=${port:-587}
        tls=${tls:-starttls}
        if [ -z "$from" ]; then
            from=${SMTP_USER:-}
        fi
        ;;
    postfix|local)
        # Der Host schickt die Mail selbst weiter; der Container kann dessen
        # sendmail nicht ausfuehren, spricht aber SMTP mit dem Host-MTA.
        host=${host:-host.docker.internal}
        port=${port:-25}
        tls=${tls:-none}
        ;;
    *)
        echo "notify: NOTIFY_BACKEND ungueltig: $backend (smtp|postfix)" >&2
        exit 1
        ;;
esac

if [ "${1:-}" = "--test" ]; then
    subject="[acme-rollout] Testmail"
    body="Diese Testmail kommt von acme-rollout.
Backend: $backend
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
case "$to" in
    *@*) ;;
    *)
        echo "notify: ALERT_EMAIL ungueltig: $to" >&2
        exit 1
        ;;
esac
if [ -z "$host" ]; then
    echo "notify: SMTP_HOST fehlt, Meldung nur im Log (siehe .env)" >&2
    printf '%s\n' "$body" >&2
    exit 1
fi
if [ -z "$from" ]; then
    # Lokal abgegebene Mail braucht keinen echten Postfach-Absender.
    from="acme-rollout@${to#*@}"
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
# Der lokale MTA nimmt unauthentifiziert an; Login nur im smtp-Modus.
if [ "$backend" = smtp ] && [ -n "${SMTP_USER:-}" ]; then
    set -- "$@" --user "$SMTP_USER:${SMTP_PASS:-}"
fi

if curl "$@"; then
    echo "notify: Mail an $to gesendet ($backend)"
else
    echo "notify: Mailversand an $to fehlgeschlagen ($backend)" >&2
    exit 1
fi
