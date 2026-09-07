# Gäste: Identität, Nummern, Platzierung

Lern- und Referenzdokument. Wie LXCs und VMs benannt, nummeriert und im Cluster
platziert werden – und **warum**, damit das Schema hält, wenn mehr dazukommt und
Container zwischen den Nodes wandern.

Verwandt: `playbook-architecture.md` (Rollen/Playbooks), `cluster-join-runbook.md`.

---

## 1. Die harten Regeln

1. **Die VMID ist cluster-weit und klebt für immer am Gast.** Sie darf **nichts
   Veränderliches kodieren** – keine Node, kein Storage, kein „Tier". Sonst lügt
   sie, sobald der Gast migriert wird (HA-Failover, manueller Move).
2. **Name == Dienst == Rollenname == Inventory-Key-Stamm.** `lxc-gatus` →
   `container_role: gatus` → `roles/gatus/`. Diese 1:1-Kette ist der eigentliche
   Gewinn – sie wird eisern durchgehalten.
3. **Platzierung lebt in Variablen, nie im Identifier.** Node und Storage stehen
   als `container_node` / `container_storage` in den host_vars. Einen Container
   verschieben heißt: eine Variable ändern + migrieren. VMID und Name bleiben.
4. **Lücken sind gratis.** Nie renummerieren „nur für Ordnung" – eine VMID-Änderung
   ist praktisch Neuanlegen (Replication-Job, HA-Ressource, Backup-Historie, jede
   IP-Referenz hängen dran).

Merksatz: **Die Nummer ist eine dumme, stabile ID. Bedeutung tragen Name, Pool
und Tags.**

---

## 2. VMID-Schema

### LXC im Management-LAN (`172.16.10.0/24`)

**VMID = letztes Oktett der statischen IP.** Bereich **200–254**. Damit hängen
VMID, IP und DNS zusammen – kein Kopfrechnen beim Debuggen.

| Band | Pool / Zweck | Beispiele |
|---|---|---|
| **201–210** | `core` – Zugangs- & Cluster-Infra: Ingress-Proxy, Tunnel, Auth, interne DNS-/PKI-Helfer | npm, cloudflared, authentik |
| **211–220** | `observability` – Monitoring, Metrics, Logs, Dashboards | gatus, victoriametrics, grafana |
| **221–230** | `smarthome` – MQTT, Zigbee, ESPHome, Matter/Z-Wave-Bridges | mosquitto, zigbee2mqtt |
| **231–240** | `apps` – Nutzer-/Produktiv-Apps: Dokumente, Passwörter, Energie, sonstiges Web | paperless, vaultwarden, wattwarriors |
| **241–250** | `media` – *arr, Request-Frontends, Downloader (falls je von Unraid runter) | – |
| **251–254** | `scratch` – Wegwerf, PoC, kurzlebig | – |

Läuft ein Band voll, wird es nach oben verlängert (260–269 usw.), nicht
gequetscht.

### VMs

**VMID 101–109.** Ist die VM single-homed im Management-LAN: `3` + IP-Oktett
(`vm-hassio` → `101` @ `172.16.10.11`). IP-Bereich für VMs: `.11–.19`. VMs sind
selten und haben ggf. mehrere NICs – die Oktett-Kopplung ist hier „nice to have",
keine Pflicht.

### „Nächste freie nehmen"?

Ja – aber die **nächste freie im passenden Band**, bewusst gewählt. Nicht
`pvesh get /cluster/nextid` blind, das zerreißt die IP-Kopplung.

---

## 3. Namen

- **Inventory-Key:** `lxc-<dienst>` bzw. `vm-<dienst>`. Das Präfix trennt in der
  Inventory sauber LXC von VM.
- **`system_hostname`:** funktionaler Kurzname (`gatus`, `paperless`). Die
  Star-Wars-Planeten bleiben den physischen „Haustieren" vorbehalten (Alderaan,
  Corellia, Hoth …) – Container sind Vieh, kriegen Zweck-Namen. Sonst gehen dir
  die Planeten aus und der Name verdeckt die Funktion.
- **Mehrere Instanzen einer Rolle:** `lxc-<dienst>-a` / `lxc-<dienst>-b`, beide
  mit demselben `container_role`. Die Rolle muss dann replica-safe sein
  (identische Config, keine „ich bin primary"-Annahme).
- Hostnamen: klein, keine Umlaute, `-` statt `_`.

---

## 4. Tags

Kontrolliertes Vokabular, an die Bänder angelehnt. Ein Bereichstag + beliebig
viele Fähigkeitstags:

- **Bereich:** `core`, `observability`, `smarthome`, `apps`, `media`, `scratch`
- **Fähigkeit:** `ingress`, `tunnel`, `auth`, `mqtt`, `zigbee`, `metrics`, `logs`,
  `status`, `backup-source`, `ha-replica`, `hw-bound`

Bestehende `container_tags` werden bei Gelegenheit angeglichen, nicht in einem
Rutsch.

---

## 5. Platzierung: Node, Storage, Verfügbarkeit

### Variablen

- `container_node` – bevorzugte Node (host_var). Default-Verteilung grob 50/50,
  aber **explizit pro Gast**, mit Grund im Kommentar.
- `container_storage` – Ziel-Storage (wird dynamisch aufgelöst, siehe
  `playbook-architecture.md` / Bootstrap-Playbook).

### Anti-Affinität

- **Replica-Paare** (`-a` / `-b`) laufen **immer auf verschiedenen Nodes**.
- Dienste, die zusammen einen Ausfallpfad bilden (z. B. zwei DNS-nahe Container),
  nicht auf dieselbe Node.

### Welches Verfügbarkeitsmodell für welchen Diensttyp

| Typ | Modell | Beispiele |
|---|---|---|
| **Stateful, Einzelinstanz** (DB, Verlauf, Pairings) | Proxmox-HA + ZFS-Replication (Intervall ≤ 15 min) | authentik, paperless, vaultwarden, grafana, victoriametrics, zigbee2mqtt |
| **Stateless / nur Config** | **2 Instanzen auf verschiedenen Nodes, KEIN Proxmox-HA, KEINE Replication** | cloudflared |
| **Hardware-gebunden** (lokaler USB-Dongle) | an eine Node gepinnt, HA nicht möglich | – (SLZB-06 hängt am LAN, daher ist z2m *nicht* hw-gebunden) |

Merksatz: **Proxmox-HA ist für Dienste, die man nicht zweimal laufen lassen kann.**
Wenn die Software nativ Multi-Replica kann (cloudflared), ist „zweimal starten"
besser als Failover-Restart – null Ausfalllücke, nichts zu replizieren, keine
Abhängigkeit vom HA-Manager.

---

## 6. Proxmox Pools

Ein Pool pro Bereich: `core`, `observability`, `smarthome`, `apps`, `media`,
`scratch`. Pool == Band, aber **node-unabhängig**: die UI gruppiert danach, Rechte
folgen dem Pool. Damit ist die VMID-Reihenfolge nur noch kosmetisch.

Pools kann man **sofort und rückwirkend** setzen (reine Metadaten, kein Stop, kein
Risiko) – das ist der billige Weg, Ordnung in den Bestand zu bringen, ohne eine
einzige VMID anzufassen.

Neuer Gast: Pool zuweisen ist Pflicht.

---

## 7. Bestand vs. Schema (Stand 2026-09)

Der Bestand liegt **quer zu den Bändern** – historisch nach Erstell-Reihenfolge
vergeben. Das ist ok und wird **nicht angefasst**. Ab hier gilt: neue Gäste ins
passende Band, Pools rückwirkend setzen.

| VMID | Name | Ziel-Pool | Anmerkung |
|---|---|---|---|
| 201 | lxc-mosquitto | smarthome | bleibt |
| 202 | lxc-zigbee2mqtt | smarthome | bleibt |
| 203 | lxc-pihole | – | wird aufgelöst (bare-metal-Umzug), 203 wird frei |
| 205 | lxc-vaultwarden | apps | bleibt |
| 206 | lxc-gatus | observability | bleibt |
| 207 | lxc-paperless | apps | bleibt |
| 208 | lxc-nginx-proxy | core | bleibt |
| 209 | lxc-victoriametrics | observability | bleibt |
| 210 | lxc-grafana | observability | bleibt |
| 211 | lxc-wattwarriors | apps | bleibt |
| 212 | lxc-cloudflared | core | bleibt; Band-Fremdlage geduldet |
| 213 | lxc-authentik | core | bleibt |

**Neue Instanz eines bestehenden, band-fremden Dienstes:** kommt **neben die
erste** (Nähe schlägt Band), nicht ins theoretisch richtige Band. Also
`lxc-cloudflared-b` → **214**, nicht 20x.

Freie Slots im 172.16.10-LAN: `.203`, `.204`, `.214`, ab `.215` aufwärts.

---

## 8. Checkliste – neuer Gast

1. **Band** wählen → freies Oktett im Band → das ist VMID **und** IP-Oktett.
2. Key `lxc-<dienst>` in `inventory/hosts.yml`, unter der passenden Gruppe.
3. Setzen: `container_role`, `container_node` (mit Grund), Pool, `container_tags`
   (ein Bereichstag + Fähigkeiten).
4. `host_vars/lxc-<dienst>.yml` für dienstspezifische Variablen, falls nötig.
5. DNS: `<dienst>.lan` → npm (oder direkt), plus ggf. externer Name über
   cloudflared/npm.
6. Anlegen: `ansible-playbook playbooks/container_site.yml -e target_host=lxc-<dienst>`
   (erster Lauf `-u root`, siehe README).
7. Verfügbarkeit: stateful → HA-Gruppe + Replication-Job; stateless-Replica →
   `-b` auf der anderen Node, **nicht** in HA/Replication.
