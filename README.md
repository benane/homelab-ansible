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
- Proxmox-API-Token und Berechtigungen automatisch anlegen, statt als Handschritt
- Wrapper-Script für Container-Erstellung (kapselt `--limit <host>` und beim ersten Lauf `-u root`, gegen Tippfehler)
- `container_vmid` dynamisch (nächste freie ID ab 201): **zurückgestellt**, bis die ganze Kette (Monitoring, Tunnel, DNS, Reverse Proxy) einen Rebuild automatisch nachzieht – sonst mehr Nacharbeit als Nutzen, und Rebuilds werden nicht-deterministisch.
- Container-Provisioning: Rolle `proxmox_container` steht (create/template/metadata; Node/Storage inventory-gesteuert via `container_node` / `container_storage`, Fallback `proxmox_default_*` in `group_vars/all/proxmox.yml`). **Offen:** schlankes `guest_site.yml`, das LXC- vs. VM-Rolle wählt und danach `common` + `hardening` + Service-Rolle anhängt; analoge Rolle `proxmox_vm`. Service-Rollen bleiben eigenständig. Details: `docs/playbook-architecture.md`
- LXC 208 (`lxc-nginx-proxy`), 213 (`lxc-authentik`) und die HA-VM (`vm-hassio`) laufen physisch auf `Corellia`, im Inventory nur IP-Stubs. Beim Reproduzieren per Ansible: `container_vmid` / `container_role` / `container_node: Corellia` / `container_storage: nvme-zfs` nachziehen.
- ESPHome-Container mit Pull der YAML-Configs aus GitHub-Repo

### Netzwerk & externe Dienste

- Cloudflared-Ingress → DNS: **erledigt** – Task `community.general.cloudflare_dns` in der `cloudflared`-Rolle (`become: false`, `delegate_to: localhost`, `run_once`) legt je Ingress-Eintrag mit `hostname` einen proxied CNAME auf `<tunnel-id>.cfargotunnel.com` an. Token `vault_cloudflare_api_token` (Zone→DNS→Edit). `service` via `cloudflared_default_origin` entdoppelt, `originServerName` entfällt (npm routet über Host-Header). Ableiten der Liste: siehe „Self-Registration".
- UniFi-Netzwerk-Config: `roles/unifi_network` ist nur ein Stub, das Playbook `0x_network_setup.yml` wurde gelöscht. Kommt via Terraform (reifer Provider `ubiquiti-community/unifi`, deklarativer Appliance-State) statt Ansible-`uri`-Gepokel.
- Reverse Proxy von NPM auf **Caddy** wechseln: NPMs Config liegt in einer SQLite-DB (nur UI/API), nicht versionierbar. Caddy = ein getemplatetes `Caddyfile`, automatisches HTTPS, `caddy reload` ohne Downtime, Single-Binary + systemd (gleiche Form wie die anderen Rollen). Bewusste Migration nach dem Monitoring-Paar: neuer Proxy hoch, alle Proxy-Hosts nachbauen, `cloudflared_default_origin` umbiegen, umschalten, NPM abbauen. Danach wird das `Caddyfile` aus derselben Liste generiert wie cloudflared-Ingress / Gatus / DNS → Anker für die „ein Fact, viele Konsumenten"-Kette (siehe „Self-Registration"). Traefik wäre die mächtigere, steilere Alternative (File-Provider).
- nebula-sync via Ansible auf Unraid ausrollen. Zusammenspiel mit den Pi-hole-DNS-Einträgen klären: nebula-sync repliziert aktuell die Pi-hole-v6-Config (Teleporter) vom Primary (`172.16.10.40`) auf die Secondaries. Schreibt Ansible die DNS-Config (`pihole_cname_records` / `pihole_dns_hosts` in `group_vars/dns_resolvers.yml`) deklarativ auf **alle** Instanzen, wird nebula-sync überflüssig – sofern keine manuellen UI-Änderungen mehr passieren. Kein Cronjob: Playbook bei Änderung laufen lassen (git → CI/Hand). nebula-sync erst entfernen, wenn „keine manuellen Pi-hole-Edits" als Regel steht.

### Querschnitt

- **Self-Registration abgeleiteter Listen** – zurückgestellt. Betrifft drei handgepflegte Listen: Gatus-Endpoints (`host_vars/lxc-gatus.yml`), cloudflared-Ingress (`group_vars/cloudflared_hosts.yml`), Pi-hole-DNS-Records (`group_vars/dns_resolvers.yml`). Bleiben kuratierte Handlisten, bis (a) alle Dienste Inventory-Hosts sind (u.a. Unraid-Container, evtl. via docker_compose) **und** (b) derselbe Fact mehrere Konsumenten speist (Tunnel + npm + DNS + Gatus). Sonst nur Kompromisse (ein Host ≠ ein Endpoint, Anzeige- ≠ Inventory-Gruppe) bei geringem Nutzen. Zielbild: verwaltete Dienste bringen ihre Spec als Daten selbst mit, Rolle sammelt + merged + hängt eine explizite externe Restliste an. Regel: kuratierte Liste vs. Self-Registration entscheidet sich an der Zahl der Konsumenten.

### Werkzeuge / Meta

- Terraform evaluieren: nach Fertigstellung `site.yml`, isoliert, Cloudflare (DNS/Tunnel) als erster Fall, dann UniFi, später ggf. Gast-Erstellung. Einstieg: `docs/terraform-evaluation.md`
- Versionen pinnen und Updates verfolgen: zentrale `versions.yml` (Anfang steht), Benachrichtigung über newreleases.io/RSS, später Renovate (Dependency Dashboard + Changelog-PRs), optional HTML-Dashboard mit Repo-vs-installiert-Abgleich. Strategie: `docs/version-tracking.md`
  - Betrifft auch alle apt-Repo-Rollen (`cloudflared`, `grafana`, …): installieren aktuell unversioniert (`state: present` ohne `=version`), ziehen also bei jedem Lauf potenziell die neueste Repo-Version. Bewusst zurückgestellt, bis diese zentrale Versionsverwaltung steht – dann in einem Rutsch für alle apt-Rollen nachziehen, nicht Rolle für Rolle einzeln pinnen.
