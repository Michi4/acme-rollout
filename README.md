# acme-rollout

**Short:** Issue certificates with acme.sh and roll them out to many servers
over SSH.

**In detail:** One container checks the certificates every six hours and renews
them only when acme.sh reports them due, about 30 days before expiry. DNS-01
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
  v2 accepts exactly those three regular files, validates certificate and key,
  tests the web server and restores the old files on failure. Existing
  `<name>.crtca`, `<name>.keycrtca` and `<name>.pem` companions are refreshed;
  `.key`, `.pem` and `.keycrtca` are forced to `0600`.
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
- on every target host: the `acmepush` user, `acme-target` v2 as forced
  command, `/etc/acme-target.dirs` and a pinned host key. The `acme-target`
  recipe from [deploy-tool](https://github.com/Michi4/deploy-tool) installs
  that.

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
in the compose file, so the container reaches the host even though it has its
own network namespace. Postfix must accept relay from the Docker network.

Find the subnet first; do not guess it, Docker picks it when the network is
created:

```bash
docker network inspect acme-rollout_default \
    -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
# e.g. 172.18.0.0/16
```

Then add it to the host's `/etc/postfix/main.cf`:

```
# /etc/postfix/main.cf
mynetworks = 127.0.0.0/8 172.18.0.0/16
inet_interfaces = all
```

`postfix reload` applies both without dropping connections. `inet_interfaces =
all` is the Debian/Ubuntu default; with `loopback-only` the host gateway is not
reachable from the container and every alert fails with "connection refused".

`mynetworks` is a relay permission, not authentication: every client in those
subnets may send mail through the host. Port 25 is then reachable from the
Docker subnets. If the host is publicly reachable, restrict port 25 at the
firewall to the Docker subnets (and localhost) instead of opening it to the
internet. After `docker compose down` the network can come back with a different
subnet; re-run `docker network inspect` and update `mynetworks` if alerts stop
working.

Verify from the host:

```bash
postconf -n mynetworks inet_interfaces
ss -ltn 'sport = :25'          # must listen on 0.0.0.0, not only 127.0.0.1
journalctl -u postfix -n 50    # or /var/log/mail.log
```

A failed delivery leaves `connect to host.docker.internal[...]:25: Connection
refused` or `relay access denied` in the container log (`docker compose logs
acme`). `NOTIFY_BACKEND=smtp` (the default) keeps using the values above.

## Adding a certificate

Everything one certificate needs lives in `config/certs/<name>.conf`. One
command reads that file and does the rest, including waiting while you create
the DNS record:

```bash
./scripts/new-cert.sh config/certs/hahnenkamm.conf
```

No spec yet? The wizard asks, writes the file and continues:

```bash
./scripts/new-cert.sh --wizard
```

### The spec

```ini
domain=example.com                        # base domain, lowercase, no "*"
wildcard=1                                # 1: *.example.com and example.com
hosts=example.com web1.example.com        # host[:port], comma or space separated
group=example                             # default: example (first label)

# name=*.example.com                      # acme.sh certificate name
# deploy_name=wildcard.example.com        # file name on the target hosts
# deploy_path=/etc/ssl                    # directory on the target hosts
# keylength=2048                          # 3072, 4096, ec-256, ec-384, ec-521
# staging=0                               # 1: staging endpoint, no deploy
```

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `domain` | yes | - | base domain; the wildcard comes from `wildcard=` |
| `wildcard` | no | `1` | `1` covers `*.domain` and `domain`, `0` only `domain` |
| `hosts` | yes | - | rollout targets; becomes `config/groups/<group>.txt` |
| `group` | no | first label (`example` for `example.com`) | group name |
| `name` | no | `*.domain` / `domain` | acme.sh certificate name; only needed to adopt an existing certificate |
| `deploy_name` | no | `wildcard.<domain>` / `<domain>` | file name below the target directory |
| `deploy_path` | no | `/etc/ssl` | target directory, see "Certificate names and target path" |
| `keylength` | no | `2048` | `3072`, `4096`, `ec-256`, `ec-384`, `ec-521` |
| `staging` | no | `0` | `1` issues on staging and does not deploy |

An unknown key is an error, so a typo cannot silently fall back to a default.

### What the command does

1. validates the spec and warns about hosts the certificate does not cover
2. writes `config/groups/<group>.txt`; if the file exists and differs it shows
   the difference and asks (`--update-group` replaces it, `--keep-group` keeps
   it)
3. registers the acme-dns slot in `config/acme-dns/<domain>.env` (idempotent)
4. prints the CNAME and waits for it: create the record, press Enter, repeat
5. scans host keys that are still missing into `config/known_hosts`
6. runs `scripts/issue.sh '<certificate>' '<group>'`
7. prints subject, expiry and the deploy result

The certificate renews itself from then on, and hosts added to the spec follow
within one sync round. A group file that `new-cert.sh` wrote starts with a
header naming its certificate; edit the spec, not the file.

### Flags

```bash
./scripts/new-cert.sh --check example.com        # validate and print the plan only
./scripts/new-cert.sh --wizard                   # ask, write the spec, continue
./scripts/new-cert.sh --no-issue example.com     # prepare, stop before issuing
./scripts/new-cert.sh --wait 600 example.com     # poll the CNAME for 10 minutes
./scripts/new-cert.sh --staging example.com      # staging, no deploy
./scripts/new-cert.sh --force example.com        # reissue
./scripts/new-cert.sh --update-group example.com # spec hosts replace the group file
```

## First certificate

Manual path, step by step; `new-cert.sh` above runs all of it from one file.

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
if a target host has no entry in `config/known_hosts`, or if a target does not
answer through the forced command with the expected receiver version. It also
warns when a target already serves another certificate from the deploy state.
`SKIP_PREFLIGHT=1` skips all of these checks.

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
Never copy a group file for a new certificate without replacing the hosts: the
copied servers would receive the new certificate. `issue.sh` and `deploy.sh`
warn when a target already carries another certificate (see Troubleshooting).
A group that `new-cert.sh` wrote starts with a header naming its certificate;
that file is generated, so change the spec and run `new-cert.sh` again.
`./scripts/deploy.sh` is immediate. To drop one host from a certificate,
`./scripts/remove.sh <cert> --host <host>` edits the spec, the group and the
deploy state together. For a new host:

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
receiver v2 accepts the optional second `install` argument and checks it
against `/etc/acme-target.dirs`; the hook only sends it when `DEPLOY_PATH` is
set:

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
docker compose run --rm acme --locked --renew --domain '*.example.com'
```

Add `--locked` to manual acme.sh commands. The helper scripts already do, so a
manual run cannot collide with the loop.

Run without arguments, the container loops: renew each domain, sync, expiry
check, alert. `ACME_INTERVAL` changes the interval (default 21600 seconds);
`ACME_CYCLES=1` runs exactly one round and is handy for debugging. The json-file
logs are capped at 3 x 10 MB.

### Renewal timing

A round does not issue anything on its own: `--renew` without `--force` returns
immediately ("Skipping. Next renewal time is: ...") until the timestamp acme.sh
stored at issuance has passed. The default is 60 days after issuance - for a
90-day certificate that is about 30 days before expiry. The value lives in the
domain config as `Le_NextRenewTime` and is shown by:

```bash
docker compose run --rm acme --locked --info -d '*.example.com'
```

The six-hour interval therefore only decides how late the first attempt may
start (at most six hours), never how much time is left. A failed attempt is
retried every round, which puts roughly 120 attempts into the 30-day window
before expiry; the `EXPIRY_WARN_DAYS` warning is the safety net behind them.
Sleeping until the exact timestamp instead would be tighter, but a clock jump,
a suspend or a restart at that moment would skip the window, and the retry and
drift checks would lose their rhythm. Polling a stored due date is what
certbot's timer and acme.sh's own cron entry do as well.

Removing a certificate:

```bash
./scripts/remove.sh '*.example.com' --check          # show the plan, change nothing
./scripts/remove.sh '*.example.com'                  # stop renewing, clean up
./scripts/remove.sh '*.example.com' --revoke         # revoke first
./scripts/remove.sh config/certs/example.conf        # take the name from the spec
./scripts/remove.sh example.com --host web2.example.com   # one host only
```

What goes with the certificate:

- every spec in `config/certs` that describes it, found by the `domain`,
  `wildcard` and `name` keys rather than by the file name. `--keep-spec` keeps
  them. Because specs are not in git, a deleted one is copied to
  `acme/removed-specs/<name>.conf.<timestamp>` first.
- the group file, but only when `new-cert.sh` generated it for this certificate
  and no other spec uses the same group (`--keep-group` keeps it regardless).
- the deploy state of every host, so the sync stops considering it.
- `config/acme-dns/<domain>.env` only with `--purge-dns`. The slot itself stays
  registered at acme-dns; the credentials are reusable if the certificate comes
  back.

A failed `--revoke` keeps the spec: the certificate is still valid on every
host, and the spec is the only place that still tracks it. Renewal stops either
way.

`--host` edits the spec, removes the host from that group and deletes its
entries in the deploy state, so the next sync no longer pushes to it. Files that
are already on that host stay there.

Files on the target hosts and the CNAME in public DNS are always left alone;
remove them by hand when a certificate is retired for good.

## Checking the setup

`./scripts/status.sh` cross-checks the pieces that are supposed to agree and
prints one line per finding:

- spec without certificate, certificate without spec
- missing group file, group file whose certificate no longer exists
- hosts the certificate does not cover, missing host keys
- hosts that were never deployed, deploy state for a removed certificate
- acme-dns credentials nobody uses

It is read-only and exits 1 when it finds something, so it fits a cron job or a
CI step. `--quiet` prints only problems and the summary. Run it after editing a
spec by hand, and before blaming DNS.

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

## Tests

```bash
sh tests/run.sh
```

The tests run against a throwaway copy of the repository with stubbed `docker`,
`ssh`, `dig` and `ssh-keygen`: no network, no container, no host keys. They
cover the spec parser, `remove.sh`, the preflight conflict warning, the deploy
hook (stored group, `DEPLOY_ONLY`, environment precedence) and `status.sh`.

## Configuration reference

All values are optional; `ALERT_EMAIL` is required for mail, and `SMTP_HOST`
too unless you use the postfix backend. They are read from `.env` (Compose
`env_file`) and from the environment.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ACMEDNS_BASE_URL` | `https://auth.example.com` | acme-dns endpoint; the image ships this default |
| `ACME_INTERVAL` | `21600` | seconds between renewal rounds |
| `ACME_CYCLES` | `0` | `0` runs forever, `1` runs one round |
| `ALERT_EVERY` | `86400` | repeat an unchanged report at most this often |
| `EXPIRY_WARN_DAYS` | `21` | warn when a certificate expires within this many days |
| `DEPLOY_GROUP` | - | group from `config/groups/<name>.txt`, or `all` |
| `DEPLOY_HOSTS` | - | `host1 host2 host3:2222`, space or comma separated |
| `DEPLOY_USER` | `acmepush` | SSH user on the target hosts |
| `DEPLOY_NAME` | `wildcard.<domain>` / `<domain>` | file name below the target directory |
| `DEPLOY_PATH` | `/etc/ssl` | target directory; receiver v2 checks it against `/etc/acme-target.dirs` |
| `DEPLOY_PARALLEL` | `4` | concurrent SSH connections, capped at 16 |
| `DEPLOY_SYNC_AGE` | `86400` | re-push a host after this many seconds without a successful deploy |
| `DEPLOY_SYNC_RETRY` | `21600` | first retry after a failed deploy, doubled per failure |
| `DEPLOY_SYNC_MAX_RETRY` | `86400` | upper bound for that backoff |
| `NOTIFY_BACKEND` | `smtp` | `smtp` (relay via `SMTP_HOST`) or `postfix` (host MTA) |
| `ALERT_EMAIL` | - | recipient; without it the report only goes to the log |
| `SMTP_HOST` | - | SMTP relay; without it the report only goes to the log |
| `SMTP_PORT` | `587` (`25` for postfix) | SMTP port |
| `SMTP_TLS` | `starttls` | `starttls`, `smtps` or `none` |
| `SMTP_USER`, `SMTP_PASS` | - | SMTP login; only sent with the `smtp` backend |
| `MAIL_FROM` | `acme-rollout@<recipient domain>` | envelope sender |
| `SKIP_PREFLIGHT` | `0` | `1` skips the preflight checks: CNAME, host keys, receiver answer, certificate conflicts |

`DEPLOY_GROUP`, `DEPLOY_HOSTS`, `DEPLOY_USER`, `DEPLOY_NAME` and `DEPLOY_PATH`
are stored per certificate in the acme.sh domain config. Setting one in the
environment for a single run overrides the stored value without changing it;
`issue.sh`, `deploy.sh` and the sync pass the resolved group and host list
explicitly, and `issue.sh` and `deploy.sh` forward `DEPLOY_NAME`, `DEPLOY_PATH`
and `DEPLOY_USER` when they are set. `new-cert.sh` sets them from the spec.

The acme-dns credentials (`ACMEDNS_USERNAME`, `ACMEDNS_PASSWORD`,
`ACMEDNS_SUBDOMAIN`, `ACMEDNS_FULLDOMAIN`) are not set in `.env`; they live in
`config/acme-dns/<domain>.env`, created by `acme-dns-register.sh`.

Internal settings, set by the image or Compose and normally not touched:
`ACME_HOME` (`/data`), `ACME_LOCK` (`/data/.acme.lock`), `ACME_DEPLOY_DIR`
(`/data/deploy`), `DEPLOY_ONLY` (sync), `DEPLOY_KEY` (`/keys/acme_ed25519`),
`DEPLOY_KNOWN_HOSTS` (`/config/known_hosts`), `DEPLOY_GROUPS_DIR`
(`/config/groups`).

## Troubleshooting

Start here:

```bash
docker compose ps
docker compose logs --tail=100 acme
docker compose run --rm acme --list
```

### Alerts do not arrive

1. Run the built-in test (see Setup). It prints `mail to ... sent` on success.
2. `ALERT_EMAIL missing` or `SMTP_HOST missing`: one of the two required values
   is not set. With the postfix backend only `ALERT_EMAIL` is required.
3. With `NOTIFY_BACKEND=postfix`, work through "Postfix on the host": the most
   common causes are a missing `mynetworks` entry, `inet_interfaces =
   loopback-only`, and a firewall on port 25.
4. If the test works but problem mails are missing: an unchanged report is only
   repeated every `ALERT_EVERY` seconds. `alert: same report` in the log is
   expected, not an error.

### One host keeps failing

The state per certificate and host lives in
`acme/deploy-state/<slug>/<host>_<port>` on the host (`/data/deploy-state/...`
in the container): last success, last attempt, consecutive failures.

```bash
cat acme/deploy-state/wildcard.example.com/web1.example.com_22
# 1764000000 1764000000 0
```

A failed host is retried after 6 h, 12 h and then daily. To force it now, delete
its state file and run `./scripts/deploy.sh '<domain>' <group>`; a missing state
file counts as "never deployed" and runs immediately.

Check the receiver directly:

```bash
ssh -i keys/acme_ed25519 -p 22 \
    -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=config/known_hosts \
    -o StrictHostKeyChecking=yes \
    acmepush@web1.example.com status
```

If `known_hosts` still has an entry from before a reinstall, replace it with
`./scripts/known-hosts.sh` and retry. The receiver validates certificate and
key before installing, so a mismatched pair or a failed web server test leaves
the old files in place; its output is in the round's log and in the alert mail.

### A host carries the wrong certificate

`issue.sh` and `deploy.sh` compare the chosen hosts with `acme/deploy-state/`
and warn when a host was already deployed successfully with a different
certificate:

```
WARN: web1.example.com already serves *.example.org (deploy state acme/deploy-state/wildcard.example.org/web1.example.com_22)
WARN: *.example.com would be deployed next to those certificates.
WARN: check config/groups (a copied group file?) so no host gets the wrong one.
```

The usual cause is a group file that was copied from another certificate and
still lists its servers. Fix `config/groups/<name>.txt` and run again; the
warning is not fatal. A host that legitimately carries two certificates (an
exact and a wildcard one, for example) triggers the same lines on every manual
run. The sync does not run this check, so it never blocks a scheduled round.

### "is not a cert name"

`deploy.sh` (acme.sh `--deploy`) only rolls out a certificate that exists.
`acme-dns-register.sh` merely registers the DNS slot; for a new domain the
first step is

```bash
./scripts/issue.sh '*.example.com' web
```

which issues the certificate and deploys it to the target group in one go.
`deploy.sh` is for repeating that rollout later.

### new-cert.sh stops at the DNS step

It printed the CNAME and waits for it to become visible. Create the record as
printed (`DNS only`, not proxied), then press Enter. With `--wait 600` it polls
for ten minutes instead of asking, which is what a non-interactive run needs.
A CNAME that exists but resolves elsewhere is shown as the current answer; the
usual causes are a typo, a proxied record or a second record for the same name.

### new-cert.sh refuses because the group file differs

The spec is the source of truth for `config/groups/<group>.txt`, but the file
may have been edited by hand. `--update-group` replaces it with the spec hosts,
`--keep-group` leaves it alone. Both print the difference first.

### `error: no target servers (DEPLOY_GROUP/DEPLOY_HOSTS)`

The deploy hook reads the stored `SAVED_DEPLOY_GROUP` and `SAVED_DEPLOY_HOSTS`
from the certificate's domain config (`acme/<cert>/<cert>.conf`) and resolves
the group file on every call. The message means one of three things:

- the group named in the config no longer exists (`config/groups/<group>.txt`),
- neither a group nor a host list is stored,
- the certificate was never deployed through these scripts, so nothing is stored
  yet.

One deploy through the normal path stores both values:

```bash
./scripts/deploy.sh '*.example.com' web
```

The sync limit the damage on its own: when the group file is missing it still
pushes the host it asked for and logs `deploying the requested host only`. That
covers a half-finished edit; a missing group is still worth fixing.

### CNAME check fails

`dig +short CNAME _acme-challenge.example.com` must show the slot from
`config/acme-dns/example.com.env` (`ACMEDNS_FULLDOMAIN`). DNS changes can take a
minute. `SKIP_PREFLIGHT=1 ./scripts/issue.sh ...` bypasses the check, but Let's
Encrypt still has to see the record.

### Renewal fails

Run the domain alone with debug output:

```bash
docker compose run --rm acme --locked --renew --domain '*.example.com' --debug 2
```

The usual causes are a CNAME that no longer points at acme-dns, credentials in
`config/acme-dns/<domain>.env` that no longer work, or a rate limit at Let's
Encrypt (use `./scripts/issue.sh --staging` for tests).

### A manual run seems to hang

All scripts and the loop take `/data/.acme.lock`, so a manual `--locked` run
waits for the current one instead of colliding with it. The lock belongs to the
process; if a run was killed, it is released with the process. Use `--locked`
for manual renewals and deploys.

## Security

- The deploy key lives only on the certificate host; `from=` in
  `authorized_keys` restricts it to that host's IP.
- Host keys are pinned (`StrictHostKeyChecking=yes`).
- `acme-target` writes only below directories listed in `/etc/acme-target.dirs`
(default `/etc/ssl`) and validates before reloading.
- No credentials in the repo: `.env`, `keys/`, `config/acme-dns/`.
- The loop and the helper scripts take one lock (`/data/.acme.lock`). Use
  `acme --locked ...` for manual renewals so they cannot collide either.

## Layout

```
docker-compose.yml          one service: acme
Dockerfile                  acme.sh + acme-dns plugin, version and sums pinned
entrypoint.sh               cycle: renew, sync, expiry check, alert
deploy/fleet.sh             deploy hook, parallel rollout per host
deploy/sync.sh              catch up missing or stale hosts
deploy/notify.sh            alert mail over SMTP
  deploy/healthcheck.sh       heartbeat for the renewal loop
deploy/lib.sh               shared helpers (targets, deploy state)
config/groups/*.txt         target groups
config/certs/*.conf         one spec per certificate (see Adding a certificate)
config/known_hosts          pinned host keys (generated)
config/acme-dns/            acme-dns credentials (generated, secret)
keys/acme_ed25519           SSH deploy key (secret)
acme/                       acme.sh home and deploy state
scripts/new-cert.sh         spec -> group, acme-dns, DNS, issue, verify
scripts/issue.sh            issue and roll out
scripts/deploy.sh           roll out only
scripts/preflight.sh        CNAME, host key, receiver and conflict checks (internal)
scripts/hosts.sh            group -> host list
scripts/target.sh           resolve target (internal)
scripts/lib.sh              certificate name, slug and spec helpers (internal)
scripts/status.sh           cross-check specs, certs, groups, keys, state, DNS
scripts/remove.sh           stop renewal, drop its spec and group, optionally revoke
scripts/bump-acme.sh        update acme.sh version and checksums
tests/run.sh                offline regression tests
scripts/acme-dns-register.sh
scripts/known-hosts.sh
```
