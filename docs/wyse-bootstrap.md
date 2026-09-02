# Wyse „Mustafar" – Bootstrap & Migrationsplan

Handoff-Dokument. Der Proxmox-Cluster-Teil (`site.yml` gegen beide PVE-Nodes) ist
durch und committet. Nächster Schritt: den Wyse unter Ansible-Verwaltung bringen.

Verwandte Docs: `playbook-architecture.md`, `disk-prep.md`, `cluster-join-runbook.md`.

---

## 1. Was Mustafar ist

- **Dell Wyse 3040**, Debian 13 (trixie), Kernel 6.12, eMMC **~7,3 GB**, 2 GB RAM,
  Atom x5. IP **172.16.10.60**, `system_hostname: Mustafar`.
- **Bewusst außerhalb des Proxmox-Clusters** – „Independence-Tier": DNS,
  Monitoring und Cluster-Quorum sollen einen kompletten Proxmox-Ausfall überleben.
- Docker-Host für: Secondary Pi-hole, eigener Unbound, Uptime Kuma, node-exporter.
- **corosync-qnetd** (QDevice fürs 2-Node-Cluster) läuft hier bereits – vom
  `pvecm qdevice setup 172.16.10.60`. **Nicht kaputt machen.**
- Zugang: `benedikt@172.16.10.60` per SSH (persönlicher User, mit sudo).
  Ein Ansible-`ansible`-User existiert noch **nicht**. In `/root/.ssh/authorized_keys`
  liegt nur Alderaans root-Key (vom qdevice-Setup), **nicht** der Control-Key.

### Bestandsaufnahme (Stand Discovery)

- **Keine eMMC-Entlastung aktiv**: kein `log2ram`/`zram`/`folder2ram`, fstab
  Standard (kein `noatime`), journald **persistent**, **Swap auf der eMMC**
  (`mmcblk0p3`, 754 MB). Das früher mal eingestellte ging bei einer Neuinstallation
  (~2026-08) verloren.
- **USB-SSD-Saga (2026-08-20)**: geplante 64-GB-USB-SSD als Docker data-root nach
  3 Disconnect-/0-Byte-Vorfällen verworfen (Verdacht: USB-Power am Wyse-Port;
  Platte/Kabel/Enclosure am MacBook sauber). Docker läuft jetzt direkt auf eMMC,
  fstab-Eintrag nur auskommentiert. → **kein verlässlicher externer Storage.**
- **Docker-Container**: `pihole` (:53/:80), `unbound` (`dns_net` 172.28.0.0/24,
  rekursiv), `uptime-kuma` (:3001), `node-exporter` (:9100).
- **`/etc/resolv.conf`**: `nameserver 1.1.1.1` + `nameserver 172.16.10.40` –
  bewusst **nicht** `127.0.0.1`, damit der Host nicht von seinem eigenen
  Pi-hole-Container abhängt.
- **Deploy bisher**: kein `git clone` auf dem Host, stattdessen
  `./scripts/deploy.sh mustafar` (rsync), `secrets.env` nur lokal.
- Gelöste Docker-Bugs (Doku, nicht neu aufreißen): Unbound-Port war 5335 statt 53;
  Pi-hole „ignoring query from non-local network" → „Listen on all interfaces,
  permit all origins" (Docker-NAT); doppelte Bridge-Netze mit gleichem Subnetz →
  kompletter Reboot löst es.
- **Monitoring-Konzept**: mustafar-Kuma ≠ LXC-204-Kuma. Nur Backup-Heartbeats +
  Grundinfra-Pings, keine Doppelüberwachung.

---

## 2. Entscheidung: Docker vs. bare-metal

Für 7,3 GB eMMC / 2 GB RAM / Failsafe-Tier: **komplett bare-metal.** Kein
Container-Runtime auf dem Host.

| Dienst | Ziel | Begründung |
|---|---|---|
| **node-exporter** | **bare-metal** – vorhandene `node_exporter`-Rolle | Container ist reiner Overhead; löst nebenbei den `:9100`-Konflikt |
| **unbound** | **bare-metal** – `apt install unbound` + Config-Template | trivial nativ; kein `dns_net`-NAT, keine der o.g. Docker-Bugs mehr |
| **uptime-kuma** | **durch Gatus ersetzen** (Go-Binary + YAML) | Scope ist eh nur Infra-Pings/Heartbeats = Gatus' Kerngebiet; YAML passt zu Ansible; steht im README-ToDo |
| **Pi-hole** | **bare-metal** – Pi-hole v6 | v6 ist ein einzelnes FTL-Binary mit eingebautem Webserver – kein lighttpd/php/dnsmasq-Gefrickel mehr, das den Installer früher un-idempotent machte. `pihole.toml` als Template, Rest wie die Container-Variante. |

**Ergebnis:** alles systemd + Ansible-Rollen, **kein Docker/Podman** auf dem Wyse.
Podman + Quadlet war ein Zwischenschritt (kurz liefen `pihole` und `gatus` so) –
fällt mit Pi-hole v6 bare-metal und dem Gatus-Binary weg.

---

## 3. Bootstrap-Ablauf

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

- `zram-tools` → Swap in komprimiertem RAM statt `mmcblk0p3`
  (danach die Swap-Partition aus fstab, ggf. `swapoff`)
- journald: `Storage=volatile` **oder** `SystemMaxUse=50M` (drop-in unter
  `/etc/systemd/journald.conf.d/`)
- `noatime` in `/etc/fstab` für `/`
- falls Docker bleibt: `/etc/docker/daemon.json` →
  `{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}`

### Dienst-Migration

1. **unbound bare-metal**: `apt install unbound`, Config-Template
   (rekursiv, wie die Container-Variante), Port 53 auf der/den passenden
   Adresse(n). Docker-`unbound` + `dns_net` weg.
2. **node-exporter bare-metal**: `node_exporter`-Rolle auf den Wyse anwenden,
   Docker-`node-exporter` weg.
3. **Gatus statt uptime-kuma**: Binary + `config.yaml` (Endpoints = Infra-Pings,
   Backup-Heartbeats), systemd-Unit. `gatus`-Rolle mit `gatus_deployment: baremetal`
   in `host_vars/wyse-3040.yml` (Default der Rolle ist `container`). Podman-Quadlet
   `gatus` weg.
4. **Pi-hole bare-metal (v6)**: FTL per Paket-Repo, `pihole.toml` +
   Custom-DNS/CNAME-Records aus Vault bzw. `group_vars` templaten, statt
   `deploy.sh`-rsync. „Kein git clone auf dem Host" bleibt – Ansible pusht die
   Dateien. Danach Podman-Quadlet `pihole` + `/var/lib/pihole` entfernen.
5. **Container-Runtime abbauen**: sobald `pihole` und `gatus` bare-metal laufen,
   `podman` deinstallieren, `/etc/containers/systemd/` aufräumen, `wyse-3040` aus
   `docker_hosts` nehmen. Die `docker_host`-Rolle greift dann nicht mehr.

### Inventory-Endzustand

- `wyse-3040` in `debian_machines` (bekommt `common` + `hardening`)
- `wyse-3040` **nicht mehr** in `docker_hosts` (kein Container-Runtime mehr)
- eigene Gruppe/Playbook für den Failsafe-Stack (unbound, gatus, pihole,
  node-exporter) – analog zu `06_monitoring.yml`
- `pve_qdevice` bleibt (nur Doku, das Setup selbst ist manuell im
  `cluster-join-runbook.md`)

---

## 5. Nicht vergessen

- `secrets.env` / Vault: Pi-hole-Webpassword, ggf. Gatus-Tokens → in
  `group_vars/all/vault.yml` bzw. `host_vars`.
- Der Wyse soll **keinen** `resolv.yml`-Zugriff kriegen und **nicht** in
  `dns_resolvers`-abhängige Templates rutschen, die ihn auf sich selbst zeigen.
- corosync-qnetd-Paket + `/etc/corosync/qnetd/nssdb` sind heilig – bei einem
  etwaigen OS-Neuaufbau des Wyse muss danach `pvecm qdevice remove` +
  `pvecm qdevice setup 172.16.10.60` von einer PVE-Node laufen.
