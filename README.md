# acme-rollout

**Kurz:** Zertifikate mit acme.sh ausstellen und per SSH auf viele Server
ausrollen.

**Im Detail:** Ein Container erneuert die Zertifikate alle sechs Stunden.
DNS-01 laeuft ueber einen eigenen [acme-dns](https://github.com/joohoi/acme-dns)-Server,
ein Cloudflare-Token wird nicht gebraucht. Nach der Ausstellung kopiert ein
Deploy-Hook Zertifikat, Kette und Key auf die Zielhosts. Dort prueft ein kleiner
Empfaenger beides, testet die Webserver-Konfiguration und rollt bei einem Fehler
die alten Dateien zurueck.

## Zwei Repos, ein Weg

`acme-rollout` ist die Ausstellungsseite. Die Empfangsseite liegt in
[deploy-tool](https://github.com/Michi4/deploy-tool): Das Rezept `acme-target`
legt den Benutzer `acmepush`, den Forced Command und die Sudoers-Regel an, die
ein Zertifikats-Bundle annehmen.

```
acme-rollout                          deploy-tool
acme.sh + deploy hook                 recipes/acme-target
        │                                     │
        │  stellt aus und pusht               │  richtet Empfaenger ein
        └───────────────┐                     │
                        ▼                     ▼
                 ┌──────────────────────────────────┐
                 │ Zielhost                         │
                 │ acmepush -> acme-target          │
                 │ /etc/ssl/<name>.{crt,key,ca}     │
                 └──────────────────────────────────┘
```

Beide Repos funktionieren fuer sich. Zusammen ergeben sie den vollstaendigen
Weg von der Ausstellung bis zur Datei auf dem Webserver.

## Ablauf

- `scripts/acme-dns-register.sh` registriert eine Domain bei acme-dns und gibt
  den CNAME aus, der im oeffentlichen DNS angelegt werden muss.
- `scripts/issue.sh` stellt das Zertifikat aus und ruft den Hook
  `deploy/fleet.sh` auf.
- Der Hook kopiert `cert.pem`, `chain.pem` und `privkey.pem` per SSH nach
  `/etc/ssl/<name>.{crt,key,ca}`. Der Empfaenger validiert Zertifikat und Key,
  testet den Webserver und stellt bei einem Fehler die alten Dateien wieder her.
- `scripts/deploy.sh` rollt ein vorhandenes Zertifikat erneut aus, ohne es neu
  auszustellen.

## Voraussetzungen

- Docker mit Compose
- ein acme-dns-Server mit `POST /register` und `POST /update`
- auf jedem Zielhost: Benutzer `acmepush`, `acme-target` als Forced Command und
  ein gepinnter Hostkey. Das Rezept `acme-target` aus
  [deploy-tool](https://github.com/Michi4/deploy-tool) installiert das.

## Einrichten

Zuerst die Beispielhosts in `config/groups/*.txt` durch die eigenen ersetzen.
Dann:

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env

ssh-keygen -t ed25519 -N '' -C acme-rollout -f keys/acme_ed25519
./scripts/known-hosts.sh
docker compose up -d --build
```

`ACMEDNS_BASE_URL` steht als sicherer Standard im Image und kann in `.env`
ueberschrieben werden. `.env`, `keys/`, `acme/`, `config/acme-dns/` und
`config/known_hosts` sind von Git ausgeschlossen.

## Erstes Zertifikat

```bash
./scripts/issue.sh '*.example.com' web
```

Beim ersten Lauf wird die Domain registriert und der CNAME ausgegeben:

```
_acme-challenge.example.com.  CNAME  <id>.auth.example.com.
```

Diesen CNAME im oeffentlichen DNS anlegen (DNS only, nicht proxied), kurz warten
und den Befehl wiederholen. Danach laeuft die Erneuerung automatisch. Ein
Wildcard-Zertifikat deckt auch die Domain ohne `*.` ab.

## Gruppen und Ziele

```
config/groups/web.txt    Beispielgruppe
config/groups/edge.txt   Beispielgruppe
```

Eine Zeile pro Ziel, entweder `host` oder `host:port`. `issue.sh` und
`deploy.sh` akzeptieren einen Gruppennamen, `all` oder eine Kommastliste:

```bash
./scripts/issue.sh '*.example.com' web
./scripts/issue.sh example.net web1.example.com,web2.example.com
./scripts/deploy.sh example.net web            # nur ausrollen
```

Eine Gruppe wird bei jeder Erneuerung neu gelesen. Neue Hosts bekommen das
Zertifikat beim naechsten Lauf, sofern der Empfaenger installiert und der
Hostkey gepinnt ist. Fuer einen neuen Host also:

```bash
# auf dem Admin-Rechner, mit deploy-tool
./deploy.py deploy -r acme-target -p example-acme

# auf dem Zertifikats-Host
# neuen Host in config/groups/web.txt eintragen
./scripts/known-hosts.sh
./scripts/deploy.sh '*.example.com' web
```

## Zertifikatsnamen

- `*.example.com` -> `/etc/ssl/wildcard.example.com.{crt,key,ca}` (deckt auch
  `example.com` ab)
- sonst -> `/etc/ssl/<domain>.{crt,key,ca}`
- abweichend: `DEPLOY_NAME` setzen.

Ein exaktes Zertifikat deckt nur diesen Namen ab. Fuer Subdomains das
Wildcard-Zertifikat nehmen.

## Betrieb

```bash
docker compose logs --tail=50 acme
docker compose run --rm acme --list
docker compose run --rm acme --cron
```

Der Container ruft alle sechs Stunden `acme.sh --cron` auf. acme.sh speichert
DNS-Zugang, Deploy-Hook und Zielgruppe pro Zertifikat, mehrere Domains stoeren
sich daher nicht.

## Sicherheit

- Der Deploy-Key liegt nur auf dem Zertifikats-Host; `from=` in
  `authorized_keys` beschraenkt ihn auf dessen IP.
- Hostkeys sind gepinnt (`StrictHostKeyChecking=yes`).
- `acme-target` schreibt ausschliesslich nach `/etc/ssl` und validiert vor dem
  Reload.
- Keine Zugangsdaten im Repo: `.env`, `keys/`, `config/acme-dns/`.

## Layout

```
docker-compose.yml          ein Dienst: acme
Dockerfile                  acme.sh + acme-dns-Plugin, fester Endpunkt
entrypoint.sh               --cron-Schleife alle 6 Stunden
deploy/fleet.sh             Deploy-Hook
config/groups/*.txt         Zielgruppen
config/known_hosts          gepinnte Hostkeys (erzeugt)
config/acme-dns/            acme-dns-Zugangsdaten (erzeugt, geheim)
keys/acme_ed25519           SSH-Deploy-Key (geheim)
acme/                       acme.sh-Home
scripts/issue.sh            ausstellen + ausrollen
scripts/deploy.sh           nur ausrollen
scripts/hosts.sh            Gruppe -> Hostliste
scripts/target.sh           Ziel aufloesen (intern)
scripts/acme-dns-register.sh
scripts/known-hosts.sh
```
