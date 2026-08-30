# Terraform in diesem Repo – Einschätzung

Lern- und Referenzdokument. **Kein Code**, sondern die Entscheidung: Lohnt sich
Terraform neben dem bestehenden Ansible-Setup, was würde es übernehmen, was
nicht – und wann ist ein guter Einstiegszeitpunkt.

Stand: 2026-08-30. Ergebnis: **Ja, grundsätzlich sinnvoll – aber nicht jetzt und
nicht überall.**

---

## 1. Was die beiden Werkzeuge machen

| | Ansible | Terraform |
|---|---|---|
| **Zweck** | Konfiguration *innerhalb* der Gäste: Pakete, Templates, Dienste | Infrastruktur *bereitstellen*: LXC/VMs, Netze, Storage, DNS-Einträge |
| **Denkweise** | prozedural – „führe diese Schritte aus" | deklarativ – „so soll die Welt aussehen, berechne den Unterschied" |
| **Gedächtnis** | keins – schaut bei jedem Lauf den Ist-Zustand an | **State-Datei** – hält fest, was Terraform angelegt hat |
| **Sprache** | YAML | HCL |

Merksatz: **Terraform baut die Hülle, Ansible richtet das Innere ein.**

Der übliche Homelab-Split: Terraform legt Container/VMs auf Proxmox an, Ansible
konfiguriert sie danach. Die Übergabe läuft über ein **dynamisches Inventory**
(`terraform output` → Ansible liest daraus die Hostliste).

---

## 2. Warum es hier grundsätzlich passt

- Die Gast-Definitionen im Inventory (`lxc-cloudflared`, `lxc-zigbee2mqtt`, …)
  sind heute schon *quasi-deklarativ* – eine Liste „diese Container soll es
  geben". Terraform kann genau das nativ, inklusive:
  - `terraform plan` als **Vorschau** vor jeder Änderung
  - sauberes `terraform destroy` (Ansible hat kein „mach das wieder weg")
  - Drift-Erkennung: „im Dashboard wurde etwas von Hand geändert"
- **Cloudflare**: `cloudflared` läuft bereits. DNS-Records und Tunnel-Config in
  Terraform zu verwalten ist Standard, risikoarm und überschneidet sich **null**
  mit Ansible. Das ist der beste erste Anwendungsfall (siehe Abschnitt 4).

---

## 3. Warum nicht jetzt und nicht alles

| Grund | Details |
|---|---|
| **Zweites Werkzeug, zweite Sprache** | HCL zusätzlich zu YAML. Mehr zu lernen, mehr zu warten. |
| **State-Datei** | Wird zur Quelle der Wahrheit über die Infra. Muss gesichert und geschützt werden (kann Secrets enthalten). Geht sie verloren, „vergisst" Terraform seine Ressourcen. |
| **Overlap mit Ansible** | Ansible kann Proxmox-Gäste über `community.general.proxmox` selbst anlegen (macht `container_site.yml` heute). Wenn beide Tools Gäste anlegen können, entsteht die Frage „wem gehört dieser Container?". |
| **Host-Bootstrap bleibt Ansible** | Terraform spricht nur die Proxmox-**API** an – *nachdem* die Node läuft. Bare-Metal-Setup einer frischen PVE-Node kann es nicht. Das „Fresh Node zero-touch"-Ziel (`site.yml`) bleibt vollständig Ansible-Sache. |
| **Migration ist Handarbeit** | Bestehende Gäste übernimmt Terraform nur per `terraform import` – eine Ressource nach der anderen. |

---

## 4. Guter Einstiegszeitpunkt

1. **Erst `site.yml` (zero-touch) fertig** und ein paar Mal erfolgreich gelaufen.
   Nicht mitten im laufenden Umbau der Playbook-Struktur ein zweites Paradigma
   einführen (siehe `docs/playbook-architecture.md`).

2. **Dann ein isoliertes erstes Projekt ohne Ansible-Overlap.** Klein,
   ungefährlich, dient zum Lernen von State und `plan`/`apply`:
   - **Cloudflare** – DNS-Records + Tunnel-Routing in Terraform. Passt zum
     bestehenden ToDo „cloudflared von Token- auf Config-Methode umstellen":
     entweder das Routing in Ansible (via `create_routes_dns.yml`) **oder** in
     Terraform – hier fällt die Entscheidung.
   - Alternativ: Proxmox-Pools, Template-/ISO-Downloads.

3. **Wenn sich das bewährt: Gast-Erstellung migrieren.** Beim nächsten
   Greenfield-Rebuild oder wenn ein Schwung neuer Gäste dazukommt – die dann in
   Terraform definieren statt in Ansible, mit `terraform output` als Quelle fürs
   Ansible-Inventory. `container_site.yml` würde dann nur noch konfigurieren,
   nicht mehr erzeugen.

---

## 5. Technische Hinweise für später

- **Provider `bpg/proxmox`** verwenden, **nicht** das ältere `Telmate/proxmox`
  (unmaintained, viele bekannte Bugs). `bpg` kann LXC, VMs, Template-Downloads,
  Pools, Cloud-Init.
- **Provider `cloudflare/cloudflare`** für DNS/Tunnel – ausgereift, gut
  dokumentiert.
- **State**: für ein Solo-Homelab reicht die lokale `terraform.tfstate` –
  **muss** aber ins Backup (nicht ins Git, enthält evtl. Secrets; `.gitignore`).
  Remote State (z. B. auf einem MinIO/S3 im Homelab) erst, wenn mehrere Rechner
  oder Personen darauf zugreifen.
- **Verzeichnis**: eigenes `terraform/`-Top-Level neben `playbooks/` und
  `roles/`, nicht vermischen.
- **Secrets**: Terraform-Variablen über `TF_VAR_*`-Env oder eine
  `*.auto.tfvars`-Datei (ebenfalls `.gitignore`), analog zu Ansible Vault.
