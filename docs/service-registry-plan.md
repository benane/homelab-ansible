# Caddy, CrowdSec & Service-Registry – Umsetzungsplan

Lern- und Arbeitsdokument. Beschreibt **Schritt für Schritt**, wie NPM durch
Caddy ersetzt wird (inkl. DNS-Challenge und CrowdSec) und wie danach ein neuer
Dienst sich automatisch in Caddy, Pi-hole, cloudflared und Gatus einträgt.

Die Code-Schnipsel sind **Beispiele zum Verstehen**, keine fertigen Dateien.
Pfade, Namen und Versionen an deine Rollen anpassen.

Jede Phase endet mit **„Fertig, wenn …"** – erst dann zur nächsten.

---

## 0. Zielbild

```
                      ┌──────────── Internet ────────────┐
                      │                                  │
          Cloudflare-Tunnel                     Portforward 443
     (paperless, auth, status, …)                (nur jellyfin)
                      │                                  │
              cloudflared-a/-b                           │
              (172.16.10.212/214)                        │
                      │ HTTPS                            │
                      ▼                                  ▼
  LAN-Clients ──► ┌────────────────────────────────────────────┐
  (Pi-hole zeigt  │  Caddy (LXC 204, 172.16.10.204)             │
   alle Namen auf │  - Wildcard-Zertifikat *.ledermann.cc       │
   Caddy)         │  - Default-Deny für Nicht-LAN (außer public)│
                  │  - CrowdSec-Bouncer (Modul)                 │
                  └──────────────────┬─────────────────────────┘
                                     │ reverse_proxy
                                     ▼
                          Dienste (LXCs, Unraid)
```

Drei Arten von Diensten – das Feld `exposure` im Steckbrief:

| `exposure` | Pi-hole | Caddy | cloudflared + CF-DNS | Portforward |
|---|---|---|---|---|
| `intern` | ✅ | ✅ nur LAN | – | – |
| `tunnel` | ✅ | ✅ | ✅ | – |
| `public` | ✅ | ✅ auch von außen | – (A-Record, grau) | ✅ |

Merksatz: **Ob etwas von außen erreichbar ist, entscheidet das DNS bzw. der
Tunnel – nicht Caddy.** Caddy macht für alle dasselbe; die Default-Deny-Regel
ist nur das Sicherheitsnetz.

### Reihenfolge

| Phase | Inhalt | Status |
|---|---|---|
| 1 | Caddy-Binary mit Modulen bauen | ☐ |
| 2 | Caddy-Rolle umbauen (Binary statt apt) | ☐ |
| 3 | DNS-Challenge + Wildcard-Zertifikat | ☐ |
| 4 | Caddyfile-Grundgerüst (Default-Deny, Log, echte Client-IP) | ☐ |
| 5 | CrowdSec auf dem Caddy-Host | ☐ |
| 6 | Dienste von NPM auf Caddy umziehen | ☐ |
| 7 | Service-Registry: Steckbriefe + Caddy als erster Konsument | ☐ |
| 8 | Pi-hole als Konsument | ☐ |
| 9 | cloudflared + CF-DNS als Konsument | ☐ |
| 10 | Gatus als Konsument | ☐ |
| 11 | Ablauf „neuer Dienst" (Playbook-Kette) | ☐ |
| 12 | Jellyfin öffentlich (Portforward, CrowdSec-Agent auf Unraid) | ☐ |
| 13 | NPM abbauen | ☐ |
| – | Ausblick: Authentik & weitere Konsumenten | – |

Warum diese Reihenfolge: Phasen 1–6 bringen **sofort Nutzen** (NPM kann weg)
und sind unabhängig von der Registry. Die Registry (7–11) baut dann auf einem
funktionierenden Caddy auf. Jellyfin (12) zuletzt, weil erst dann alle
Schutzmechanismen stehen.

---

## Phase 1 – Caddy-Binary mit Modulen bauen

### Warum

Das Standard-Caddy (auch das apt-Paket) enthält keine DNS-Provider und keinen
CrowdSec-Bouncer. Caddy ist in Go geschrieben; Module werden **beim Kompilieren**
eingebaut. Das Werkzeug dafür heißt `xcaddy`. Ablauf identisch zu Gatus
(`docs/gatus-binary-build.md`): einmal pro Version auf dem Mac bauen, Datei ins
Repo, Ansible kopiert sie.

Zwei Module:

| Modul | Wofür |
|---|---|
| `github.com/caddy-dns/cloudflare` | DNS-01-Challenge über die Cloudflare-API |
| `github.com/hslatman/caddy-crowdsec-bouncer/http` | Caddy fragt CrowdSec, ob eine IP gesperrt ist |

Warum der Bouncer **in Caddy** und nicht in der Firewall: Anfragen über den
Tunnel kommen am Caddy-Host von den cloudflared-IPs an. Eine Firewall sieht nie
den echten Angreifer. Caddy dagegen kennt über den Header `Cf-Connecting-IP`
die echte IP (Phase 4) und kann dort sperren.

### Schritte

1. Go und xcaddy auf dem Mac (Go hast du vom Gatus-Build schon):
   ```bash
   go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
   ```
2. Aktuelle Caddy-Version auf GitHub nachsehen (`caddyserver/caddy`, Releases)
   und in `inventory/group_vars/all/versions.yml` als `caddy_version` eintragen.
3. Bauen – `GOOS`/`GOARCH` wie bei Gatus, weil der Mac für Linux baut:
   ```bash
   GOOS=linux GOARCH=amd64 xcaddy build v<version> \
     --with github.com/caddy-dns/cloudflare \
     --with github.com/hslatman/caddy-crowdsec-bouncer/http \
     --output roles/caddy/files/caddy-<version>-linux-amd64
   ```
4. Den Ablauf in `docs/gatus-binary-build.md` um einen Caddy-Abschnitt ergänzen
   oder ein eigenes Build-Script schreiben (gleiche Idee: Version aus
   `versions.yml` lesen).

### Fertig, wenn

- Die Datei in `roles/caddy/files/` liegt.
- Nach dem Deploy (Phase 2) auf dem LXC zeigt
  `caddy list-modules | grep -E 'cloudflare|crowdsec'` beide Module.

---

## Phase 2 – Caddy-Rolle umbauen

### Warum

Das apt-Paket würde bei jedem `apt upgrade` dein Binary überschreiben. Also:
apt-Repo raus, eigenes Binary + eigene systemd-Unit rein – genau wie bei
Gatus.

Das apt-Paket hat bisher drei Dinge „geschenkt", die du jetzt selbst anlegst:

| Was | Warum |
|---|---|
| System-User `caddy` mit Home `/var/lib/caddy` | Caddy läuft nicht als root; im Home landen Zertifikate und ACME-Konto |
| systemd-Unit | Start, Reload, Rechte |
| Verzeichnisse `/etc/caddy`, `/var/log/caddy` | Konfig und Access-Log (`/var/log/caddy` muss `caddy` gehören) |

### Beispiel: systemd-Unit

Angelehnt an die offizielle Unit aus `caddyserver/dist`, mit zwei Änderungen:

```ini
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/.env
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

- **`EnvironmentFile` direkt in der Unit** – damit brauchst du die
  `override.conf` nicht mehr (die wurde bisher ohnehin nicht verteilt).
- **`--environ` bewusst weggelassen.** Die offizielle Unit hat es; es schreibt
  beim Start alle Umgebungsvariablen ins Journal – also auch deinen
  Cloudflare-Token.
- `AmbientCapabilities=CAP_NET_BIND_SERVICE` erlaubt dem Nicht-root-User,
  Port 80/443 zu öffnen.

### Handler: reload vs. restart

| Änderung | Handler | Warum |
|---|---|---|
| `Caddyfile` | `reloaded` | Caddy lädt die Konfig ohne Unterbrechung neu |
| `.env`, Binary, Unit | `restarted` (+ `daemon_reload` bei Unit) | Umgebungsvariablen und Programm werden nur beim Start gelesen |

Also **zwei Handler** statt einem. Tipp: Das `template`-Modul hat einen
Parameter `validate:` – damit lässt sich ein kaputtes Caddyfile verhindern,
bevor es geschrieben wird (`caddy validate --adapter caddyfile --config %s`).
Ausprobieren; falls `validate` wegen des leeren Tokens meckert, weglassen und
stattdessen nach dem Deploy `journalctl -u caddy` prüfen.

### Aufräumen in der Rolle

- `install.yml`: Repo-/apt-Tasks ersetzen; die doppelten Konfig-Tasks entfernen
  (die gehören nur nach `config.yml`).
- Falls das apt-Paket auf 204 schon installiert ist: einmalig
  `apt: name=caddy state=absent` und das Repo mit `state: absent` entfernen.

### Fertig, wenn

- `systemctl status caddy` läuft als User `caddy`.
- Ein zweiter Ansible-Lauf meldet `changed=0`.

---

## Phase 3 – DNS-Challenge + Wildcard-Zertifikat

### Warum

Siehe README (Caddy → Zertifikate): Interne Clients landen direkt bei Caddy und
brauchen ein echtes Zertifikat. Die DNS-Challenge funktioniert, ohne dass Caddy
von außen erreichbar ist: Caddy legt über die Cloudflare-API einen TXT-Eintrag
`_acme-challenge.ledermann.cc` an, Let's Encrypt prüft ihn, fertig.

### Schritte

1. **Eigenen Cloudflare-Token** anlegen (nicht den von cloudflared
   wiederverwenden – der hier liegt dauerhaft auf einem Server):
   - Rechte: *Zone → Zone → Read* und *Zone → DNS → Edit*
   - Zone: nur `ledermann.cc`
   - In den Vault: z.B. `vault_caddy_cloudflare_token`
2. `secrets.env.j2`:
   ```
   CF_API_TOKEN={{ vault_caddy_cloudflare_token }}
   ```
3. Caddyfile – globaler Block ganz oben plus **ein** Wildcard-Block:
   ```
   {
       acme_dns cloudflare {env.CF_API_TOKEN}
       # Nur zum Testen – Staging-Zertifikate zählen nicht gegen die Limits:
       acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
   }

   *.ledermann.cc {
       @paperless host paperless.ledermann.cc
       handle @paperless {
           reverse_proxy 172.16.10.207:8000
       }

       handle {
           abort
       }
   }
   ```
   **Warum ein Block statt einem pro Dienst:** Ein Block pro Hostname würde je
   ein eigenes Zertifikat anfordern. Der Wildcard-Block holt genau eins; darin
   verteilen `host`-Matcher auf die Dienste. `handle`-Blöcke schließen sich
   gegenseitig aus – der erste passende gewinnt. Das letzte `handle` ohne
   Matcher fängt alles Unbekannte ab.
4. Testen **ohne** etwas am echten Betrieb zu ändern – auf dem Mac in
   `/etc/hosts`:
   ```
   172.16.10.204 paperless.ledermann.cc
   ```
   Dann:
   ```bash
   journalctl -u caddy -f          # auf dem LXC: "certificate obtained successfully"
   curl -vI https://paperless.ledermann.cc   # auf dem Mac
   ```
   Mit Staging meckert curl über ein unbekanntes Zertifikat – das ist
   richtig so. Danach die `acme_ca`-Zeile entfernen → echtes Zertifikat.
5. `/etc/hosts`-Eintrag wieder löschen.

### Wenn es hakt

- `timed out waiting for record to fully propagate`: Caddy fragt zum Prüfen
  die System-DNS (Pi-hole). Lösung: im Wildcard-Block einen `tls`-Block mit
  `dns cloudflare {env.CF_API_TOKEN}` und `resolvers 1.1.1.1` setzen.
- `403`/`Invalid request headers` von Cloudflare: Token-Rechte prüfen.

### Fertig, wenn

- `curl -vI` zeigt ein Zertifikat von Let's Encrypt für `*.ledermann.cc`.
- In `/var/lib/caddy/.local/share/caddy/certificates/` liegt es.

---

## Phase 4 – Caddyfile-Grundgerüst

Jetzt bekommt das Caddyfile die Form, die es dauerhaft behält. Noch aus einer
**Handliste** – aber schon im Format des späteren Steckbriefs (Phase 7). Dann
musst du beim Umstieg nur die Quelle der Liste tauschen, nicht das Template.

### 4a – Die Liste

In `host_vars/lxc-caddy.yml` (vorübergehend):

```yaml
caddy_sites:
  - name: paperless
    upstream: "172.16.10.207:8000"
    exposure: tunnel
  - name: proxmox-alderaan
    upstream: "https://172.16.10.10:8006"
    upstream_insecure: true      # selbstsigniertes Zertifikat am Ziel
    exposure: intern
```

### 4b – Das Template

Nur die Schleife als Idee:

```jinja
{% for s in caddy_sites %}
    @{{ s.name }} host {{ s.name }}.{{ external_domain }}
    handle @{{ s.name }} {
        reverse_proxy {{ s.upstream }}{% if s.upstream_insecure | default(false) %} {
            transport http {
                tls_insecure_skip_verify
            }
        }{% endif %}

    }
{% endfor %}
```

### 4c – Default-Deny

Idee: *Wer nicht aus dem LAN kommt und keinen `public`-Dienst will, fliegt
raus.* Muss **vor** den Dienst-`handle`-Blöcken stehen (erster Treffer
gewinnt):

```
    @blocked {
        not remote_ip private_ranges
        not host jellyfin.ledermann.cc
    }
    handle @blocked {
        abort
    }
```

- Mehrere Zeilen in einem benannten Matcher sind **UND**-verknüpft.
- `host jellyfin…` später aus der Liste erzeugen (alle mit `exposure: public`).
- **Wichtig: `remote_ip`, nicht `client_ip`.** `remote_ip` ist die IP, die
  die Verbindung tatsächlich aufgebaut hat – bei Tunnel-Traffic die
  cloudflared-IP (LAN) → darf durch. `client_ip` wäre nach 4d die echte
  Internet-IP → Tunnel-Dienste wären gesperrt.
- `abort` schließt die Verbindung ohne Antwort – ein Scanner erfährt nicht mal,
  dass dort ein Dienst läuft.

### 4d – Echte Client-IP und Access-Log

Im globalen Block:

```
    servers {
        trusted_proxies static 172.16.10.212/32 172.16.10.214/32
        client_ip_headers Cf-Connecting-IP
    }
```

- Nur den beiden cloudflared-Containern wird der Header geglaubt. Würdest du
  `private_ranges` eintragen, könnte jedes Gerät im LAN eine beliebige IP
  vortäuschen.
- Die IPs nicht abtippen, sondern ableiten – das Muster gibt es schon in
  `group_vars/proxmox_nodes.yml`:
  `groups['cloudflared_hosts'] | map('extract', hostvars, 'ansible_host')`

Im Wildcard-Block:

```
    log {
        output file /var/log/caddy/access.log
    }
```

Caddy schreibt JSON und rotiert die Datei selbst. CrowdSec liest sie in Phase 5.

### Fertig, wenn

- Ein unbekannter Name (z.B. `/etc/hosts`-Test mit `gibtsnicht.ledermann.cc`)
  wird von Caddy abgebrochen.
- Nachprüfbar erst ab Phase 6: Im Log eines Tunnel-Aufrufs steht bei
  `remote_ip` die cloudflared-IP und bei `client_ip` deine Mobilfunk-IP.
- Den Default-Deny von außen testest du in Phase 12.

---

## Phase 5 – CrowdSec auf dem Caddy-Host

### Warum / wie es zusammenhängt

```
access.log ──► CrowdSec-Agent ──► erkennt Muster ──► Entscheidung "IP sperren"
                                                        │
                        Caddy-Bouncer fragt LAPI ◄──────┘
                        (bei jeder Anfrage, gecacht)
```

- **Agent + LAPI** (Local API) laufen im Paket `crowdsec` zusammen auf 204.
- **Bouncer** = der Teil, der sperrt. Hier: das Modul in Caddy.

### Schritte

1. **Neue Rolle `crowdsec`**, Aufbau wie deine anderen apt-Rollen: Repo
   (`deb822_repository`, URL und Key aus der CrowdSec-Doku, Abschnitt
   Linux/Debian), Paket `crowdsec`.
2. **Collections** (Pakete aus Parsern + Erkennungsregeln):
   ```
   crowdsecurity/caddy
   crowdsecurity/base-http-scenarios
   crowdsecurity/http-cve
   crowdsecurity/linux
   crowdsecurity/sshd
   ```
   Installation per `cscli collections install <name>` im `command`-Modul.
   Damit Ansible nicht jedes Mal „changed" meldet: den Befehl von Hand zweimal
   ausführen, die Ausgabe beim zweiten Mal ansehen und daraus ein
   `changed_when` bauen. Nach Änderungen: Handler `restart crowdsec`.
3. **Log-Quelle** `/etc/crowdsec/acquis.d/caddy.yaml` (Template):
   ```yaml
   filenames:
     - /var/log/caddy/access.log
   labels:
     type: caddy
   ```
4. **Bouncer-Schlüssel.** Statt CrowdSec einen Schlüssel erzeugen zu lassen
   (nicht wiederholbar), selbst einen erzeugen und in den Vault legen:
   ```bash
   openssl rand -hex 32   # → vault_crowdsec_caddy_bouncer_key
   ```
   Registrieren:
   ```bash
   cscli bouncers add caddy --key <schlüssel>
   ```
   Idempotent machen: vorher `cscli bouncers list -o json` abfragen und nur
   hinzufügen, wenn `caddy` fehlt.
5. **Caddy anbinden.** In `.env` `CROWDSEC_API_KEY=…`, im globalen Block:
   ```
       order crowdsec first
       crowdsec {
           api_url http://127.0.0.1:8080
           api_key {env.CROWDSEC_API_KEY}
       }
   ```
   Im Wildcard-Block eine Zeile `crowdsec`. `order … first` sorgt dafür, dass
   die Prüfung vor allem anderen läuft. Genaue Syntax im README des Moduls
   gegenprüfen – sie hat sich zwischen Versionen geändert.
6. **Update-Job**: `cscli hub update && cscli hub upgrade`, danach Neustart.
   Vorher prüfen, ob das Paket schon einen Timer/Cron mitbringt
   (`systemctl list-timers`, `ls /etc/cron.daily`). Wenn nicht:
   `ansible.builtin.cron` oder ein systemd-Timer (erster Kandidat für
   Semaphore, siehe README).

### Wichtig zu wissen

- CrowdSec setzt **private IPs standardmäßig auf die Whitelist**
  (`crowdsecurity/whitelists`). Die cloudflared-Container werden also nie
  gesperrt – gut so. Nebeneffekt: Du kannst dich aus dem LAN nicht selbst
  aussperren und darum nicht aus dem LAN testen.
- Firewall-Bouncer (`crowdsec-firewall-bouncer-nftables`) ist **optional**
  zusätzlich, für SSH und später den Jellyfin-Portforward. Im LXC erst testen.

### Testen

```bash
cscli metrics                           # Zeilen gelesen/geparst für caddy?
cscli bouncers list                     # caddy mit "last pull" kürzlich?
cscli decisions add --ip <handy-mobilfunk-ip> --duration 5m
# Handy über Mobilfunk → paperless über Tunnel → muss gesperrt sein (403)
cscli decisions delete --ip <handy-mobilfunk-ip>
```

Die Mobilfunk-IP findest du im Caddy-Log als `client_ip` (Phase 4d).

### Fertig, wenn

- `cscli metrics` zeigt geparste Caddy-Zeilen.
- Der Sperr-Test mit dem Handy funktioniert.

---

## Phase 6 – Dienste von NPM auf Caddy umziehen

Einzeln, jeweils mit Test. NPM läuft parallel weiter.

### Tunnel-Dienste

In `group_vars/cloudflared_hosts.yml` pro Eintrag `service` überschreiben:

```yaml
  - hostname: "paperless.{{ external_domain }}"
    service: "https://172.16.10.204:443"
    originRequest:
      matchSNItoHost: true
```

**Warum `matchSNItoHost`:** cloudflared prüft Caddys Zertifikat. Ohne die Option
vergleicht es gegen `172.16.10.204` – passt nicht zu `*.ledermann.cc`. Mit der
Option meldet es sich mit dem angefragten Hostnamen. Falls deine
cloudflared-Version die Option nicht kennt: `originServerName` pro Eintrag
setzen. Beides in der cloudflared-Doku unter „Origin configuration" prüfen.

### Interne Dienste

Pi-hole: Eintrag von `npm.lan` auf Caddy umbiegen. Empfehlung: **A-Record statt
CNAME** (`pihole_dns_hosts`: `172.16.10.204 paperless.ledermann.cc`). Pi-hole
beantwortet CNAMEs nur, wenn es das Ziel selbst kennt – ein A-Record hat diese
Falle nicht, und die Caddy-IP ist in Ansible ohnehin eine Variable.

### `.lan`-Dienste

Auf `<dienst>.ledermann.cc` umbenennen. Übergangsweise alte Lesezeichen
weiterleiten – ein eigener, einfacher Block **außerhalb** des Wildcard-Blocks:

```
http://sonarr.lan {
    redir https://sonarr.ledermann.cc{uri}
}
```

`http://` davor sagt Caddy: kein Zertifikat versuchen. Nach ein paar Wochen
löschen.

### Fertig, wenn

- Alle NPM-Einträge haben ein Caddy-Gegenstück und sind getestet (intern und,
  wo zutreffend, über Tunnel).
- `cloudflared_default_origin` zeigt auf Caddy; die Einzel-Overrides sind weg.

---

## Phase 7 – Service-Registry: Steckbriefe + Caddy als Konsument

### Die Idee

Jeder Dienst beschreibt sich **selbst**. Konsumenten-Rollen sammeln ein.

### 7a – Steckbrief am Dienst-Host

`host_vars/lxc-paperless.yml`:

```yaml
host_services:
  - name: paperless
    upstream: "{{ ansible_host }}:8000"
    exposure: tunnel
    health_path: /api/
```

- **Liste**, weil ein Host mehrere Dienste haben kann.
- `{{ ansible_host }}` wird erst beim Zugriff ausgewertet – und zwar mit den
  Variablen **dieses** Hosts. Aus der Caddy-Rolle heraus kommt also trotzdem
  die Paperless-IP heraus.
- Stub-Hosts wie `lxc-paperless` brauchen dafür eine `container_vmid`, sonst
  ist `ansible_host` leer (siehe `lxc_containers: vars:`).

### 7b – Unraid-Dienste als reine Daten-Hosts

In `hosts.yml` eine eigene Gruppe:

```yaml
unraid_services:        # Nur Daten – kein Play spricht diese Gruppe an!
  hosts:
    svc-jellyfin:
      ansible_host: 172.16.10.20
      host_services:
        - name: jellyfin
          upstream: "172.16.10.20:8096"
          exposure: public
    svc-seer:
      ansible_host: 172.16.10.20
      host_services:
        - name: seer
          upstream: "172.16.10.20:5055"
          exposure: tunnel
```

Ansible verbindet sich nie dorthin, aber `hostvars['svc-jellyfin']` ist lesbar.
**Achtung:** Kein Play darf `hosts: all` nutzen, sonst versucht Ansible SSH auf
diese Phantom-Hosts. Aktuell tut das keins – beim Schreiben neuer Playbooks
daran denken (oder `hosts: all:!unraid_services`).

### 7c – Einsammeln

`inventory/group_vars/all/services.yml`:

```yaml
service_registry: >-
  {{ groups['all']
     | map('extract', hostvars)
     | selectattr('host_services', 'defined')
     | map(attribute='host_services')
     | flatten
     + service_registry_extra }}

service_registry_extra: []   # Dienste ohne eigenen Host
```

Zeile für Zeile:

| Filter | Macht |
|---|---|
| `groups['all']` | Liste aller Hostnamen |
| `map('extract', hostvars)` | … ersetzt durch deren Variablen |
| `selectattr('host_services', 'defined')` | … nur Hosts mit Steckbrief |
| `map(attribute='host_services')` | … nur die Steckbrief-Listen |
| `flatten` | Liste von Listen → eine Liste |

**Stolperfalle Namensgleichheit:** Die Sammel-Variable darf **nicht** so
heißen wie das Feld am Host. Hieße beides `services`, hätte durch
`group_vars/all` *jeder* Host das Feld – inkl. Selbstbezug. Deshalb
`host_services` (am Host) vs. `service_registry` (gesammelt).

Ausprobieren, bevor du Templates anfasst:

```bash
ansible localhost -m debug -a "var=service_registry"
```

### 7d – Caddy umstellen

In der Caddy-Rolle `caddy_sites` durch `service_registry` ersetzen – das
Template bleibt gleich, weil Phase 4 schon dieses Format hatte. Die
`public`-Hostnamen für Default-Deny:

```jinja
{{ service_registry | selectattr('exposure', 'eq', 'public') | map(attribute='name') | join(' ') }}
```

### Fertig, wenn

- `caddy_sites` ist aus `host_vars/lxc-caddy.yml` verschwunden.
- Das erzeugte Caddyfile ist identisch zu vorher (Ansible meldet `ok`, nicht
  `changed`) – das ist der beste Beweis, dass der Umbau nichts verändert hat.

---

## Phase 8 – Pi-hole als Konsument

Pi-hole v6 liest Einstellungen aus Umgebungsvariablen – das nutzt deine Rolle
schon (`pihole-FTL.env.j2`). Lokale DNS-Einträge gehen genauso:

```
FTLCONF_dns_hosts={{ pihole_dns_records | join(';') }}
```

mit einer abgeleiteten Liste wie:

```yaml
pihole_dns_records: >-
  {{ pihole_dns_hosts
     + (service_registry | map(attribute='name')
        | map('regex_replace', '^(.*)$', caddy_ip ~ ' \1.' ~ external_domain)
        | list) }}
```

- `caddy_ip` einmal zentral ableiten: `hostvars['lxc-caddy'].ansible_host`.
- `pihole_dns_hosts` bleibt als Handliste für Geräte (unraid.lan, unifi.lan …).
- **Warum Umgebungsvariable gut ist:** Pi-hole sperrt Einstellungen, die per
  Variable gesetzt sind, in der Web-Oberfläche. Das ist automatisch
  „deklarativ" – niemand kann per UI etwas daneben eintragen, und nebula-sync
  wird für diese Einträge überflüssig.
- Eine geänderte `.env` braucht einen **Neustart** des Pi-hole-Dienstes/
  Containers (Handler).

### Fertig, wenn

- `dig @172.16.10.40 paperless.ledermann.cc` → `172.16.10.204`
- `pihole_cname_records` ist leer bzw. gelöscht.

---

## Phase 9 – cloudflared + CF-DNS als Konsument

### Ingress

Im cloudflared-Template statt der Handliste über die Registry laufen:

```jinja
ingress:
{% for s in service_registry | selectattr('exposure', 'eq', 'tunnel') %}
  - hostname: "{{ s.name }}.{{ external_domain }}"
    service: "https://{{ caddy_ip }}:443"
    originRequest:
      matchSNItoHost: true
{% endfor %}
  - service: http_status:404
```

`cloudflared_ingress` kann dann weg (oder bleibt als Extras-Liste für
Sonderfälle).

### DNS-Einträge

Der bestehende `cloudflare_dns`-Task bekommt als `loop` dieselbe gefilterte
Liste.

**Löschen ist nicht automatisch:** Der Task legt nur an. Fällt ein Dienst weg,
bleibt der CNAME bei Cloudflare stehen. Einfachste Lösung:

```yaml
cloudflared_removed_hostnames:
  - altedienst
```

und ein zweiter Task mit `state: absent` über diese Liste. (Eleganter, aber
aufwändiger: alle CNAMEs auf `<tunnel-id>.cfargotunnel.com` abfragen und die
löschen, die nicht in der Registry sind – erst wenn es nervt.)

### Fertig, wenn

- Ein Test-Dienst mit `exposure: tunnel` taucht nach einem Lauf im Tunnel und
  bei Cloudflare auf – ohne dass du `cloudflared_hosts.yml` anfasst.

---

## Phase 10 – Gatus als Konsument

Gatus ist am individuellsten. Deshalb: **Standard-Check aus der Registry**,
Sonderfälle bleiben in der Handliste.

```jinja
{% for s in service_registry %}
  - name: {{ s.name }}
    group: {{ s.gatus_group | default('services') }}
    url: "https://{{ s.name }}.{{ external_domain }}{{ s.health_path | default('/') }}"
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[CERTIFICATE_EXPIRATION] > 240h"
    alerts: …
{% endfor %}
{# danach die Handliste: #}
{{ gatus_endpoints | to_nice_yaml }}
```

- Die Checks laufen **über Caddy** (per Pi-hole-Name) – damit prüft Gatus
  Dienst, Proxy und Zertifikat in einem.
- `gatus_endpoints` in `host_vars/lxc-gatus.yml` enthält danach nur noch
  Dinge ohne Steckbrief (Proxmox-API, Geräte …).
- Optional: `health_path: false` im Steckbrief → kein Check (für Dienste, die
  keinen sinnvollen Endpunkt haben).

### Fertig, wenn

- In Gatus erscheinen alle Registry-Dienste; die Handliste ist deutlich kürzer.

---

## Phase 11 – Ablauf „neuer Dienst"

### Die Playbook-Kette

Neues Playbook `playbooks/service_registry.yml` – nur die Konsumenten:

```yaml
- name: Pi-hole DNS
  hosts: failsafe_hosts
  roles: [pihole]

- name: Caddy
  hosts: caddy_hosts          # Gruppe neu anlegen, analog gatus_hosts
  roles: [caddy]

- name: Tunnel
  hosts: cloudflared_hosts
  roles: [cloudflared]

- name: Monitoring
  hosts: gatus_hosts
  roles: [gatus]
```

- **Reihenfolge zählt:** Gatus zuletzt, sonst Fehlalarm.
- **Neustarts organisieren sich selbst:** Handler laufen am Ende **jedes Plays**.
  Caddy ist also schon neu geladen, bevor das Tunnel-Play beginnt. Nur Rollen,
  deren Dateien sich geändert haben, starten neu.
- Beschleunigen mit Tags (z.B. `caddy-config`), damit nicht jedes Mal die
  komplette Installation geprüft wird.

### Die `--limit`-Falle

`container_site.yml` läuft mit `--limit lxc-neu`. Würdest du die Konsumenten
dort anhängen, überspringt Ansible sie – `lxc-caddy` ist ja nicht im Limit.
Deshalb **zwei Aufrufe** – ideal im geplanten Wrapper-Script:

```bash
#!/usr/bin/env bash
set -euo pipefail
host="$1"; shift
ansible-playbook playbooks/container_site.yml --limit "$host" "$@"
ansible-playbook playbooks/service_registry.yml
```

### Ergebnis – so sieht ein neuer Dienst dann aus

1. In `hosts.yml` den Container eintragen (`container_vmid`, `container_role` …).
2. In `host_vars/<host>.yml` den Steckbrief (`host_services`).
3. `./new-service.sh lxc-neu -u root`
4. Fertig: Container läuft, DNS, Proxy, Zertifikat, ggf. Tunnel und Gatus-Check
   sind da.

---

## Phase 12 – Jellyfin öffentlich

Erst jetzt, weil Default-Deny (4c) und CrowdSec (5) stehen müssen.

1. **Steckbrief** `svc-jellyfin` mit `exposure: public` (schon in 7b).
2. **Jellyfin:** *Dashboard → Netzwerk → Known Proxies* = `172.16.10.204`.
   Sonst sieht Jellyfin jeden Login als „von Caddy" – Sperren und Logs wären
   wertlos.
3. **DNS:** A-Record `jellyfin.ledermann.cc` → öffentliche IP, **nicht
   proxied**. Bei wechselnder IP DDNS: erst UniFi prüfen, sonst ein kleiner
   Container (z.B. `favonia/cloudflare-ddns`) auf Unraid.
4. **CrowdSec-Agent auf Unraid** (siehe README → CrowdSec → Jellyfin):
   - Auf 204 die LAPI im LAN erreichbar machen (`listen_uri` in
     `/etc/crowdsec/config.yaml` von `127.0.0.1:8080` auf
     `0.0.0.0:8080`) – und per Firewall nur für Unraid öffnen.
   - Agent registrieren: `cscli machines add unraid --password <aus Vault>`
   - Auf Unraid den CrowdSec-Container **ohne eigene LAPI** starten
     (Umgebungsvariablen laut Doku des Images: LAPI abschalten, URL +
     Zugangsdaten der Zentrale, Collection `LePresidente/jellyfin`), das
     Jellyfin-Log-Verzeichnis read-only einbinden.
   - Test: `cscli machines list` auf 204 zeigt `unraid` als aktiv.
   - Test: absichtlich 5× falsches Passwort von Mobilfunk →
     `cscli decisions list` zeigt die IP.
5. **Portforward** in UniFi: 443 → `172.16.10.204:443`. **Als letzter Schritt.**
6. Test von außen: `jellyfin.ledermann.cc` geht, `paperless.ledermann.cc`
   **mit der öffentlichen IP** muss abbrechen:
   ```bash
   curl -v --resolve paperless.ledermann.cc:443:<öffentliche-ip> https://paperless.ledermann.cc
   ```
   (von außen ausführen, z.B. Handy-Hotspot) → Verbindung wird geschlossen.

### Fertig, wenn

- Beide Tests aus 6. verhalten sich wie beschrieben.
- Der Fehl-Login-Test aus Schritt 4 führt zu einer Sperre.

---

## Phase 13 – NPM abbauen

1. Prüfen, dass nichts mehr auf 208 zeigt: Pi-hole, cloudflared, Portforwards.
2. Der alte CrowdSec auf 208 ist dann überflüssig (läuft jetzt auf 204).
3. LXC 208 **stoppen**, nicht löschen – eine Woche beobachten (Gatus!).
4. Danach löschen, `lxc-nginx-proxy` aus dem Inventory und `npm.lan` aus
   `pihole_dns_hosts` entfernen, README-Punkt auf „erledigt".

---

## Ausblick – weitere Konsumenten

### Authentik (Forward-Auth)

Für Dienste **ohne eigenen Login** (oder zusätzlichen Schutz) schiebt Caddy
jede Anfrage erst zu Authentik. Neues Feld im Steckbrief:

```yaml
    auth: forward     # none (Standard) | forward
```

Caddy-Seite (im jeweiligen `handle`-Block, per `{% if %}`):

```
        reverse_proxy /outpost.goauthentik.io/* http://172.16.10.213:9000
        forward_auth http://172.16.10.213:9000 {
            uri /outpost.goauthentik.io/auth/caddy
            copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email
        }
        reverse_proxy {{ s.upstream }}
```

Authentik-Seite: Pro Dienst braucht es einen *Proxy Provider* (Modus
„Forward auth, single application"), eine *Application* und die Zuordnung zum
Outpost. Das geht automatisiert über **Authentik-Blueprints**: YAML-Dateien in
Authentiks `blueprints`-Verzeichnis, die Authentik selbst einliest. Ansible
würde daraus ein weiteres Template mit Schleife über
`service_registry | selectattr('auth', 'defined') | selectattr('auth', 'eq', 'forward')`.
Voraussetzung: `lxc-authentik` ist ein echter Ansible-Host (README → Stubs).

**Nicht** automatisierbar im Allgemeinen: Dienste mit eigenem OIDC-Login
(Paperless, Immich, Grafana). Die brauchen app-spezifische Einstellungen auf
beiden Seiten – bleiben Handarbeit.

### Sonderfall Jellyfin

**Kein Forward-Auth.** Die Jellyfin-Apps (TV, Handy, Infuse …) erwarten eine
Antwort von Jellyfin und können mit der Umleitung auf die Authentik-Loginseite
nichts anfangen – nur der Browser würde noch funktionieren. Im Steckbrief
bleibt Jellyfin deshalb bei `auth: none`; angemeldet wird in Jellyfin selbst.

Stattdessen:

| Weg | Wie | Vorteile | Grenzen |
|---|---|---|---|
| **LDAP** (Empfehlung) | Authentik-*LDAP-Outpost* + offizielles Jellyfin-**LDAP-Plugin** | Funktioniert in **allen** Apps (App schickt wie bisher Benutzer/Passwort, Jellyfin prüft bei Authentik); Nutzer zentral anlegen/sperren | Kein MFA in den Apps; Passwort-Raten bleibt möglich → CrowdSec (Phase 12) bleibt wichtig |
| **SSO-Plugin** (Ergänzung) | Community-Plugin `jellyfin-plugin-sso` per OIDC | Web-Login mit Authentik inkl. MFA; Apps per **Quick Connect** (Code in der App, im Browser bestätigen) | Drittanbieter-Code; für fremde Nutzer umständlicher |

Beachten:

- **Abhängigkeit:** Ist Authentik weg, kann sich niemand neu anmelden
  (bestehende Sitzungen laufen weiter). Ein **lokales Jellyfin-Admin-Konto**
  als Notzugang behalten.
- Authentik protokolliert fehlgeschlagene LDAP-Anmeldungen selbst und kann per
  Richtlinie nach Fehlversuchen sperren – ergänzt CrowdSec.
- Reihenfolge: erst nach Phase 12 und erst, wenn `lxc-authentik` ein echter
  Ansible-Host ist.

### Weitere Kandidaten

| Konsument | Was er aus dem Steckbrief nimmt | Lohnt sich, wenn … |
|---|---|---|
| Dashboard (Homepage/Homarr) | Name, URL, Gruppe, Icon | du eins nutzt – sonst nicht |
| VictoriaMetrics | Dienste mit `/metrics`-Endpunkt | Dienste eigene Metriken liefern (Feld `metrics_port`) |
| Proxmox-HA / Replikation | `container_ha` (gibt es schon) | Phase „HA + ZFS-Replikation" aus dem README |
| CrowdSec-Collections | z.B. `crowdsec_collection: LePresidente/jellyfin` | mehrere Dienste eigene Log-Parser brauchen |

Regel wie immer: Ein neues Feld nur, wenn **ein Konsument** es wirklich liest.
