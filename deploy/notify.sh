#!/bin/sh
# Send an alert mail.
#
#   printf 'text\n' | ./deploy/notify.sh "subject"
#   ./deploy/notify.sh --test
#
# NOTIFY_BACKEND=smtp     SMTP_HOST, SMTP_PORT, SMTP_TLS, SMTP_USER, SMTP_PASS
# NOTIFY_BACKEND=postfix  host MTA at host.docker.internal:25, no TLS or login
#
# Without ALERT_EMAIL or a delivery path nothing is sent; the report is written
# to the log with a warning instead. The cycle keeps running and retries next
# round.
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
        # The host relays the mail itself; the container cannot run its sendmail
        # but can speak SMTP to the host MTA.
        host=${host:-host.docker.internal}
        port=${port:-25}
        tls=${tls:-none}
        ;;
    *)
        echo "notify: invalid NOTIFY_BACKEND: $backend (smtp|postfix)" >&2
        exit 1
        ;;
esac

if [ "${1:-}" = "--test" ]; then
    subject="[acme-rollout] test mail"
    body="This test mail comes from acme-rollout.
Backend: $backend
Host: $(hostname)
Time: $(date)"
else
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <subject> (body on stdin) | $0 --test" >&2
        exit 1
    fi
    subject=$1
    body=$(cat)
fi

if [ -z "$to" ]; then
    echo "notify: ALERT_EMAIL missing, message only in the log" >&2
    printf '%s\n' "$body" >&2
    exit 1
fi
case "$to" in
    *@*) ;;
    *)
        echo "notify: invalid ALERT_EMAIL: $to" >&2
        exit 1
        ;;
esac
if [ -z "$host" ]; then
    echo "notify: SMTP_HOST missing, message only in the log (see .env)" >&2
    printf '%s\n' "$body" >&2
    exit 1
fi
if [ -z "$from" ]; then
    # Locally submitted mail does not need a real mailbox as sender.
    from="acme-rollout@${to#*@}"
fi

_msg=$(mktemp) || exit 1
trap 'rm -f "$_msg"' EXIT
{
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$to"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R 2>/dev/null || date)"
    printf 'Message-ID: <%s.%s@%s>\n' "$(date +%s)" "$$" "${from#*@}"
    printf 'Auto-Submitted: auto-generated\n'
    printf 'X-Mailer: acme-rollout\n'
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
# The local MTA accepts unauthenticated mail; login only in smtp mode.
if [ "$backend" = smtp ] && [ -n "${SMTP_USER:-}" ]; then
    set -- "$@" --user "$SMTP_USER:${SMTP_PASS:-}"
fi

if curl "$@"; then
    echo "notify: mail to $to sent ($backend)"
else
    echo "notify: sending mail to $to failed ($backend)" >&2
    exit 1
fi
