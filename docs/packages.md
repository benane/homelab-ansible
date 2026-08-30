# Paket- und Monitoring-Strategie

Lern- und Referenzdokument. Kein fertiger Code, sondern die Denkweise: **welches
Paket gehört auf welche Maschine, wo im Repo wird das entschieden, und wann im
Ablauf passiert es.**

Ergänzt `docs/playbook-architecture.md` (die die Playbook-Phasen und den
Rollen-Aufbau erklärt).

---

## 1. Grundsatz: drei Paket-Ebenen

| Ebene | Frage | Wo im Repo | Beispiele |
|---|---|---|---|
| **Basis** | Was braucht *jedes* OS zum vernünftigen Arbeiten? | `roles/common/defaults/main.yaml` → `common_base_packages` | `sudo`, `curl`, `wget`, `git`, `htop`, `python3` |
| **Rollen-spezifisch** | Was braucht *diese Aufgabe* / *dieser Host-Typ*? | `roles/<rolle>/tasks/packages.yml` | `lm-sensors` (nur PVE-Nodes), `docker-ce` (nur docker_hosts) |
| **Dienst** | Ein eigenständiger Daemon mit Config, Port, Lifecycle | eigene Rolle | `node_exporter` |

**Merksatz:** `common` bleibt klein. Sobald ein Paket nur für einen Host-Typ
oder eine Aufgabe relevant ist, gehört es in die passende Rolle – nicht in
`common`. Jedes Paket ist Angriffsfläche, apt-Zeit und ein potentieller
Update-Breaker.

Ein Dienst (eigener Prozess, eigene Config-Datei, eigener Port) ist mehr als ein
Paket und bekommt eine **eigene Rolle**, damit man ihn pro Gruppe an- und
abschalten kann.

---

## 2. Monitoring: warum Node Exporter raus aus `common` musste

Vorher stand `prometheus-node-exporter` in `common_base_packages`. Weil
`00_bootstrap.yml` die `common`-Rolle auf `bare_metal` **und**
`virtual_machines` anwendet (und `lxc_containers` ein Kind von
`virtual_machines` ist), landete der Exporter auf **jedem** Host – auch auf
jedem LXC.

Probleme dabei:

- ein zusätzlicher Prozess **und** ein zusätzliches Scrape-Target pro Container
- die Metriken sind im LXC teils **falsch oder host-weit** (Dateisysteme, Load,
  teilweise RAM), weil der Container sich den Kernel mit dem Host teilt
- die Container-Kernwerte (CPU / RAM / Disk / Netz) liefert der
  **PVE-Exporter** ohnehin schon sauber von außen über die Proxmox-API

Deshalb: Node Exporter ist ein Dienst → **eigene Rolle `node_exporter`**, die
gezielt auf einer Inventory-Gruppe läuft.

### Wo läuft der Node Exporter – und wo nicht

Kriterium: *„Ist das ein vollständiges OS, das sonst niemand von außen misst?"*

| Host-Typ | Node Exporter? | Begründung |
|---|---|---|
| Proxmox-Nodes (Bare Metal) | **ja** | echte Hardware: Temperaturen, Disks, NICs. PVE-Exporter liefert nur die PVE-Sicht (Gäste, Storage, Cluster), nicht die OS-/Hardware-Tiefe |
| SBCs (`rpi-dns`, `rpi-klipper`) | **ja** | misst sonst niemand |
| Thin Client (`wyse-3040`) | **ja** | misst sonst niemand |
| QEMU-VMs (`vm-hassio`) | **ja**, *sofern es ein apt-fähiges OS ist* | aus Kernel-Sicht ein echtes OS → Metriken stimmen. Bei **Home Assistant OS** kommt der Exporter stattdessen über das HA-Add-on, nicht über Ansible → dann **nicht** in die Gruppe |
| LXC-Container | **nein** (Default) | PVE-Exporter deckt CPU/RAM/Disk/Netz ab; In-Guest-Werte sind teils irreführend |
| Unraid-NAS | **nein** (hier) | eigenes Exporter-Plugin auf Unraid |

**Opt-in-Ausnahme:** Braucht *ein einzelner* Container mal In-Guest-Prozess-
oder Textfile-Metriken, nimmt man **genau diesen** Host in `monitoring_targets`
auf – nicht pauschal alle.

### Umsetzung im Repo

```
roles/node_exporter/tasks/main.yml     # apt install + systemd enable/started

inventory/hosts.yml:
  monitoring_targets:
    children:
      proxmox_nodes:
      single_board_computers:
      thin_clients:
      qemu_vms:          # nur wenn vm-hassio apt-fähig ist – sonst entfernen

playbooks/03_monitoring.yml            # hosts: monitoring_targets, roles: [node_exporter]
```

**Reihenfolge:** nach `01_security_hardening.yml` (SSH/Firewall stehen) und nach
dem Gast-Setup (Gäste existieren). Als späte Querschnitts-Phase gehört die
Nummer eher ans Ende (`06_`/`07_`) statt `03_`, wo laut Architektur-Doc schon
`proxmox_cluster` geplant ist. Danach in `site.yml` einhängen, sonst läuft die
Phase nur beim direkten Aufruf.

### Erweiterungspunkt (später)

Bewusst noch nicht drin, aber der natürliche nächste Schritt in derselben Rolle:

- `defaults/main.yml` + Template für `/etc/default/prometheus-node-exporter`
  (Collector an-/abschalten, `--collector.textfile.directory=…`)
- Firewall-Regel, die Port 9100 **nur** für den VictoriaMetrics-Host öffnet
  (entweder hier oder als Variable, die die `hardening`-Rolle liest)

---

## 3. `lm-sensors` und Hardware-Pakete auf den Proxmox-Nodes

Nur sinnvoll auf **echter Hardware** – VMs und LXC haben keine Sensoren. Gehört
also in `roles/proxmox_node/tasks/packages.yml` (analog zu `repos.yml`,
`storage.yml` …), eingehängt in `roles/proxmox_node/tasks/main.yml`.

> ⚠️ Eine Task-Datei mit *nur Kommentaren* ist leer – `import_tasks` darauf gibt
> eine Warnung/Fehler. Es muss mindestens ein echter Task drin sein.

### Zusammenspiel mit dem Node Exporter

Der Node Exporter hat den `hwmon`-Collector **standardmäßig an**. Er exportiert
`node_hwmon_temp_celsius`, **sobald die passenden Kernel-Module geladen sind**
(Intel-CPU: `coretemp`; viele Boards zusätzlich ein Super-I/O-Chip wie
`nct6775`).

`lm-sensors` selbst exportiert nichts an Prometheus – es liefert das
`sensors`-CLI und `sensors-detect`, um herauszufinden, **welche Module** dein
Board braucht.

Ablauf:

1. `lm-sensors` per Ansible installieren
2. **einmalig manuell** auf jedem Node `sensors-detect` laufen lassen (ist
   interaktiv, lässt sich nicht sinnvoll automatisieren)
3. die dabei genannten Modulnamen per Ansible nach
   `/etc/modules-load.d/lm-sensors.conf` schreiben (Template/`copy`)
4. nach Reboot bzw. `modprobe` tauchen die Temperaturen automatisch im Node
   Exporter auf

### Kandidaten-Pakete pro Zweck

**Nur Proxmox-Nodes** (`roles/proxmox_node/tasks/packages.yml`):

| Paket | Wofür |
|---|---|
| `lm-sensors` | CPU-/Board-Temperaturen |
| `smartmontools` | SMART-Disk-Health (`smartctl`); Werte via Node-Exporter-Textfile-Collector oder separatem `prometheus-smartctl-exporter` |
| `nvme-cli` | nur falls NVMe verbaut (bei uns: ja, ZFS-Pool auf NVMe) |
| `ethtool` | NIC-Diagnose, wird auch vom `ethtool`-Collector des Node Exporters genutzt |
| `zfs-zed` | ZFS-Event-Daemon für Alerts bei Pool-Fehlern – bei PVE meist schon installiert, aber Enable prüfen |
| `ipmitool` / `freeipmi-tools` | **nur** wenn das Board ein BMC/IPMI hat (Consumer-Boards nicht) |

**Alle vollen OS-Instanzen** (Kandidaten für `common` oder eine eigene
`base_extras`-Rolle, wenn `common` sonst zu voll wird):

`ca-certificates`, `rsync`, `vim`/`nano`, `tmux`, `dnsutils` (`dig`),
`mtr-tiny`, `jq`, `chrony` (Zeitsync – bei PVE dabei, auf SBCs/Wyse prüfen).

**Nur VMs:** `qemu-guest-agent` (gehört in die künftige `proxmox_vm`- bzw.
`qemu_vm`-Rolle, nicht in `common`).

---

## 4. Entscheidungs-Checkliste für „wohin mit einem neuen Paket?"

1. **Braucht es wirklich *jede* Maschine** (inkl. LXC), um brauchbar zu sein?
   → `common_base_packages`. Sonst nächste Frage.
2. **Ist es an einen Host-Typ gebunden** (nur PVE, nur Docker-Hosts, nur VMs)?
   → `roles/<passende-rolle>/tasks/packages.yml`.
3. **Ist es ein eigenständiger Daemon** mit Config-Datei / Port / Service?
   → eigene Rolle, gezielt über eine Inventory-Gruppe + eigene Playbook-Phase.
4. **Läuft es nur auf Hardware** (Sensoren, SMART, IPMI)?
   → `proxmox_node` (bzw. eine `bare_metal`-Rolle), nie auf VM/LXC.

---

## 5. Offene Punkte

- [ ] `roles/proxmox_node/tasks/packages.yml` mit echtem apt-Task füllen
      (`lm-sensors`, Rest als Kommentar in der Liste)
- [ ] `sensors-detect` auf beiden Nodes einmalig ausführen, Module in
      `/etc/modules-load.d/` per Ansible fixieren
- [ ] `03_monitoring.yml` umbenennen (späte Nummer) und in `site.yml` einhängen
- [ ] `vm-hassio` klären: apt-fähiges OS oder HAOS? Ggf. aus `monitoring_targets`
      (und aus `virtual_machines`-basierten Bootstrap-Phasen) nehmen
- [ ] `node_exporter`: `defaults/main.yml` + `/etc/default`-Template, Firewall-Port
      nur für den VictoriaMetrics-Host
