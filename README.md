# acme-rollout

**Short:** Issue certificates with acme.sh and roll them out to many servers
over SSH.

**In detail:** One container renews the certificates every six hours. DNS-01
runs through a self-hosted [acme-dns](https://github.com/joohoi/acme-dns)
server, so no Cloudflare token is needed. After issuance a deploy hook copies
certificate, chain and key to the target hosts. There a small receiver validates
both, tests the web server configuration and restores the previous files if
anything fails. Missing or stale hosts are caught up daily; failures and
certificates close to expiry are mailed.

## Two repos, one path

`acme-rollout` is the issuing side. The receiving side lives in
[deploy-tool](https://github.com/Michi4/deploy-tool): the `acme-target` recipe
creates the `acmepush` user, the forced command and the sudoers rule that accept
a certificate bundle.

```
acme-rollout                          deploy-tool
acme.sh + deploy hook                 recipes/acme-target
        │                                     │
        │  issues and pushes                  │  installs the receiver
        └───────────────┐                     │
                        ▼                     ▼
                 ┌──────────────────────────────────┐
                 │ target host                      │
                 │ acmepush -> acme-target          │
                 │ /etc/ssl/<name>.{crt,key,ca}     │
                 └──────────────────────────────────┘
```

Both repos work on their own. Together they cover the path from issuance to the
file on the web server.

## Flow

- `scripts/acme-dns-register.sh` registers a domain with acme-dns and prints the
  CNAME that must be created in public DNS.
- `scripts/issue.sh` checks the CNAME and host keys, issues the certificate and
  calls the `deploy/fleet.sh` hook.
- The hook copies `cert.pem`, `chain.pem` and `privkey.pem` over SSH to
  `/etc/ssl/<name>.{crt,key,ca}` (path configurable, see below). The receiver
  validates certificate and key, tests the web server and restores the old
  files on failure.
- `scripts/deploy.sh` rolls out an existing certificate again without reissuing
  it.
- After every round `deploy/sync.sh` runs: the last successful deploy per
  certificate and host is stored in `acme/deploy-state/`. Only hosts that have
  never been deployed to, whose certificate is newer than their last deploy, or
  whose last success is older than `DEPLOY_SYNC_AGE` (default 24 h) are pushed
  again. A failed host is retried after 6 h, 12 h and then daily.
- If something is left over in a round, or a certificate expires in less than
  21 days, a mail goes to `ALERT_EMAIL`.

## Requirements

- Docker with Compose
- an acme-dns server with `POST /register` and `POST /update`
- on every target host: the `acmepush` user, `acme-target` as forced command
  and a pinned host key. The `acme-target` recipe from
  [deploy-tool](https://github.com/Michi4/deploy-tool) installs that.

## Setup

First replace the example hosts in `config/groups/*.txt` with your own. Then:

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env

ssh-keygen -t ed25519 -N '' -C acme-rollout -f keys/acme_ed25519
./scripts/known-hosts.sh
docker compose up -d --build
```

`ACMEDNS_BASE_URL` ships as a safe default in the image and can be overridden in
`.env`. `.env`, `keys/`, `acme/`, `config/acme-dns/` and `config/known_hosts`
are excluded from Git.

For alerts, set in `.env`:

```
ALERT_EMAIL=ops@example.com
SMTP_HOST=mail.example.com
SMTP_PORT=587
SMTP_USER=acme@example.com
SMTP_PASS=...
MAIL_FROM=acme@example.com
```

`SMTP_TLS` is `starttls` (port 587), `smtps` (port 465) or `none`. Without
`SMTP_HOST` the report is only written to the container log and retried next
round; operation continues. Test:

```bash
docker compose run --rm --entrypoint sh acme /data/deploy/notify.sh --test
```

### Postfix on the host

The container cannot run the host's `sendmail` (Alpine, no Postfix binary). It
can hand the mail to the host MTA instead:

```
NOTIFY_BACKEND=postfix
```

Mail then goes to `host.docker.internal:25`, without TLS or login; the sender is
`acme-rollout@<domain of ALERT_EMAIL>`. The name is mapped to the host gateway
in the compose file. Postfix must accept relay from the Docker network:

```bash
docker network inspect acme-rollout_default \
    -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
# e.g. 172.18.0.0/16

# /etc/postfix/main.cf
mynetworks = 127.0.0.0/8 172.18.0.0/16
inet_interfaces = all
```

Then `postfix reload`. `inet_interfaces = all` is the Debian/Ubuntu default; if
Postfix is publicly reachable, restrict port 25 at the firewall to the Docker
subnets. `NOTIFY_BACKEND=smtp` (the default) keeps using the values above.

## First certificate

```bash
./scripts/issue.sh '*.example.com' web
```

On the first run the domain is registered and the CNAME is printed:

```
_acme-challenge.example.com.  CNAME  <id>.auth.example.com.
```

Create that CNAME in public DNS (DNS only, not proxied), wait a moment and run
the command again. Renewal is automatic from then on. A wildcard certificate
also covers the domain without `*.`.

`issue.sh` aborts beforehand if the CNAME does not point at the acme-dns slot,
or if a target host has no entry in `config/known_hosts`. `SKIP_PREFLIGHT=1`
skips both checks.

More flags:

```bash
./scripts/issue.sh --staging example.net web       # Let's Encrypt staging
./scripts/issue.sh --force example.net web         # reissue
./scripts/issue.sh --force --keylength ec-256 example.net web
```

`--force` is required to reissue an existing certificate, for example for a new
SAN list or a switch to ECC. For SANs, issue directly with acme.sh using
`--force` and the additional `--domain` arguments, then run
`./scripts/deploy.sh`.

## Groups and targets

```
config/groups/web.txt    example group
config/groups/edge.txt   example group
```

One target per line, either `host` or `host:port`. `issue.sh` and `deploy.sh`
accept a group name, `all` or a comma-separated list:

```bash
./scripts/issue.sh '*.example.com' web
./scripts/issue.sh example.net web1.example.com,web2.example.com
./scripts/deploy.sh example.net web            # roll out only
```

A group is read on every renewal and every sync. New hosts get the certificate
on the next sync run, at most about six hours later - not at the next renewal.
`./scripts/deploy.sh` is immediate. For a new host:

```bash
# on the admin machine, with deploy-tool
./deploy.py deploy -r acme-target -p example-acme

# on the certificate host
# add the new host to config/groups/web.txt
./scripts/known-hosts.sh
./scripts/deploy.sh '*.example.com' web
```

The sync catches the host up on its own otherwise. The first run after this
update knows no deploy state and therefore pushes every host once; that is the
simplest way to verify the whole chain.

## Certificate names and target path

- `*.example.com` -> `/etc/ssl/wildcard.example.com.{crt,key,ca}` (also covers
  `example.com`)
- otherwise -> `/etc/ssl/<domain>.{crt,key,ca}`
- different: set `DEPLOY_NAME`.

An exact certificate only covers that name. Use the wildcard certificate for
subdomains.

The directory is configurable with `DEPLOY_PATH` (default `/etc/ssl`). The
receiver must accept the optional second `install` argument; the hook only sends
it when `DEPLOY_PATH` is set:

```
DEPLOY_PATH=/srv/tls
```

Matching Apache configuration per host (the three files the receiver writes):

```apache
<VirtualHost *:443>
    SSLEngine on
    SSLCertificateFile      /etc/ssl/wildcard.example.com.crt
    SSLCertificateKeyFile   /etc/ssl/wildcard.example.com.key
    SSLCertificateChainFile /etc/ssl/wildcard.example.com.ca
</VirtualHost>
```

Reloading the web server belongs to the receiver (`acme-target`), not to this
repo.

## Operation

```bash
docker compose logs --tail=50 acme
docker compose run --rm acme --list
docker compose run --rm acme --renew --domain '*.example.com'
```

Run without arguments, the container loops: renew each domain, sync, expiry
check, alert. `ACME_INTERVAL` changes the interval (default 21600 seconds);
`ACME_CYCLES=1` runs exactly one round and is handy for debugging. The json-file
logs are capped at 3 x 10 MB.

Removing a certificate:

```bash
./scripts/remove.sh '*.example.com'            # stop renewing
./scripts/remove.sh '*.example.com' --revoke   # revoke first
```

Files on the target hosts and the CNAME in public DNS stay in place and must be
removed by hand if needed.

## Monitoring

A mail goes out when

- a renewal fails,
- the deploy sync fails for a host,
- a certificate is missing, unreadable or expires in less than
  `EXPIRY_WARN_DAYS` (default 21) days.

The report contains the affected domains and the last lines of acme.sh output.
An unchanged report is repeated at most every `ALERT_EVERY` seconds (default
86400); a new error mails immediately.

## Updating acme.sh

The `Dockerfile` pins the version and both SHA256 checksums. A moved GitHub tag
therefore fails the build. To fetch a new version:

```bash
./scripts/bump-acme.sh
docker compose up -d --build
```

## Security

- The deploy key lives only on the certificate host; `from=` in
  `authorized_keys` restricts it to that host's IP.
- Host keys are pinned (`StrictHostKeyChecking=yes`).
- `acme-target` writes only below `/etc/ssl` and validates before reloading.
- No credentials in the repo: `.env`, `keys/`, `config/acme-dns/`.
- All acme.sh invocations share one lock (`/data/.acme.lock`), so a manual run
  cannot collide with the loop.

## Layout

```
docker-compose.yml          one service: acme
Dockerfile                  acme.sh + acme-dns plugin, version and sums pinned
entrypoint.sh               cycle: renew, sync, expiry check, alert
deploy/fleet.sh             deploy hook, parallel rollout per host
deploy/sync.sh              catch up missing or stale hosts
deploy/notify.sh            alert mail over SMTP
deploy/lib.sh               shared helpers (targets, deploy state)
config/groups/*.txt         target groups
config/known_hosts          pinned host keys (generated)
config/acme-dns/            acme-dns credentials (generated, secret)
keys/acme_ed25519           SSH deploy key (secret)
acme/                       acme.sh home and deploy state
scripts/issue.sh            issue and roll out
scripts/deploy.sh           roll out only
scripts/preflight.sh        CNAME and host key checks (internal)
scripts/hosts.sh            group -> host list
scripts/target.sh           resolve target (internal)
scripts/remove.sh           stop renewal, optionally revoke
scripts/bump-acme.sh        update acme.sh version and checksums
scripts/acme-dns-register.sh
scripts/known-hosts.sh
```
