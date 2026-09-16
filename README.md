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
- `proxmox_container`-Task „Container als HA-Ressource registrieren" (`community.proxmox.proxmox_cluster_ha_resources`, `roles/proxmox_container/tasks/ha.yml`) meldet bei jedem Lauf `changed`, obwohl sich nichts ändert – Idempotenz-Problem im Modul, noch nicht untersucht.

### Netzwerk & externe Dienste

- Cloudflared-Ingress → DNS: **erledigt** – Task `community.general.cloudflare_dns` in der `cloudflared`-Rolle (`become: false`, `delegate_to: localhost`, `run_once`) legt je Ingress-Eintrag mit `hostname` einen proxied CNAME auf `<tunnel-id>.cfargotunnel.com` an. Token `vault_cloudflare_api_token` (Zone→DNS→Edit). `service` via `cloudflared_default_origin` entdoppelt, `originServerName` entfällt (npm routet über Host-Header). Ableiten der Liste: siehe „Self-Registration".
- UniFi-Netzwerk-Config: `roles/unifi_network` ist nur ein Stub, das Playbook `0x_network_setup.yml` wurde gelöscht. Kommt via Terraform (reifer Provider `ubiquiti-community/unifi`, deklarativer Appliance-State) statt Ansible-`uri`-Gepokel.
- Reverse Proxy von NPM auf **Caddy** wechseln: **in Arbeit** (`roles/caddy/`). NPMs Config liegt in einer SQLite-DB (nur UI/API), nicht versionierbar. Caddy = ein getemplatetes `Caddyfile`, automatisches HTTPS, `caddy reload` ohne Downtime, Single-Binary + systemd (gleiche Form wie die anderen Rollen). Läuft bewusst auf einem **neuen Container (VMID 204)** parallel zu NPM (208), nicht als Ersatz an Ort und Stelle – Migration Hostname für Hostname per Override auf `service:` im jeweiligen `cloudflared_ingress`-Eintrag (`cloudflared_default_origin` bleibt bis zum Schluss auf NPM zeigen), NPM erst abbauen wenn alles umgezogen ist. Danach wird das `Caddyfile` aus derselben Liste generiert wie cloudflared-Ingress / Gatus / DNS → Anker für die „ein Fact, viele Konsumenten"-Kette (siehe „Self-Registration"). Traefik wäre die mächtigere, steilere Alternative (File-Provider).
  - **Zertifikate / Exposure:** Caddy kann DNS-01 nur mit Modul `caddy-dns/cloudflare` → eigenes Binary via `xcaddy` (gleiches Muster wie `docs/gatus-binary-build.md`), apt-Paket fällt weg. Ein **Wildcard-Zertifikat `*.ledermann.cc`** für alles – nötig, weil interne Clients per Pi-hole-CNAME direkt bei Caddy landen (Tunnel-Zertifikat hilft dort nicht) und HTTP-01 für rein interne Namen nicht geht; hält nebenbei interne Hostnamen aus den CT-Logs. Intern/extern entscheidet das **DNS** (nur Pi-hole / zusätzlich Cloudflare), nicht Caddy. `*.lan`-Einträge auf `<dienst>.ledermann.cc` (nur Pi-hole) umziehen – `.lan` bekommt nie ein öffentliches Zertifikat. Tunnel → Caddy per HTTPS: `originRequest.matchSNItoHost` prüfen.
  - **Jellyfin als einziger Dienst ohne Tunnel** (Video-Streaming verstößt gegen die Cloudflare-ToS): Portforward 443 → Caddy, A-Record **nicht** proxied (ggf. DDNS). Dadurch ist Caddy direkt aus dem Internet erreichbar → Default-Deny in Caddy: Nicht-LAN-IP (`remote_ip`) und Host ≠ Jellyfin → `abort` (Tunnel-Traffic kommt von der LAN-IP des cloudflared-Hosts und bleibt erlaubt). Portforward erst **zuletzt** aktivieren, wenn Default-Deny + CrowdSec (inkl. Jellyfin-Collection, Caddy-Access-Log via `log`) stehen.
  - **CrowdSec:** läuft aktuell auf dem NPM-Container, zieht nicht automatisch um. Agent (LAPI) auf dem Caddy-Host, liest Caddys Access-Log lokal. Kein fail2ban zusätzlich (SSH via `crowdsecurity/sshd`-Collection). Neue Scenarios über `cscli hub update/upgrade`, erst nach `systemctl restart crowdsec` aktiv → wiederkehrender Update-Job nötig.
    - **Neu: Bouncer-Entscheidung revidiert.** Ursprünglich OS-Firewall-Bouncer, um `xcaddy` zu vermeiden – Caddy wird für DNS-01 aber ohnehin per `xcaddy` gebaut. Und: Tunnel-Traffic kommt aus Sicht des Caddy-Hosts von den **cloudflared-Container-IPs**, nicht vom echten Client → ein Firewall-Bouncer kann Angreifer über den Tunnel **nie** sperren (und cloudflared-IPs zu sperren würde alle Tunnel-Dienste killen; private IPs whitelistet CrowdSec standardmäßig). Daher: **Caddy-Bouncer-Modul** (`hslatman/caddy-crowdsec-bouncer`) mit ins Binary, Caddy wertet per `trusted_proxies` (nur cloudflared-a/-b) den Header `Cf-Connecting-IP` als echte Client-IP aus → Log und Sperre greifen am echten Client. Firewall-Bouncer optional zusätzlich für SSH/Portforward.
    - **Jellyfin + CrowdSec:** Fehlgeschlagene Jellyfin-Logins stehen im **Jellyfin-Log**, nicht in Caddys Log → Collection `LePresidente/jellyfin` braucht einen CrowdSec-Agent dort, wo Jellyfin läuft (Unraid, als Container), registriert an der LAPI auf dem Caddy-Host (`cscli machines add`); gesperrt wird zentral vom Caddy-Bouncer. Damit ist der Fall „mehr als ein Host profitiert" für die zentrale Instanz erreicht. Voraussetzung: in Jellyfin unter *Netzwerk → Known Proxies* die Caddy-IP eintragen, sonst loggt Jellyfin nur Caddys IP statt der des Angreifers.
- nebula-sync via Ansible auf Unraid ausrollen. Zusammenspiel mit den Pi-hole-DNS-Einträgen klären: nebula-sync repliziert aktuell die Pi-hole-v6-Config (Teleporter) vom Primary (`172.16.10.40`) auf die Secondaries. Schreibt Ansible die DNS-Config (`pihole_cname_records` / `pihole_dns_hosts` in `group_vars/dns_resolvers.yml`) deklarativ auf **alle** Instanzen, wird nebula-sync überflüssig – sofern keine manuellen UI-Änderungen mehr passieren. Kein Cronjob: Playbook bei Änderung laufen lassen (git → CI/Hand). nebula-sync erst entfernen, wenn „keine manuellen Pi-hole-Edits" als Regel steht.

### Querschnitt

- **Service-Registry (Self-Registration)** – **freigegeben 2026-09-16**, Umsetzung nach Caddy + CrowdSec. Plan: `docs/service-registry-plan.md`. Jeder Dienst-Host trägt einen Steckbrief (`service:` mit `subdomain`/`port`/`exposure`/…) in seinen `host_vars`; `group_vars/all` sammelt daraus per `hostvars` eine Liste, die Konsumenten filtern. Konsumenten in dieser Reihenfolge: Caddy → Pi-hole → cloudflared + CF-DNS → Gatus. Später: Authentik (`forward_auth` + Blueprints), evtl. Dashboard/VictoriaMetrics. Unraid-Container als reine Daten-Hosts (eigene Gruppe, die kein Play anspricht) – löst die frühere Bedingung „alle Dienste im Inventory". Stolperfallen: `--limit` überspringt Konsumenten-Plays; CF-DNS-Einträge werden nicht automatisch gelöscht (`state: absent` nötig); Pi-hole-Records deklarativ (ganze Liste ersetzen). Regel bleibt: kuratierte Liste vs. Self-Registration entscheidet sich an der Zahl der Konsumenten – hier vier.

- **`--tags` erreicht keine Rolle, die per `include_role` eingebunden wird** (z.B. in `container_site.yml`, Task „Service-Rolle anwenden"), solange diese Include-Task selbst kein passendes `tags:` trägt. Ansible prüft den Tag-Filter zuerst am `include_role`-Task – matcht der nicht, wird gar nicht erst in die Rolle reingeschaut, selbst wenn Tasks dort drin den gesuchten Tag haben (z.B. `caddy-config`). Betroffen: gezieltes Nachziehen einzelner Config-Änderungen über `container_site.yml --tags <rolle>-config` funktioniert nicht, nur der volle Lauf. Fix wäre `apply: {tags: [...]}` am `include_role` oder Umstieg auf statisches `roles:`, aber das beträfe alle Rollen gleichzeitig – erstmal nur gemerkt, nicht behoben.

### Werkzeuge / Meta

- Terraform evaluieren: nach Fertigstellung `site.yml`, isoliert, Cloudflare (DNS/Tunnel) als erster Fall, dann UniFi, später ggf. Gast-Erstellung. Einstieg: `docs/terraform-evaluation.md`
- Semaphore UI evaluieren: Web-UI + Scheduler für Ansible-Läufe, statt `ansible-playbook` immer von Hand vom Mac aus zu starten. Konkreter erster Anwendungsfall: der wiederkehrende CrowdSec-Hub-Update-Job (siehe Caddy/CrowdSec-Punkt oben), später evtl. auch periodische `site.yml`-Konvergenz-Läufe.
- Versionen pinnen und Updates verfolgen: zentrale `versions.yml` (Anfang steht), Benachrichtigung über newreleases.io/RSS, später Renovate (Dependency Dashboard + Changelog-PRs), optional HTML-Dashboard mit Repo-vs-installiert-Abgleich. Strategie: `docs/version-tracking.md`
  - Betrifft auch alle apt-Repo-Rollen (`cloudflared`, `grafana`, …): installieren aktuell unversioniert (`state: present` ohne `=version`), ziehen also bei jedem Lauf potenziell die neueste Repo-Version. Bewusst zurückgestellt, bis diese zentrale Versionsverwaltung steht – dann in einem Rutsch für alle apt-Rollen nachziehen, nicht Rolle für Rolle einzeln pinnen.
