# Wyse „Mustafar" – Bootstrap & Migrationsplan

Handoff-Dokument. **Migration komplett abgeschlossen (Stand 2026-09-07).** Der
Wyse ist unter Ansible-Verwaltung (Bootstrap + Hardening durch, `ansible`-User +
Key-Login aktiv), eMMC-Entlastung/Unbound/node-exporter/Gatus/Pi-hole laufen alle
bare-metal, Docker und Podman sind vollständig von der Box runter. Dieses
Dokument bleibt als Referenz/Runbook stehen (z. B. für einen Re-Bootstrap).

Verwandte Docs: `playbook-architecture.md`, `disk-prep.md`, `cluster-join-runbook.md`.

---

## 1. Was Mustafar ist

- **Dell Wyse 3040**, Debian 13 (trixie), Kernel 6.12, eMMC **~7,3 GB**, 2 GB RAM,
  Atom x5. IP **172.16.10.60**, `system_hostname: Mustafar`.
- **Bewusst außerhalb des Proxmox-Clusters** – „Independence-Tier": DNS,
  Monitoring und Cluster-Quorum sollen einen kompletten Proxmox-Ausfall überleben.
- War Docker-Host für: Secondary Pi-hole, eigener Unbound, Uptime Kuma,
  node-exporter. Docker ist inzwischen komplett runter – siehe Bestandsaufnahme.
- **corosync-qnetd** (QDevice fürs 2-Node-Cluster) läuft hier bereits – vom
  `pvecm qdevice setup 172.16.10.60`. **Nicht kaputt machen.**
- Zugang: `ansible@172.16.10.60` per Key (`~/.ssh/id_ed25519_ansible`), Sudo ohne
  Passwort. Persönlicher User `benedikt` mit sudo bleibt als Fallback.
  `PasswordAuthentication no` + `PermitRootLogin prohibit-password` sind aktiv.

### Bestandsaufnahme (Stand 2026-09-07)

- **eMMC-Entlastung aktiv**: `zram-tools` läuft, Swap liegt auf `/dev/zram0`
  (965 MB, `zramswap.service`), die eMMC-Swap-Partition ist per `noauto` in der
  fstab stillgelegt (Marker `BEGIN/END ANSIBLE emmc_saver disk-swap`). `noatime`
  steht auf `/`. journald ist per Drop-in (`/etc/systemd/journald.conf.d/emmc.conf`)
  auf `SystemMaxUse=50M` gedeckelt (Storage bleibt `persistent`, nicht `volatile`).
  eMMC-Auslastung: 2,2 GB von 5,8 GB.
- **Docker ist komplett deinstalliert** (kein Paket, kein Binary mehr). Die
  USB-SSD-Idee von 2026-08-20 (Disconnect-/0-Byte-Vorfälle) ist damit erledigt
  gegenstandslos – kein externer Storage mehr nötig, alles läuft direkt auf eMMC.
- **Unbound, node-exporter (`prometheus-node-exporter`) und Gatus laufen bereits
  bare-metal**, aktiv, kein Podman-Quadlet mehr dafür. Uptime Kuma ist damit
  endgültig durch Gatus ersetzt.
- **Nur noch Pi-hole hängt in Podman**: `/etc/containers/systemd/pihole.container`
  existiert noch, das Quadlet lauscht via `--network host` auf `:53`/`:80`.
  `host_vars/wyse-3040.yml` setzt bereits `pihole_deployment: baremetal` – die
  passende `pihole`-Rolle (`playbooks/08c_pihole.yml`) ist fertig. Offen: alter
  Podman-Container abräumen, Installer von Hand laufen lassen, Rolle drüber.
  Ablauf siehe **Pihole-Cutover auf dem Wyse** unten.
- **Aufräumen im Inventory nötig**: `inventory/hosts.yml` hat am Host `wyse-3040`
  noch eine veraltete `pihole_deployment: container`-Zeile stehen (überschrieben
  von `host_vars/wyse-3040.yml`, aber inkonsistent) – gehört raus, siehe Schritt 1
  im Cutover unten.
- **`/etc/resolv.conf`**: `nameserver 1.1.1.1` + `nameserver 172.16.10.40` –
  bewusst **nicht** `127.0.0.1`, damit der Host nicht von seinem eigenen
  Pi-hole abhängt. Gilt unverändert auch nach dem Umzug auf bare-metal.
- Gelöste Docker-Bugs (Doku, nicht neu aufreißen – nur noch relevant falls je
  wieder Container auf dem Host laufen): Unbound-Port war 5335 statt 53;
  Pi-hole „ignoring query from non-local network" → „Listen on all interfaces,
  permit all origins" (Docker-NAT); doppelte Bridge-Netze mit gleichem Subnetz →
  kompletter Reboot löst es.
- **Monitoring-Konzept**: mustafar-Gatus ≠ LXC-204-Kuma. Nur Backup-Heartbeats +
  Grundinfra-Pings, keine Doppelüberwachung.

---

## 2. Entscheidung: Docker vs. bare-metal

Für 7,3 GB eMMC / 2 GB RAM / Failsafe-Tier: **komplett bare-metal.** Kein
Container-Runtime auf dem Host.

| Dienst | Ziel | Begründung | Status |
|---|---|---|---|
| **node-exporter** | **bare-metal** – vorhandene `node_exporter`-Rolle | Container ist reiner Overhead; löst nebenbei den `:9100`-Konflikt | ✅ erledigt |
| **unbound** | **bare-metal** – `apt install unbound` + Config-Template | trivial nativ; kein `dns_net`-NAT, keine der o.g. Docker-Bugs mehr | ✅ erledigt |
| **uptime-kuma** | **durch Gatus ersetzt** (Go-Binary + YAML) | Scope ist eh nur Infra-Pings/Heartbeats = Gatus' Kerngebiet; YAML passt zu Ansible | ✅ erledigt |
| **Pi-hole** | **bare-metal** – Pi-hole v6 | v6 ist ein einzelnes FTL-Binary mit eingebautem Webserver – kein lighttpd/php/dnsmasq-Gefrickel mehr, das den Installer früher un-idempotent machte. `pihole.toml` als Template, Rest wie die Container-Variante. | ✅ erledigt |

**Ergebnis:** alles systemd + Ansible-Rollen, **kein Docker/Podman** auf dem Wyse.
Podman + Quadlet war nur ein Zwischenschritt (kurz liefen `pihole` und `gatus` so)
– beide sind umgezogen, `podman` ist deinstalliert.

---

## 3. Bootstrap-Ablauf

**✅ Erledigt.** Der Ablauf unten ist als Referenz stehen gelassen (falls der Wyse
je neu aufgesetzt werden muss), ist aber bereits durchgelaufen: `ansible`-User +
Key-Login funktionieren, Hardening (`PasswordAuthentication no`,
`PermitRootLogin prohibit-password`) ist aktiv, `corosync-qnetd` unangetastet.

### 3.1 Voraussetzungen / Repo-Kontext

- `ansible.cfg`: `remote_user = ansible`, Key `~/.ssh/id_ed25519_ansible`,
  globales `become = True`.
- `playbooks/site.yml` hat einen **Guard**: bricht ohne `--limit` ab
  (`--limit all` für „alles, bewusst"). Reihenfolge: Guard → `00_bootstrap`
  (common) → `01_security_hardening` → `02_proxmox_setup` (nur `proxmox_nodes`) →
  `03_proxmox_cluster` (nur `proxmox_nodes`) → `06_monitoring`
  (`monitoring_targets`).
- `00`/`01` zielen auf Gruppe **`debian_machines`** (nach dem Scope-Fix – vorher
  `bare_metal, virtual_machines`).
- `common` legt auf Nicht-`proxmox_nodes` den `ansible`-User + sudo + Key an
  (`user.yml`, `include_tasks` mit `when: 'proxmox_nodes' not in group_names`).
- `resolv.yml` in `common` ist geguardet mit `when: dns_servers is defined` +
  kein Container.

### 3.2 Inventory-Änderungen

1. **`wyse-3040` in `debian_machines`** aufnehmen (unter `hosts:`, nicht
   `children:` – ist ein Host, kein Gruppenname).
2. **`dns_servers` darf für den Wyse NICHT definiert sein** → sonst überschreibt
   `resolv.yml` die bewusste `1.1.1.1 / 172.16.10.40`-Config und der Host hängt an
   seinem eigenen Pi-hole. Aktuell steckt `dns_servers` in
   `group_vars/proxmox_nodes.yml` → passt. Vor dem Lauf gegenprüfen, dass es nicht
   nach `group_vars/all/` gewandert ist.
3. **node-exporter-Konflikt lösen**: `06_monitoring.yml` würde
   `prometheus-node-exporter` per apt auf `:9100` installieren – da lauscht schon
   der Docker-node-exporter. Optionen:
   - Docker-node-exporter entfernen, bare-metal-Rolle übernehmen (Zielbild), **oder**
   - Wyse vorerst aus `monitoring_targets` raus (Gruppe enthält `thin_clients`).

### 3.3 `authorized_key`-Task check-fest machen

`--check` gegen einen jungfräulichen Host failt in
`roles/common/tasks/user.yml` bei „SSH-Public-Key … hinterlegen"
(`Either user must exist or you must provide full path to key file in check mode`)
– der `ansible`-User existiert im Check-Modus noch nicht. Fix (Option B):

```yaml
- name: SSH-Public-Key dynamisch aus ansible.cfg hinterlegen
  ansible.posix.authorized_key:
    user: ansible
    path: /home/ansible/.ssh/authorized_keys
    manage_dir: true
    state: present
    key: "{{ lookup('file', (ansible_private_key_file | expanduser) + '.pub') }}"
```

Der explizite `path` macht die Home-Auflösung überflüssig; `create_home: true` in
der User-Task legt `/home/ansible` beim echten Lauf an. (Alternative:
`when: not ansible_check_mode`.)

### 3.4 Erstlauf

Der Wyse ist **kein** `proxmox_nodes`-Member → `ansible_user: root` greift nicht.
Erstkontakt über den persönlichen User mit sudo:

```bash
ansible-playbook playbooks/site.yml --check --limit wyse-3040 -u benedikt -K   # optional, hat Lücken
ansible-playbook playbooks/site.yml        --limit wyse-3040 -u benedikt -K
```

`common` legt den `ansible`-User + Key an → **ab dem zweiten Lauf** ohne
`-u benedikt -K` (Default aus `ansible.cfg`). `hardening` setzt
`PasswordAuthentication no` + `PermitRootLogin prohibit-password` und startet sshd
neu – Key-Login als `ansible` funktioniert dann, Konsole als Fallback.

**Watch beim Erstlauf:**
- `hostname.yml`: Debian-Default hat `127.0.1.1 <host>` → wird entfernt und
  `172.16.10.60 Mustafar` gesetzt. Für einen Nicht-Cluster-Host kosmetisch,
  unkritisch.
- `resolv.yml`: muss **skippen** (siehe 3.2 Punkt 2).
- node-exporter: siehe 3.2 Punkt 3.
- corosync-qnetd / QDevice: `common`/`hardening` fassen das nicht an. Nach dem Lauf
  `pvecm status` (von einer PVE-Node) gegenchecken: weiter 3 Votes, beide Nodes
  `A,V,NMW`.

---

## 4. Danach – als Rollen abbilden

### `sbc_tweaks` / `emmc_saver` (eMMC-Schutz, unabhängig von Docker/bare-metal)

**✅ Erledigt** – alle vier Punkte sind auf dem Wyse aktiv (siehe Bestandsaufnahme):

- `zram-tools` → Swap in komprimiertem RAM statt `mmcblk0p3`
  (Swap-Partition per `noauto` aus der fstab-Automatik genommen)
- journald: `SystemMaxUse=50M` per Drop-in unter `/etc/systemd/journald.conf.d/`
- `noatime` in `/etc/fstab` für `/`
- Docker-Punkt (`daemon.json`) entfällt – Docker ist komplett runter, nie bare
  geblieben.

### Dienst-Migration

1. ✅ **unbound bare-metal**: läuft aktiv, kein Docker-`unbound`/`dns_net` mehr.
2. ✅ **node-exporter bare-metal**: `prometheus-node-exporter` aktiv, kein
   Docker-`node-exporter` mehr.
3. ✅ **Gatus statt uptime-kuma**: läuft aktiv als bare-metal-Service
   (`gatus_deployment: baremetal` in `host_vars/wyse-3040.yml`). Ablauf war
   **Gatus-Cutover auf dem Wyse** unten – als Referenz stehen gelassen.
4. ✅ **Pi-hole bare-metal (v6)**: `pihole-FTL` aktiv, Config über
   `pihole_deployment: baremetal` in `host_vars/wyse-3040.yml` +
   `08c_pihole.yml`-Rolle. Ablauf war **Pihole-Cutover auf dem Wyse** unten – als
   Referenz stehen gelassen.
5. ✅ **Container-Runtime abgebaut**: `podman` deinstalliert,
   `/etc/containers/systemd/` und `/var/lib/pihole` (altes Container-Volume) weg,
   `wyse-3040` aus `docker_hosts` in `hosts.yml` entfernt.

### Gatus-Cutover auf dem Wyse (Einmal-Handschritt)

**✅ Erledigt (2026-09-04ff., siehe Commits `a9a1bf4`/`852fc97`).** Gatus läuft
bare-metal, aktiv. Abschnitt bleibt als Vorlage für den Pi-hole-Umzug (gleiches
Muster) und für einen etwaigen Re-Bootstrap stehen.

Die `gatus`-Rolle beschreibt nur den **Zielzustand** (bare-metal Gatus läuft). Das
Abräumen des alten Podman-Containers ist eine Migrations-Handlung und steht
bewusst **nicht** in Ansible.

**Warum die Reihenfolge zählt:** Quadlet- und bare-metal-Pfad tragen denselben
Unit-Namen `gatus.service`. Solange der Container läuft, ist `gatus.service` für
systemd bereits *aktiv*; der Rollen-Task „Gatus aktivieren und starten"
(`state: started`) ist dann ein No-op und das Binary startet nie. Also erst den
Container komplett abräumen, dann die Rolle laufen lassen.

1. **Host-Var setzen und committen:** `gatus_deployment: baremetal` in
   `inventory/host_vars/wyse-3040.yml`.

2. **Auf dem Wyse den Container abräumen** (als root/sudo):

   ```bash
   systemctl stop gatus.service
   rm /etc/containers/systemd/gatus.container
   systemctl daemon-reload          # generierte Unit verschwindet aus /run/systemd/generator/
   systemctl status gatus.service   # muss jetzt "could not be found" sagen
   ```

3. **Rolle anwenden** (nur den Wyse, nicht `lxc-gatus` mittreffen):

   ```bash
   ansible-playbook playbooks/08a_gatus.yml --limit wyse-3040 --check --diff   # Sichtprüfung
   ansible-playbook playbooks/08a_gatus.yml --limit wyse-3040
   ```

   Die Rolle legt jetzt `/etc/systemd/system/gatus.service` frisch an und startet
   sie sauber – kein Schatten-Unit mehr aus dem Generator.

4. **Verifizieren:**

   ```bash
   systemctl cat gatus.service      # nur noch /etc/systemd/system/gatus.service
   systemctl status gatus.service   # active (running), User=gatus
   curl -s localhost:8080/health    # Gatus antwortet
   ```

5. **Podman-Reste entfernen:**

   ```bash
   podman ps -a                     # steht noch ein gestoppter 'gatus'-Container?
   podman rm gatus                  # falls ja
   podman rmi ghcr.io/twin/gatus:v5.36.0
   ```

   Das `podman`-Paket selbst bleibt vorerst – das fällt erst mit dem Pi-hole-Umzug
   (Punkt 5 der Liste).

### Pihole-Cutover auf dem Wyse (Einmal-Handschritt)

**✅ Erledigt (2026-09-07).** `pihole-FTL` läuft bare-metal, Podman/Quadlet/altes
Container-Volume sind weg, Inventory bereinigt (`pihole_deployment` lebt nur noch
in `host_vars/wyse-3040.yml`, `wyse-3040` ist aus `docker_hosts` raus). Blocklisten
kommen separat über Nebula-Sync vom Primary (`172.16.10.40`) – das ist kein Teil
dieses Cutovers. Abschnitt bleibt als Referenz stehen.

Wie bei Gatus beschreibt die `pihole`-Rolle nur den **Zielzustand** (bare-metal
`pihole-FTL` läuft, Config über `FTLCONF_*`-Env + Drop-in). Der Podman-Container
und der Installer-Lauf selbst sind Migrations-Handlungen, nicht Ansible.

**Warum die Reihenfolge zählt:** Der Podman-`pihole` hält `:53` und `:80`
(`Network=host`). Installer und `pihole-FTL` wollen dieselben Ports – also erst den
Container komplett abräumen, dann installieren. `baremetal.yml` hat einen `assert`
auf `/usr/bin/pihole-FTL`: läuft der Installer nicht vorher, bricht die Rolle mit
klarer Meldung ab (statt halb zu konfigurieren).

Der RPi-Primary (`172.16.10.40`) bleibt die ganze Zeit oben – der Wyse ist nur
Secondary. Trotzdem eine ruhige Zeit wählen; Clients mit nur einem DNS-Eintrag auf
`.60` sind währenddessen blind.

1. ✅ **Host-Var bereinigt:** `pihole_deployment: baremetal` lebt nur noch in
   `inventory/host_vars/wyse-3040.yml`; die veraltete
   `pihole_deployment: container`-Zeile am Host-Eintrag `wyse-3040` in
   `inventory/hosts.yml` (unter `thin_clients`) ist entfernt (wie `gatus_deployment`).

2. **Podman-Container abräumen** (root/sudo auf dem Wyse):

   ```bash
   systemctl stop pihole.service
   rm /etc/containers/systemd/pihole.container
   systemctl daemon-reload
   systemctl status pihole.service        # "could not be found"
   podman ps -a                           # gestoppter 'systemd-pihole'?
   podman rm systemd-pihole               # falls vorhanden
   podman rmi docker.io/pihole/pihole:2026.07.2
   ss -tulpn | grep -E ':53|:80'          # muss jetzt frei sein
   ```

3. **`systemd-resolved` prüfen:** hält es noch `:53` (`DNSStubListener`)? Auf dem
   Wyse ist `/etc/resolv.conf` schon bewusst statisch (`1.1.1.1` + `172.16.10.40`,
   nicht der `127.0.0.53`-Stub) – meist ist da nichts zu tun. Falls doch: Stub aus
   per Drop-in unter `/etc/systemd/resolved.conf.d/`. `/etc/resolv.conf` bleibt
   statisch – der Host darf **nicht** auf sein eigenes Pi-hole zeigen (Henne/Ei
   beim Boot).

4. **Installer von Hand:**

   **Achtung Stolperfalle:** Domain ist `pi-hole.net` **mit** Bindestrich.
   `pihole.net` (ohne Bindestrich) ist eine fremde, geparkte Domain und liefert
   einen kaputten/self-signed TLS-Handshake – sieht wie ein Netzwerkproblem aus,
   ist aber nur ein Tippfehler.

   ```bash
   curl -sSL https://install.pi-hole.net -o /tmp/pihole-install.sh
   less /tmp/pihole-install.sh            # einmal drüberschauen – root-Script
   sudo bash /tmp/pihole-install.sh
   ```

   Interaktive Fragen: Upstream-DNS / Blocklisten / DB-Tage / NTP sind egal – die
   überschreibt die Rolle gleich per `FTLCONF_*` (das Env hat Vorrang vor
   `pihole.toml`, auch fürs Admin-Passwort). Wichtig nur: Web-Interface aktivieren,
   Interface `eth0`, statische IP bestätigen.
   Danach: `systemctl status pihole-FTL.service` → active; `ss -tulpn | grep :53`
   → nur noch `pihole-FTL`.

5. **Rolle anwenden** (Playbook zielt auf `failsafe_hosts` = nur Wyse, `--limit`
   zur Sicherheit):

   ```bash
   ansible-playbook playbooks/08c_pihole.yml --limit wyse-3040 --check --diff
   ansible-playbook playbooks/08c_pihole.yml --limit wyse-3040
   ```

   Schreibt `/etc/pihole/pihole-FTL.env` +
   `/etc/systemd/system/pihole-FTL.service.d/override.conf`, dann `daemon-reload`
   + Restart über den Handler.

6. **Verifizieren:**

   ```bash
   systemctl cat pihole-FTL.service                        # Drop-in mit EnvironmentFile= sichtbar
   systemctl show pihole-FTL.service -p EnvironmentFiles    # zeigt /etc/pihole/pihole-FTL.env
   dig @127.0.0.1 example.com +short                        # Auflösung geht (unbound-Upstream)
   dig @172.16.10.60 doubleclick.net +short                # geblockt -> 0.0.0.0
   ```
   Web-UI: `http://172.16.10.60/admin`, Login mit dem Vault-Passwort.

7. **Podman endgültig weg** (jetzt läuft kein Container mehr auf der Box):

   ```bash
   apt-get purge --autoremove podman
   rm -rf /var/lib/pihole                 # alte Container-Volume-Daten
   rmdir /etc/containers/systemd 2>/dev/null || true
   ```

   Danach `wyse-3040` aus `docker_hosts` in `hosts.yml` nehmen. Damit ist
   „Podman verlässt die Box" abgehakt.

### Inventory-Endzustand

**✅ Erreicht.**

- `wyse-3040` in `debian_machines` (bekommt `common` + `hardening`)
- `wyse-3040` **nicht mehr** in `docker_hosts` (kein Container-Runtime mehr)
- eigene Gruppe/Playbook für den Failsafe-Stack (unbound, gatus, pihole,
  node-exporter) – analog zu `06_monitoring.yml`
- `pve_qdevice` bleibt (nur Doku, das Setup selbst ist manuell im
  `cluster-join-runbook.md`)

---

## 5. Nicht vergessen

- **Netzwerkweiter Secondary-DNS lief bisher NICHT über den Wyse.** Unifi-DHCP
  (alle 6 VLANs: Management, Servers, IoT, Guest, IoT untrusted, Clients) hatte
  einheitlich `dhcpd_dns_2 = 172.16.10.203` – das ist `lxc-pihole` (VMID 203, alte
  Helper-Script-Installation auf Alderaan), nicht der Wyse. Das unterlief den
  ganzen Sinn der Independence-Tier (Secondary stirbt bei Proxmox-Ausfall mit).
  Proxmox-Nodes und LXC-Container selbst waren davon nicht betroffen – die
  bekommen DNS schon korrekt über die Ansible-verwaltete `dns_resolvers`-Gruppe
  bzw. Vererbung vom Node. Fix (manuell in der Unifi-UI, Stand 2026-09-07 in
  Arbeit): `dhcpd_dns_2` in allen 6 VLANs auf `172.16.10.60` (Wyse) ändern,
  `.203` rausnehmen.
- **`lxc-pihole` (VMID 203) danach abbauen** – läuft vorerst weiter, ist aber
  ohne DHCP-Eintrag funktionslos für den Rest des Netzes. **Plan:** nach ein
  paar Tagen im Admin-Interface von 203 (Top Clients / Query-Log) prüfen, ob
  noch wer anfragt (z. B. Geräte mit altem DHCP-Lease oder manuell gesetztem
  DNS) – wenn nicht, LXC 203 abbauen.

- `secrets.env` / Vault: Pi-hole-Webpassword, ggf. Gatus-Tokens → in
  `group_vars/all/vault.yml` bzw. `host_vars`.
- Der Wyse soll **keinen** `resolv.yml`-Zugriff kriegen und **nicht** in
  `dns_resolvers`-abhängige Templates rutschen, die ihn auf sich selbst zeigen.
- corosync-qnetd-Paket + `/etc/corosync/qnetd/nssdb` sind heilig – bei einem
  etwaigen OS-Neuaufbau des Wyse muss danach `pvecm qdevice remove` +
  `pvecm qdevice setup 172.16.10.60` von einer PVE-Node laufen.
