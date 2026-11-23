# acme-rollout

**Kurz:** Zertifikate mit acme.sh ausstellen und per SSH auf viele Server
ausrollen.

**Im Detail:** Ein Container erneuert die Zertifikate alle sechs Stunden.
DNS-01 laeuft ueber einen eigenen [acme-dns](https://github.com/joohoi/acme-dns)-Server,
ein Cloudflare-Token wird nicht gebraucht. Nach der Ausstellung kopiert ein
Deploy-Hook Zertifikat, Kette und Key auf die Zielhosts. Dort prueft ein kleiner
Empfaenger beides, testet die Webserver-Konfiguration und rollt bei einem Fehler
die alten Dateien zurueck. Fehlende oder veraltete Hosts werden taeglich
nachgezogen, Fehler und bald ablaufende Zertifikate gehen per Mail raus.

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
- `scripts/issue.sh` prueft CNAME und Hostkeys, stellt das Zertifikat aus und
  ruft den Hook `deploy/fleet.sh` auf.
- Der Hook kopiert `cert.pem`, `chain.pem` und `privkey.pem` per SSH nach
  `/etc/ssl/<name>.{crt,key,ca}` (Pfad anpassbar, siehe unten). Der Empfaenger
  validiert Zertifikat und Key, testet den Webserver und stellt bei einem
  Fehler die alten Dateien wieder her.
- `scripts/deploy.sh` rollt ein vorhandenes Zertifikat erneut aus, ohne es neu
  auszustellen.
- Nach jeder Runde laeuft `deploy/sync.sh`: pro Zertifikat und Host steht der
  letzte erfolgreiche Deploy in `acme/deploy-state/`. Neu bespielt werden nur
  Hosts, die noch nie erfolgreich beliefert wurden, deren Zertifikat neuer ist
  als ihr letzter Deploy oder deren letzter Erfolg aelter als
  `DEPLOY_SYNC_AGE` (Standard 24 h) ist. Ein fehlgeschlagener Host wird nach
  6 h, 12 h und danach taeglich erneut versucht.
- Bleibt in einer Runde etwas liegen oder laeuft ein Zertifikat in weniger als
  21 Tagen ab, geht eine Mail an `ALERT_EMAIL`.

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

Fuer Alarme in `.env` setzen:

```
ALERT_EMAIL=ops@example.com
SMTP_HOST=mail.example.com
SMTP_PORT=587
SMTP_USER=acme@example.com
SMTP_PASS=...
MAIL_FROM=acme@example.com
```

`SMTP_TLS` ist `starttls` (Port 587), `smtps` (Port 465) oder `none`. Fehlt
`SMTP_HOST`, wird die Meldung nur ins Container-Log geschrieben und in der
naechsten Runde erneut versucht; der Betrieb laeuft weiter. Test:

```bash
docker compose run --rm --entrypoint sh acme /data/deploy/notify.sh --test
```

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

`issue.sh` bricht vorher ab, wenn der CNAME nicht auf den acme-dns-Slot zeigt
oder ein Zielhost keinen Eintrag in `config/known_hosts` hat. Mit
`SKIP_PREFLIGHT=1` laesst sich beides ueberspringen.

Weitere Flaggen:

```bash
./scripts/issue.sh --staging example.net web       # Let's Encrypt Staging
./scripts/issue.sh --force example.net web         # neu ausstellen
./scripts/issue.sh --force --keylength ec-256 example.net web
```

`--force` ist noetig, um ein bestehendes Zertifikat neu auszustellen, z. B. fuer
eine neue SAN-Liste oder den Wechsel auf ECC. Fuer SANs das Zertifikat mit
`--force` und den zusaetzlichen `--domain`-Argumenten direkt mit acme.sh
ausstellen und danach `./scripts/deploy.sh` laufen lassen.

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

Eine Gruppe wird bei jeder Erneuerung und bei jedem Sync neu gelesen. Neue
Hosts bekommen das Zertifikat beim naechsten Sync-Lauf, also spaetestens nach
rund sechs Stunden - nicht erst bei der naechsten Erneuerung. Sofort geht es mit
`./scripts/deploy.sh`. Fuer einen neuen Host also:

```bash
# auf dem Admin-Rechner, mit deploy-tool
./deploy.py deploy -r acme-target -p example-acme

# auf dem Zertifikats-Host
# neuen Host in config/groups/web.txt eintragen
./scripts/known-hosts.sh
./scripts/deploy.sh '*.example.com' web
```

Der Sync holt den Host sonst von selbst nach. Der erste Lauf nach diesem Update
kennt noch keinen Deploy-Status und bespielt deshalb jeden Host einmal neu; das
ist der einfachste Weg, den Zustand zu verifizieren.

## Zertifikatsnamen und Zielpfad

- `*.example.com` -> `/etc/ssl/wildcard.example.com.{crt,key,ca}` (deckt auch
  `example.com` ab)
- sonst -> `/etc/ssl/<domain>.{crt,key,ca}`
- abweichend: `DEPLOY_NAME` setzen.

Ein exaktes Zertifikat deckt nur diesen Namen ab. Fuer Subdomains das
Wildcard-Zertifikat nehmen.

Das Verzeichnis ist mit `DEPLOY_PATH` aenderbar (Standard `/etc/ssl`). Der
Empfaenger muss dafuer das optionale zweite Argument von `install` verstehen;
der Hook schickt es nur, wenn `DEPLOY_PATH` gesetzt ist:

```
DEPLOY_PATH=/srv/tls
```

Passende Apache-Konfiguration pro Host (die drei Dateien, die der Empfaenger
schreibt):

```apache
<VirtualHost *:443>
    SSLEngine on
    SSLCertificateFile      /etc/ssl/wildcard.example.com.crt
    SSLCertificateKeyFile   /etc/ssl/wildcard.example.com.key
    SSLCertificateChainFile /etc/ssl/wildcard.example.com.ca
</VirtualHost>
```

Der Reload des Webservers gehoert zum Empfaenger (`acme-target`), nicht zu
diesem Repo.

## Betrieb

```bash
docker compose logs --tail=50 acme
docker compose run --rm acme --list
docker compose run --rm acme --renew --domain '*.example.com'
```

Der Container laeuft ohne Argumente in einer Schleife: jede Domain einzeln
erneuern, Sync, Ablaufpruefung, Alarm. Mit `ACME_INTERVAL` laesst sich der
Abstand aendern (Standard 21600 Sekunden), `ACME_CYCLES=1` macht genau eine
Runde und ist beim Debuggen praktisch. Die json-file-Logs sind auf 3 x 10 MB
begrenzt.

Ein Zertifikat stilllegen:

```bash
./scripts/remove.sh '*.example.com'            # nur nicht mehr erneuern
./scripts/remove.sh '*.example.com' --revoke   # vorher widerrufen
```

Dateien auf den Zielhosts und der CNAME im oeffentlichen DNS bleiben dabei
stehen und muessen bei Bedarf von Hand entfernt werden.

## Ueberwachung

Eine Mail geht raus, wenn

- eine Erneuerung fehlschlaegt,
- der Deploy-Sync fuer einen Host fehlschlaegt,
- ein Zertifikat fehlt, nicht lesbar ist oder in weniger als
  `EXPIRY_WARN_DAYS` (Standard 21) Tagen ablaueft.

Die Meldung enthaelt die betroffenen Domains und die letzten Zeilen der
acme.sh-Ausgabe. Eine unveraenderte Meldung wird hoechstens alle
`ALERT_EVERY` Sekunden (Standard 86400) wiederholt; kommt ein neuer Fehler
dazu, geht sofort eine Mail raus.

## acme.sh aktualisieren

`Dockerfile` pinnt Version und SHA256-Summen beider Downloads. Ein bewegter
GitHub-Tag faellt damit beim Build auf. Neue Version holen:

```bash
./scripts/bump-acme.sh
docker compose up -d --build
```

## Sicherheit

- Der Deploy-Key liegt nur auf dem Zertifikats-Host; `from=` in
  `authorized_keys` beschraenkt ihn auf dessen IP.
- Hostkeys sind gepinnt (`StrictHostKeyChecking=yes`).
- `acme-target` schreibt ausschliesslich nach `/etc/ssl` und validiert vor dem
  Reload.
- Keine Zugangsdaten im Repo: `.env`, `keys/`, `config/acme-dns/`.
- Alle acme.sh-Aufrufe teilen sich ein Lock (`/data/.acme.lock`), damit ein
  manueller Lauf nicht mit der Schleife kollidiert.

## Layout

```
docker-compose.yml          ein Dienst: acme
Dockerfile                  acme.sh + acme-dns-Plugin, Version und Summen gepinnt
entrypoint.sh               Zyklus: renew, sync, Ablaufpruefung, Alarm
deploy/fleet.sh             Deploy-Hook, paralleler Rollout pro Host
deploy/sync.sh              fehlende/veraltete Hosts nachziehen
deploy/notify.sh            Alarm-Mail per SMTP
deploy/lib.sh               gemeinsame Helfer (Ziele, Deploy-Status)
config/groups/*.txt         Zielgruppen
config/known_hosts          gepinnte Hostkeys (erzeugt)
config/acme-dns/            acme-dns-Zugangsdaten (erzeugt, geheim)
keys/acme_ed25519           SSH-Deploy-Key (geheim)
acme/                       acme.sh-Home und Deploy-Status
scripts/issue.sh            ausstellen + ausrollen
scripts/deploy.sh           nur ausrollen
scripts/preflight.sh        CNAME- und Hostkey-Pruefung (intern)
scripts/hosts.sh            Gruppe -> Hostliste
scripts/target.sh           Ziel aufloesen (intern)
scripts/remove.sh           Erneuerung stoppen, optional widerrufen
scripts/bump-acme.sh        acme.sh-Version und Summen aktualisieren
scripts/acme-dns-register.sh
scripts/known-hosts.sh
```
