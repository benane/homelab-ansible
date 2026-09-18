# homelab-ansible

## Nutzung

### Gesamten Bestand konfigurieren

`site.yml` wendet Grundkonfiguration, Hardening, Proxmox-Setup, Monitoring und DNS-Failsafe an. Beliebig oft wiederholbar (idempotent). Ein Guard erzwingt `--limit` – für den kompletten Bestand bewusst `--limit all`:

```bash
ansible-playbook playbooks/site.yml --limit all
```

### Einzelnen Container erstellen/konfigurieren

`container_site.yml` läuft gegen die Gruppe `lxc_provisioned` und braucht daher `--limit` auf genau den Container, den du erzeugen/konfigurieren willst (der Host muss Mitglied von `lxc_provisioned` sein):

```bash
ansible-playbook playbooks/container_site.yml --limit lxc-zigbee2mqtt
```

**Erster Lauf für einen neuen Container:** Der `ansible`-Service-User existiert noch nicht (den legt erst die `common`-Rolle an), daher muss die Verbindung beim allerersten Mal als `root` erfolgen:

```bash
ansible-playbook playbooks/container_site.yml --limit lxc-zigbee2mqtt -u root
```

Ab dem zweiten Lauf greift wieder der Default aus `ansible.cfg` (`remote_user = ansible`) – `-u root` nicht mehr nötig. `ansible_user: root` sollte deshalb **nicht** dauerhaft in `hosts.yml` stehen bleiben.

### Hinweise für den Betrieb

**Mosquitto komplett neu aufsetzen:** Beim Neubau des mosquitto-Containers gehen alle persistierten (retained) MQTT-Nachrichten verloren – u.a. die Home-Assistant-Discovery-Configs und der letzte bekannte Gerätezustand. Danach müssen alle MQTT-Clients (aktuell: zigbee2mqtt) manuell neu gestartet werden, damit sie sich neu verbinden und alles erneut publizieren:

```bash
ssh ansible@172.16.10.202
sudo systemctl restart zigbee2mqtt
```

Home-Assistant-Geräte sollten danach innerhalb weniger Sekunden wieder "available" werden.

## ToDo

### Provisioning / Gäste

- backup restore
- Proxmox-HA + ZFS-Replikation für wichtige Container (u.a. Caddy) prüfen/einrichten: HA kann einen Container nur dann auf dem anderen Node neu starten, wenn dessen Storage dort auch verfügbar ist – ohne `pvesr`-Replikation zwischen Alderaan/Corellia hilft die HA-Konfiguration nicht. Reiner Proxmox-Admin-Schritt, nicht Ansible. Beim Ersteinrichten von Caddy noch nicht berücksichtigt, muss nachgezogen werden.
- Proxmox-API-Token und Berechtigungen automatisch anlegen, statt als Handschritt
- Wrapper-Script für Container-Erstellung (kapselt `--limit <host>` und beim ersten Lauf `-u root`, gegen Tippfehler)
- `container_vmid` dynamisch (nächste freie ID ab 201): **zurückgestellt**, bis die ganze Kette (Monitoring, Tunnel, DNS, Reverse Proxy) einen Rebuild automatisch nachzieht – sonst mehr Nacharbeit als Nutzen, und Rebuilds werden nicht-deterministisch.
- Container-Provisioning: Rolle `proxmox_container` steht (create/template/metadata; Node/Storage inventory-gesteuert via `container_node` / `container_storage`, Fallback `proxmox_default_*` in `group_vars/all/proxmox.yml`). **Offen:** schlankes `guest_site.yml`, das LXC- vs. VM-Rolle wählt und danach `common` + `hardening` + Service-Rolle anhängt; analoge Rolle `proxmox_vm`. Service-Rollen bleiben eigenständig. Details: `docs/playbook-architecture.md`
- LXC 208 (`lxc-nginx-proxy`), 213 (`lxc-authentik`) und die HA-VM (`vm-hassio`) laufen physisch auf `Corellia`, im Inventory nur IP-Stubs. Beim Reproduzieren per Ansible: `container_vmid` / `container_role` / `container_node: Corellia` / `container_storage: nvme-zfs` nachziehen.
- ESPHome-Container mit Pull der YAML-Configs aus GitHub-Repo
- **`rpi-dns` (Hoth, 172.16.10.40, Primary-Pi-hole) unter Ansible bringen** – hat bisher nie `common`/`hardening` durchlaufen (kein `ansible`-User, SSH mit Standard-Key/-User schlägt fehl), daher liest die `pihole`-Rolle für diesen Host bislang nur Karteileichen-Variablen. Geplanter Zeitpunkt: **Neuaufsetzen mit bereits bestellter High-Endurance-SD-Karte** – dann von Grund auf bootstrappen statt nachträglich auf ein laufendes System zuzugreifen. `docs/wyse-bootstrap.md` ist trotz Wyse-spezifischem Inhalt bewusst als Runbook für genau so einen Fall stehen geblieben ("z.B. für einen Re-Bootstrap") – als Vorlage nutzen. Bis dahin: Pi-hole-Registry-Rollout (`08c_pihole.yml`) nur gegen `wyse-3040`, `rpi-dns` bleibt außen vor.
- `proxmox_container`-Task „Container als HA-Ressource registrieren" (`community.proxmox.proxmox_cluster_ha_resources`, `roles/proxmox_container/tasks/ha.yml`) meldet bei jedem Lauf `changed`, obwohl sich nichts ändert – Idempotenz-Problem im Modul, noch nicht untersucht.

### Netzwerk & externe Dienste

- Cloudflared-Ingress → DNS: **erledigt** – Task `community.general.cloudflare_dns` in der `cloudflared`-Rolle (`become: false`, `delegate_to: localhost`, `run_once`) legt je Ingress-Eintrag mit `hostname` einen proxied CNAME auf `<tunnel-id>.cfargotunnel.com` an. Token `vault_cloudflare_api_token` (Zone→DNS→Edit). `service` via `cloudflared_default_origin` entdoppelt. Ableiten der Liste: siehe „Self-Registration".
  - **Vorfall 2026-09-17/18 (behoben):** Alle Tunnel-Dienste (Gatus/status, Paperless, Seer, Wattwarriors, zeitweise auch Immich) von ~22:00 bis ~08:42 praktisch durchgehend extern nicht erreichbar (`502 Bad Gateway`, per UptimeRobot gemeldet). Ursache: `cloudflared_default_origin` zeigt auf NPMs nackte IP ohne SNI – NPM (mehrere virtuelle Hosts auf einer IP) lehnte Verbindungen ohne passenden SNI ab (`tls: unrecognized name` in cloudflareds Log, ~600 Fehler/Container in dem Zeitraum). Die Annahme "npm routet über Host-Header, SNI ist egal" (siehe alte Fassung dieser Zeile) stimmte nicht – TLS-SNI wird von nginx **vor** jeder Host-Header-Auswertung geprüft. **Fix:** `originRequest.matchSNItoHost: true` global in `roles/cloudflared/templates/config.yml.j2` gesetzt – cloudflared schickt jetzt den tatsächlich angefragten Hostnamen als SNI, für alle Ingress-Einträge gleichzeitig, auch künftige Caddy-Migrationen. Offene Frage: Warum der Fehler ausgerechnet um 22:00 begann, ist ungeklärt (evtl. NPM-seitige Änderung) – für den Fix nicht relevant.
- UniFi-Netzwerk-Config: `roles/unifi_network` ist nur ein Stub, das Playbook `0x_network_setup.yml` wurde gelöscht. Kommt via Terraform (reifer Provider `ubiquiti-community/unifi`, deklarativer Appliance-State) statt Ansible-`uri`-Gepokel.
- Reverse Proxy von NPM auf **Caddy** wechseln: **in Arbeit** (`roles/caddy/`). NPMs Config liegt in einer SQLite-DB (nur UI/API), nicht versionierbar. Caddy = ein getemplatetes `Caddyfile`, automatisches HTTPS, `caddy reload` ohne Downtime, Single-Binary + systemd (gleiche Form wie die anderen Rollen). Läuft bewusst auf einem **neuen Container (VMID 204)** parallel zu NPM (208), nicht als Ersatz an Ort und Stelle – Migration Hostname für Hostname per Override auf `service:` im jeweiligen `cloudflared_ingress`-Eintrag (`cloudflared_default_origin` bleibt bis zum Schluss auf NPM zeigen), NPM erst abbauen wenn alles umgezogen ist. Danach wird das `Caddyfile` aus derselben Liste generiert wie cloudflared-Ingress / Gatus / DNS → Anker für die „ein Fact, viele Konsumenten"-Kette (siehe „Self-Registration"). Traefik wäre die mächtigere, steilere Alternative (File-Provider).
  - **Zertifikate / Exposure:** Caddy kann DNS-01 nur mit Modul `caddy-dns/cloudflare` → eigenes Binary via `xcaddy` (gleiches Muster wie `docs/gatus-binary-build.md`), apt-Paket fällt weg. Ein **Wildcard-Zertifikat `*.ledermann.cc`** für alles – nötig, weil interne Clients per Pi-hole-CNAME direkt bei Caddy landen (Tunnel-Zertifikat hilft dort nicht) und HTTP-01 für rein interne Namen nicht geht; hält nebenbei interne Hostnamen aus den CT-Logs. Intern/extern entscheidet das **DNS** (nur Pi-hole / zusätzlich Cloudflare), nicht Caddy. `*.lan`-Einträge auf `<dienst>.ledermann.cc` (nur Pi-hole) umziehen – `.lan` bekommt nie ein öffentliches Zertifikat. Tunnel → Caddy per HTTPS: `originRequest.matchSNItoHost` prüfen.
  - **Jellyfin als einziger Dienst ohne Tunnel** (Video-Streaming verstößt gegen die Cloudflare-ToS): Portforward 443 → Caddy, A-Record **nicht** proxied (ggf. DDNS). Dadurch ist Caddy direkt aus dem Internet erreichbar → Default-Deny in Caddy: Nicht-LAN-IP (`remote_ip`) und Host ≠ Jellyfin → `abort` (Tunnel-Traffic kommt von der LAN-IP des cloudflared-Hosts und bleibt erlaubt). Portforward erst **zuletzt** aktivieren, wenn Default-Deny + CrowdSec (inkl. Jellyfin-Collection, Caddy-Access-Log via `log`) stehen.
  - **CrowdSec:** **erledigt** (`roles/crowdsec/`, Playbook `09_crowdsec.yml`, Gruppe `crowdsec_hosts`) – Agent + LAPI laufen auf dem Caddy-Host, lesen Caddys Access-Log lokal, Caddy-Bouncer-Modul zieht Entscheidungen bei jeder Anfrage. End-to-end verifiziert (`cscli metrics` zeigt geparste Zeilen, `cscli bouncers list` einen aktiven Pull). Kein fail2ban zusätzlich (SSH via `crowdsecurity/sshd`-Collection). Offen: `cscli hub update`/`upgrade`-Tasks lösen bei jedem Ansible-Lauf einen Neustart aus (kein `changed_when`, harmlos aber unnötig); SSH-Journal-Parser (`crowdsecurity/linux`) liest mit, erkennt aber nichts (144 Zeilen unparsed, nicht untersucht); wiederkehrender Update-Job als Cron/Timer weiterhin offen, siehe Semaphore-Punkt unten.
    - **Neu: Bouncer-Entscheidung revidiert.** Ursprünglich OS-Firewall-Bouncer, um `xcaddy` zu vermeiden – Caddy wird für DNS-01 aber ohnehin per `xcaddy` gebaut. Und: Tunnel-Traffic kommt aus Sicht des Caddy-Hosts von den **cloudflared-Container-IPs**, nicht vom echten Client → ein Firewall-Bouncer kann Angreifer über den Tunnel **nie** sperren (und cloudflared-IPs zu sperren würde alle Tunnel-Dienste killen; private IPs whitelistet CrowdSec standardmäßig). Daher: **Caddy-Bouncer-Modul** (`hslatman/caddy-crowdsec-bouncer`) mit ins Binary, Caddy wertet per `trusted_proxies` (nur cloudflared-a/-b) den Header `Cf-Connecting-IP` als echte Client-IP aus → Log und Sperre greifen am echten Client. Firewall-Bouncer optional zusätzlich für SSH/Portforward.
    - **Jellyfin + CrowdSec:** Fehlgeschlagene Jellyfin-Logins stehen im **Jellyfin-Log**, nicht in Caddys Log → Collection `LePresidente/jellyfin` braucht einen CrowdSec-Agent dort, wo Jellyfin läuft (Unraid, als Container), registriert an der LAPI auf dem Caddy-Host (`cscli machines add`); gesperrt wird zentral vom Caddy-Bouncer. Damit ist der Fall „mehr als ein Host profitiert" für die zentrale Instanz erreicht. Voraussetzung: in Jellyfin unter *Netzwerk → Known Proxies* die Caddy-IP eintragen, sonst loggt Jellyfin nur Caddys IP statt der des Angreifers.
- nebula-sync via Ansible auf Unraid ausrollen. Zusammenspiel mit den Pi-hole-DNS-Einträgen klären: nebula-sync repliziert aktuell die Pi-hole-v6-Config (Teleporter) vom Primary (`172.16.10.40`) auf die Secondaries. Schreibt Ansible die DNS-Config (`pihole_cname_records` / `pihole_dns_hosts` in `group_vars/dns_resolvers.yml`) deklarativ auf **alle** Instanzen, wird nebula-sync überflüssig – sofern keine manuellen UI-Änderungen mehr passieren. Kein Cronjob: Playbook bei Änderung laufen lassen (git → CI/Hand). nebula-sync erst entfernen, wenn „keine manuellen Pi-hole-Edits" als Regel steht.

### Querschnitt

- **Service-Registry (Self-Registration)** – **freigegeben 2026-09-16**, Umsetzung nach Caddy + CrowdSec. Plan: `docs/service-registry-plan.md`. Jeder Dienst-Host trägt einen Steckbrief (`service:` mit `subdomain`/`port`/`exposure`/…) in seinen `host_vars`; `group_vars/all` sammelt daraus per `hostvars` eine Liste, die Konsumenten filtern. Konsumenten in dieser Reihenfolge: Caddy → Pi-hole → cloudflared + CF-DNS → Gatus. Später: Authentik (`forward_auth` + Blueprints), evtl. Dashboard/VictoriaMetrics. Unraid-Container als reine Daten-Hosts (eigene Gruppe, die kein Play anspricht) – löst die frühere Bedingung „alle Dienste im Inventory". Stolperfallen: `--limit` überspringt Konsumenten-Plays; CF-DNS-Einträge werden nicht automatisch gelöscht (`state: absent` nötig); Pi-hole-Records deklarativ (ganze Liste ersetzen). Regel bleibt: kuratierte Liste vs. Self-Registration entscheidet sich an der Zahl der Konsumenten – hier vier.
- **Zigbee2MQTT hat keinen HTTP-Health-Endpoint** – `/health` liefert 404 (Frontend ist nur eine statische UI ohne API), Root (`/`) liefert 200 und dient im Registry-Steckbrief als Ersatz. Ein eigener Health-Check war upstream mal angedacht ([PR #29128](https://github.com/Koenkk/zigbee2mqtt/pull/29128)), aber nie gemerged und inzwischen als "stale" geschlossen (Dez. 2025) – Maintainer wollten dateibasiert statt curl/HTTP lösen, kam nie. Das eingebaute `health`-Feature (`zigbee2mqtt/bridge/health`) ist MQTT-basiert, nicht per HTTP abfragbar – für echtes CPU-/Speicher-/Gerätestatistiken-Monitoring bräuchte es eine MQTT→HTTP-Brücke, kein Ansible-Thema, sondern ein eigenes kleines Vorhaben, falls je gewünscht.

- **`--tags` erreicht keine Rolle, die per `include_role` eingebunden wird** (z.B. in `container_site.yml`, Task „Service-Rolle anwenden"), solange diese Include-Task selbst kein passendes `tags:` trägt. Ansible prüft den Tag-Filter zuerst am `include_role`-Task – matcht der nicht, wird gar nicht erst in die Rolle reingeschaut, selbst wenn Tasks dort drin den gesuchten Tag haben (z.B. `caddy-config`). Betroffen: gezieltes Nachziehen einzelner Config-Änderungen über `container_site.yml --tags <rolle>-config` funktioniert nicht, nur der volle Lauf. Fix wäre `apply: {tags: [...]}` am `include_role` oder Umstieg auf statisches `roles:`, aber das beträfe alle Rollen gleichzeitig – erstmal nur gemerkt, nicht behoben.

### Werkzeuge / Meta

- Terraform evaluieren: nach Fertigstellung `site.yml`, isoliert, Cloudflare (DNS/Tunnel) als erster Fall, dann UniFi, später ggf. Gast-Erstellung. Einstieg: `docs/terraform-evaluation.md`
- Semaphore UI evaluieren: Web-UI + Scheduler für Ansible-Läufe, statt `ansible-playbook` immer von Hand vom Mac aus zu starten. Konkreter erster Anwendungsfall: der wiederkehrende CrowdSec-Hub-Update-Job (siehe Caddy/CrowdSec-Punkt oben), später evtl. auch periodische `site.yml`-Konvergenz-Läufe.
- Versionen pinnen und Updates verfolgen: zentrale `versions.yml` (Anfang steht), Benachrichtigung über newreleases.io/RSS, später Renovate (Dependency Dashboard + Changelog-PRs), optional HTML-Dashboard mit Repo-vs-installiert-Abgleich. Strategie: `docs/version-tracking.md`
  - Betrifft auch alle apt-Repo-Rollen (`cloudflared`, `grafana`, …): installieren aktuell unversioniert (`state: present` ohne `=version`), ziehen also bei jedem Lauf potenziell die neueste Repo-Version. Bewusst zurückgestellt, bis diese zentrale Versionsverwaltung steht – dann in einem Rutsch für alle apt-Rollen nachziehen, nicht Rolle für Rolle einzeln pinnen.
