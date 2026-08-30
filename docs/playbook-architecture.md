# Playbook-Architektur

Lern- und Referenzdokument. Hier steht **kein** fertiger Code, sondern die
Denkweise: Wie sind Inventory, Rollen und Playbooks aufgeteilt, warum, und wie
bleibt das übersichtlich, wenn mehr dazukommt.

---

## 1. Das Grundprinzip: drei getrennte Ebenen

Ansible trennt sauber zwischen drei Dingen. Wenn man die auseinanderhält, bleibt
alles wartbar:

| Ebene | Frage | Wo im Repo |
|---|---|---|
| **Inventory** | *Wer* existiert? Welche Maschine ist was? | `inventory/hosts.yml`, `inventory/group_vars/` |
| **Rollen** | *Was* wird gemacht? Die eigentliche Logik. | `roles/<name>/` |
| **Playbooks** | *Welche Rolle läuft auf welcher Gruppe – und in welcher Reihenfolge?* | `playbooks/` |

Merksatz: **Rollen enthalten die Arbeit, Playbooks enthalten nur die
Verdrahtung.** Ein Playbook sollte fast nur aus „wende Rolle X auf Gruppe Y an"
bestehen. Sobald in einem Playbook viel `tasks:`-Logik steht, gehört die
wahrscheinlich in eine Rolle.

---

## 2. Die geschichtete Playbook-Struktur (`00_`, `01_`, …)

Die nummerierten Playbooks sind **Phasen**, nicht einzelne Maschinen. Jede Phase
ist *ein Thema*, angewendet auf die Hosts, für die das Thema relevant ist:

```
00_bootstrap.yml          Basis, die JEDE Maschine bekommt (User, Pakete, Hostname)
01_security_hardening.yml  Security-Basis (SSH, sysctl, fail2ban …)
02_proxmox_nodes.yml       alles Node-lokale für PVE (Repos, Upgrade, ZFS-Pool …)
03_proxmox_cluster.yml     alles Cluster-weite für PVE (Storage-Eintrag, Firewall …)
04_docker_hosts.yml        Docker auf Unraid + Wyse
05_vms.yml                 QEMU-Gäste (guest-agent, fstrim …)
06_network.yml             UniFi
```

`site.yml` ist der **Dirigent**: er importiert die Phasen in der richtigen
Reihenfolge und ist der *einzige* Ort, an dem die Gesamt-Reihenfolge sichtbar
ist. Genau dort gehören Kommentare hin, die Reihenfolge-Abhängigkeiten erklären
(siehe Abschnitt 5).

```yaml
# site.yml
- import_playbook: 00_bootstrap.yml          # muss zuerst: legt 'ansible'-User an
- import_playbook: 01_security_hardening.yml
- import_playbook: 02_proxmox_nodes.yml
- import_playbook: 03_proxmox_cluster.yml    # setzt bestehenden Cluster voraus (siehe README)
- import_playbook: 04_docker_hosts.yml
- import_playbook: 05_vms.yml
- import_playbook: 06_network.yml
```

Nummern-Lücken sind ok. Die Zahl sagt nur „Phase 2 kommt vor Phase 3".

**Warum nicht ein Playbook pro Maschine?** Weil sich Themen wiederholen: `common`
läuft auf *allem*, `hardening` auf *fast allem*. Ein Playbook pro Maschine würde
diese Rollen zwanzigmal auflisten. Die Gruppen im Inventory erledigen das
Bündeln.

**Sonderfall `container_site.yml`:** Container haben einen eigenen Lebenszyklus
(erst per Proxmox-API erzeugen, dann konfigurieren). Das bleibt bewusst ein
separates Playbook und wird *nicht* in `site.yml` eingehängt – `site.yml` ist für
Maschinen, die schon existieren.

---

## 3. Aufbau einer Rolle – und warum es „nur" `tasks/main.yml` gibt

### Die feste Verzeichnis-Konvention

Ansible erwartet in einer Rolle bestimmte Unterordner. Jeweils `main.yml` (oder
`main.yaml`) wird **automatisch** geladen:

```
roles/proxmox_node/
  tasks/main.yml         Einstiegspunkt – wird automatisch ausgeführt
  handlers/main.yml      Handler (z. B. „Dienst neu starten"), per notify ausgelöst
  defaults/main.yml      Standardwerte für Variablen (niedrigste Priorität → leicht überschreibbar)
  vars/main.yml          Variablen mit höherer Priorität (selten nötig)
  templates/             Jinja2-Templates (.j2)
  files/                 statische Dateien zum 1:1-Kopieren
  meta/main.yml          Metadaten + Abhängigkeiten zu anderen Rollen
```

`tasks/main.yml` ist also nur der **fest verdrahtete Einstiegspunkt**. Du bist
aber nicht auf diese eine Datei beschränkt.

### Eine Rolle auf mehrere Task-Dateien aufteilen

Sobald `tasks/main.yml` lang wird, macht man daraus ein **Inhaltsverzeichnis**
und lagert die Themen in eigene Dateien im selben `tasks/`-Ordner aus:

```yaml
# roles/proxmox_node/tasks/main.yml  – nur noch imports
- import_tasks: repos.yml
- import_tasks: upgrade.yml
- import_tasks: nag_banner.yml
- import_tasks: storage.yml
```

```
roles/proxmox_node/tasks/
  main.yml
  repos.yml        Enterprise-Repo weg, no-subscription rein
  upgrade.yml      full-upgrade + Reboot
  nag_banner.yml   Subscription-Popup entfernen
  storage.yml      zpool anlegen (node-lokal)
```

Das ist der normale Weg, eine wachsende Rolle übersichtlich zu halten. Die
„Mini-Rolle", nach der du gefragt hast, ist genau so eine Task-Datei –
**kein** eigener Ordner unter `roles/`.

### `import_tasks` vs. `include_tasks`

- **`import_tasks`** – statisch, wird beim Start eingelesen. `--list-tasks` zeigt
  alles, Tags funktionieren sauber. **Standardwahl fürs Aufteilen einer Rolle.**
- **`include_tasks`** – dynamisch, wird zur Laufzeit eingebunden. Nötig, wenn du
  die Einbindung *selbst* in einer Schleife oder hinter einer Bedingung brauchst
  (`when` entscheidet dann, ob die ganze Datei geladen wird).

### Rollen ineinander verschachteln – geht das?

**Verzeichnismäßig nein.** Es gibt kein `roles/proxmox_node/roles/…`. Alle Rollen
liegen flach in `roles/`. Wenn eine Rolle eine andere braucht, gibt es zwei Wege:

1. **`meta/main.yml` → `dependencies:`** – die abhängige Rolle läuft automatisch
   vorher. Haken: nur innerhalb desselben Plays, und das Verhalten bei gleichen
   Parametern ist gewöhnungsbedürftig. Für „echte" Abhängigkeiten ok, sonst eher
   meiden.
2. **`include_role` / `import_role`** in den Tasks – explizit eine andere Rolle
   aufrufen. Klarer, weil man im Code sieht, was passiert.

### Bonus: nur *einen Teil* einer Rolle aufrufen (`tasks_from`)

`include_role` kann gezielt eine andere Datei als `main.yml` ausführen:

```yaml
- name: Nur den Repo-Teil der proxmox_node-Rolle vorziehen
  ansible.builtin.include_role:
    name: proxmox_node
    tasks_from: repos.yml
  when: "'proxmox_nodes' in group_names"
```

Damit bleibt die gesamte Proxmox-Logik in **einer** Rolle, aber der Repo-Schritt
kann trotzdem früher laufen als der Rest (siehe Abschnitt 5). Das ist der
eleganteste Weg für dein aktuelles Problem, ohne eine neue Top-Level-Rolle
anzulegen.

---

## 4. Wann eigene Rolle, wann nur eine Task-Datei?

| Situation | Lösung |
|---|---|
| Unterthema einer Rolle, gehört logisch dazu, wird nur von dieser Rolle gebraucht | **Task-Datei** (`tasks/xyz.yml`) |
| Eigenständige Software / eigenständiger Dienst (mosquitto, cloudflared, docker) | **eigene Rolle** |
| Logik, die aus *mehreren* Playbooks / Kontexten aufgerufen wird | **eigene Rolle** |
| Etwas, das eine andere Reihenfolge braucht als der Rest seiner Rolle | Task-Datei + gezielt per `tasks_from` früher aufrufen, **oder** eigene Rolle |

Faustregel: **Eine Rolle = eine zusammenhängende Einheit, die man auch einzeln
sinnvoll erklären kann.** „Proxmox-Node einrichten" ist so eine Einheit –
Repos, Upgrade, Nag-Banner, ZFS-Pool sind ihre Kapitel, keine eigenen Bücher.

Gegenbeispiel `hardening` und `common`: getrennt, weil „OS-Basis" und
„Security-Politik" unterschiedliche Themen sind, die man auch mal getrennt
anfassen will.

---

## 5. Reihenfolge-Abhängigkeiten sichtbar machen

Das aktuelle Repo-Problem ist ein Musterbeispiel für eine **versteckte
Abhängigkeit**:

> `common` macht `apt update`. Auf einer frischen PVE-Node ist das Enterprise-Repo
> aktiv und liefert `401`. Also muss das Enterprise-Repo weg, *bevor* irgendein
> `apt update` läuft – und `common` läuft in `site.yml` als Erstes.

Möglichkeiten, so etwas zu lösen (von „am saubersten" nach „Notnagel"):

1. **Reihenfolge im Dirigenten anpassen.** Den Repo-Schritt als eigene frühe
   Phase oder als `pre_tasks` in `00_bootstrap.yml` einhängen – mit Kommentar,
   *warum* er da vorne steht.

   ```yaml
   # 00_bootstrap.yml
   pre_tasks:
     - name: PVE-Repos umstellen, bevor common das erste apt update macht
       ansible.builtin.include_role:
         name: proxmox_node
         tasks_from: repos.yml
       when: "'proxmox_nodes' in group_names"
   roles:
     - common
   ```

   Ausführungsreihenfolge in einem Play: `pre_tasks` → `roles` → `tasks` →
   `post_tasks`. Deshalb ist `pre_tasks` der richtige Platz für „vor `common`".

2. **`meta/dependencies`** – nur wenn die Abhängigkeit wirklich „Rolle A braucht
   immer erst Rolle B" ist und im selben Play liegt.

3. **Die Abhängigkeit in die abhängige Rolle einbauen** (z. B. `common` prüft
   selbst die Repos). *Nicht* machen: koppelt die generische `common`-Rolle an
   Proxmox-Wissen.

Wichtig ist weniger *welcher* Weg, sondern dass die Abhängigkeit **an einer
Stelle dokumentiert** ist – idealerweise als Kommentar in `site.yml` und im
Playbook, das den vorgezogenen Schritt enthält.

---

## 6. Erst-Lauf vs. Konvergenz (`root` vs. `ansible`-User)

Jedes Playbook muss mit **zwei Ausgangszuständen** klarkommen:

- **Jungfräuliche Maschine:** kein `ansible`-User → Verbindung als `root`
  (`-u root`), nachdem der SSH-Key von Hand hinterlegt wurde.
- **Bereits konvergierte Maschine:** `ansible`-User existiert → Default aus
  `ansible.cfg`.

Konsequenzen für den Bau:
- Rollen **idempotent** halten – ein zweiter Lauf darf nichts kaputt machen und
  soll möglichst nichts als „changed" melden.
- Der Bootstrap-Einstieg (`-u root`) gehört **dokumentiert** (README) oder in ein
  Wrapper-Script (steht schon als ToDo im README).
- Nichts in `hosts.yml` fest auf `ansible_user: root` setzen – das ist nur ein
  Einmal-Zustand.

---

## 7. Proxmox-spezifisch: die drei Phasen einer Node

Bei Proxmox gibt es eine harte Grenze zwischen „vor dem Cluster-Join" und
„danach". Das strukturiert die Rollen:

| Phase | Was | Wo | Ausführung |
|---|---|---|---|
| **Node-lokal** | Repos, Upgrade, Reboot, Nag-Banner, `/etc/hosts`, ZFS-Pool `zpool create` | Rolle `proxmox_node` | auf **jeder** Node, idempotent, pre-join-tauglich |
| **Cluster-weit** | Storage-Eintrag (`pvesm add`), Node-/Cluster-Firewall, `datacenter.cfg`, Replikation | Rolle `proxmox_cluster` (eigenes Playbook) | **einmal**, per `--limit` auf *eine* Node, erst wenn der Cluster steht |
| **Manuell** | `pvecm add`, `pvecm qdevice setup` | – | Handschritt, im README dokumentiert, **nicht** in Ansible |

Warum die Trennung: Cluster-weite Befehle vor dem Join sind sinnlos (werden vom
Join überschrieben) oder gefährlich (Firewall-Aktivierung wirkt sofort auf alle
Nodes). Der Join selbst ist interaktiv und einmalig – schlechter Kandidat für
Automatisierung.

---

## 8. Vorschlag: Zielstruktur für dieses Repo

```
playbooks/
  site.yml                    Dirigent (importiert 00–06, mit Reihenfolge-Kommentaren)
  00_bootstrap.yml            role: common   + pre_task: proxmox_node/repos.yml (nur PVE)
  01_security_hardening.yml   role: hardening
  02_proxmox_nodes.yml        role: proxmox_node        (hosts: proxmox_nodes)
  03_proxmox_cluster.yml      role: proxmox_cluster     (hosts: eine PVE-Node, gated)
  04_docker_hosts.yml         role: docker_host         (hosts: docker_hosts)
  05_vms.yml                  role: qemu_vm             (hosts: qemu_vms)
  06_network.yml              role: unifi_network       (hosts: unifi_controllers)
  container_site.yml          eigener Lifecycle, bleibt separat

roles/
  common/                     OS-Basis, jede Maschine
  hardening/                  Security-Basis
  proxmox_node/
    tasks/
      main.yml                nur import_tasks
      repos.yml               Enterprise weg / no-subscription rein   ← die „Mini-Rolle"
      upgrade.yml             full-upgrade + Reboot
      nag_banner.yml
      storage.yml             zpool create (node-lokal, idempotent)
    handlers/main.yml
    defaults/main.yml         alle Stellschrauben (Pool-Name, Disk-by-id, …)
  proxmox_cluster/            pvesm-Storage, Firewall, datacenter.cfg — alles 1x, cluster-weit
  docker_host/
  qemu_vm/
  <service-rollen…>           mosquitto, zigbee2mqtt, cloudflared, …
```

Was sich gegenüber heute ändert:
- `proxmox_node` wird in Task-Dateien zerlegt (`main.yml` = Inhaltsverzeichnis).
- Der Repo-Teil (`repos.yml`) wird zusätzlich früh aufgerufen – per
  `tasks_from` aus `00_bootstrap.yml`, damit er vor `common`s `apt update` läuft
  und beide Repo-Formate abdeckt (altes `.list` = PVE 8, neues `.sources`/deb822
  = PVE 9).
- Neue Rolle `proxmox_cluster` für alles, was erst nach dem Join Sinn ergibt.
- `site.yml` bekommt die auskommentierten Phasen 03–06 zurück, sobald die Rollen
  stehen.

---

## 9. Konkrete Antwort auf deine Frage

**„Kann die Mini-Rolle innerhalb von `proxmox_node` liegen?"**
Ja – als **Task-Datei** `roles/proxmox_node/tasks/repos.yml`, nicht als eigener
Rollen-Ordner. `tasks/main.yml` bindet sie per `import_tasks: repos.yml` ein.
Damit sie früher als `common` läuft, ruft `00_bootstrap.yml` sie gezielt per
`include_role: { name: proxmox_node, tasks_from: repos.yml }` in den `pre_tasks`
auf.

**„Werden die Rollen sonst unübersichtlich?"**
Genau dagegen ist das Aufteilen in Task-Dateien da: `main.yml` bleibt ein
10-Zeilen-Inhaltsverzeichnis, jedes Thema hat seine eigene kurze Datei,
Variablen sammeln sich in `defaults/main.yml`. Eine eigene Rolle machst du erst
auf, wenn es wirklich ein eigenständiger Dienst ist oder aus mehreren Playbooks
gebraucht wird.
