# Dienst-Rechte: User, Gruppen, Modes

Lern- und Referenzdokument. Wie Config-Dateien und Verzeichnisse einer Service-Rolle
besessen und geschützt werden – und **warum die Zahl immer das Ergebnis einer Frage
ist, nie die Entscheidung**.

Verwandt: `linux-basics.md` (Grundlagen zu Modes und System-Usern),
`playbook-architecture.md` (Aufbau der Rollen).

> Dieses Dokument verschärft die Daumenregel aus `linux-basics.md` §1
> („alle Verzeichnisse `0755`, Config-Dateien `0644`"). Die galt, solange jede Config
> öffentlich lesbar sein durfte. Sobald ein Secret drinsteht, gilt §2 hier.

---

## 1. Die eine Frage

Vor jedem `owner` / `group` / `mode` steht immer dieselbe Frage:

> **Wer liest, wer schreibt – und unter welcher Identität?**

Drei Teilfragen, die sie beantworten:

```bash
systemctl show <unit> -p User -p Group -p EnvironmentFiles -p FragmentPath
```

1. Unter welchem User läuft der Dienst?
2. Liest der Prozess die Datei **selbst**, oder liest systemd sie **für** ihn?
3. Schreibt der Dienst die Datei zur Laufzeit **zurück**?

**Achtung bei der Messung:** `systemctl show -p EnvironmentFile` (Singular) ist keine
gültige Property. systemd gibt bei unbekannten Properties stillschweigend *nichts* aus,
statt zu meckern. Leer heißt also nicht „gibt es nicht", sondern kann „falsch gefragt"
heißen. Gegenprobe: `systemctl show <unit> | grep -i environ`.

---

## 2. Die drei Muster

Mehr braucht es nicht. Die Zahlen unterscheiden sich, das Verfahren ist identisch.

| | Wann | Datei | Verzeichnis | Im Repo |
|---|---|---|---|---|
| **A** | Dienst liest die Config selbst | `root:<dienst>` `0640` | `root:<dienst>` `0750` | `grafana`, `unpoller` |
| **B** | systemd liest sie über `EnvironmentFile=` | `root:root` `0600` | – | `caddy`, `gatus`, `pihole` |
| **C** | Dienst schreibt die Config selbst | `<dienst>:<dienst>` `0600` | `<dienst>:<dienst>` `0750` | `zigbee2mqtt` |

### Muster A – der Normalfall

Der Dienst öffnet seine Config, *nachdem* systemd die Privilegien abgegeben hat. Also
muss der Dienstuser lesen dürfen: `root` besitzt und schreibt (das tut Ansible), die
Dienstgruppe liest, alle anderen bekommen nichts.

### Muster B – systemd ist **kein** User

Häufigstes Missverständnis. systemd ist PID 1 und läuft als **root**. Der Ablauf:

```
1. systemd (root) startet die Unit
2. systemd (root) liest EnvironmentFile=        ← hier wird die Datei geöffnet
3. systemd wechselt auf User=<dienst>
4. der Dienstprozess läuft                      ← sieht nur noch Variablen
```

Der Dienstuser bekommt die Datei **nie** zu Gesicht, nur die fertigen
Umgebungsvariablen. Deshalb reicht `root:root 0600` – und deshalb ist das das
strengste der drei Muster. Wenn ein Dienst Secrets über Variablen annimmt, ist B
immer die erste Wahl.

### Muster C – der Dienst pflegt seine Datei selbst

Schreibt ein Dienst seine Config zur Laufzeit zurück (zigbee2mqtt tut das bei
Frontend-Änderungen und bei Schema-Migrationen), dann muss er Owner sein. Ansible
darf die Datei dann **nicht** mehr überschreiben:

```yaml
- ansible.builtin.template:        # nur den Inhalt, nur beim ersten Mal
    force: false
- ansible.builtin.file:            # die Rechte, bei jedem Lauf
    mode: "0600"
```

Warum getrennt: siehe §7, `force: false`.

---

## 3. Owner und Gruppe sind unabhängig

Zwei getrennte Felder im Inode. Es gibt **keine** Regel, dass die Gruppe zum Owner
passen muss.

```
/etc/grafana/grafana.ini   root:grafana   640
/etc/shadow                root:shadow    640
/etc/ssl/private           root:root      700
```

Alle gehören `root`, und `root` ist in keiner dieser Gruppen Mitglied (`groups=0(root)`).
Dass eine von root angelegte Datei die Gruppe `root` bekommt, ist der **Default** –
die GID des erzeugenden Prozesses –, keine Vorschrift.

> Der Gruppeneintrag existiert, um **jemand anderem als dem Owner** Zugriff zu geben.
> Müsste er zum Owner passen, wäre er nutzlos.

### Das Verzeichnis vererbt den Owner nicht

Der Owner einer neuen Datei ist der User des **Prozesses**, der sie anlegt. Beleg aus
dem eigenen Haus:

```
drwxr-xr-x  grafana grafana   /var/lib/grafana/
drwxr-xr-x  root    root      /var/lib/grafana/dashboards     ← drin, aber root
```

Ansible eskaliert zu root (`ansible.cfg`: `become_user = root`), also gehört alles, was
es anlegt, root. Deshalb muss `group:` **explizit** hingeschrieben werden.

Einzige Ausnahme, und die betrifft nur die Gruppe: das **setgid**-Bit auf einem
Verzeichnis (`2xxx`) lässt neue Dateien darin die Gruppe des Verzeichnisses erben.
Den Owner vererbt auch das nicht. In diesem Repo bewusst nicht benutzt – ein
explizites `group:` ist klarer als ein Bit, das aus der Ferne wirkt.

### Primärgruppen tauchen in `/etc/group` nicht auf

```
getent group grafana  →  grafana:x:105:        ← sieht leer aus
id grafana            →  uid=102 gid=105(grafana)
```

Der User steht nicht in der Mitgliederliste, weil `grafana` seine **Primärgruppe** ist –
die steht in `/etc/passwd`. In `/etc/group` landen nur *zusätzliche* Mitgliedschaften.
Nicht wundern, der Zugriff funktioniert.

---

## 4. Erste passende Regel gewinnt

Der Kernel prüft der Reihe nach und **stoppt beim ersten Treffer**:

1. Prozess-UID == Datei-UID? → **Owner-Bits**, fertig
2. Prozess in der Datei-Gruppe? → **Gruppen-Bits**, fertig
3. sonst → **Other-Bits**

Es wird **nicht addiert**. Bei `0604` bekommt ein Gruppenmitglied *gar nichts*, obwohl
„Andere" lesen dürfen – Regel 2 greift und stoppt. Gruppenmitgliedschaft kann Zugriff
also sogar verringern.

### Die beiden Fallen, die daraus folgen

**`0750` ohne die passende Gruppe heißt „nur root".** Ein Dienstuser, der nicht Owner
und nicht in der Gruppe ist, fällt auf Regel 3 – und die ist bei `0750` leer.

**Verzeichnis und Datei brauchen dieselbe Gruppe.** Sonst ist die Datei korrekt gesetzt
und trotzdem unerreichbar, weil der Weg dorthin versperrt ist. Modus und Gruppe sind
*eine* Entscheidung, nicht zwei.

---

## 5. Verzeichnis ≠ Datei

Das `x`-Bit bedeutet bei einer Datei „ausführbar", bei einem Verzeichnis
„**betreten/durchqueren**". Details in `linux-basics.md` §1. Praktische Folge:

- Verzeichnis → `0750` (`rwxr-x---`), `x` ist Pflicht
- Config-Datei → `0640` (`rw-r-----`), `x` wäre sinnlose Angriffsfläche

---

## 6. Die vierte Stelle und die Anführungszeichen

`chmod` nimmt vier Stellen; die erste ist meist `0` und wird weggelassen.
`chmod 640` und `chmod 0640` sind identisch.

| Wert | Bit | Wirkung |
|---|---|---|
| 4 | setuid | Programm läuft mit den Rechten des Owners |
| 2 | setgid | auf Verzeichnis: neue Dateien erben dessen **Gruppe** |
| 1 | sticky | in `/tmp`: nur der Owner darf seine eigenen Dateien löschen |

**Immer als String mit führender Null** – das ist ein YAML-Thema, kein chmod-Thema:

```
mode: 644     (ohne Quotes) → dezimal 644 → oktal 1204 → -w----r-T
mode: "0640"                → oktal 0640              → rw-r-----
```

Ohne Quotes rechnet der YAML-Parser die Zahl als Dezimalwert um. Das Ergebnis ist
Unsinn, den man beim Debuggen nie vermutet.

---

## 7. Ansible-Fallen

**`template` ohne `owner`/`group`.** Bei einer **bestehenden** Zieldatei bleiben
Owner und Gruppe erhalten (`atomic_move` liest sie vorher aus). Bei einer **neuen**
Datei wird es `root:root`. Eine Rolle, die sich darauf verlässt, funktioniert auf dem
gewachsenen Container und bricht auf dem frischen Node.

**`force: false` schaltet alles ab.** Es bedeutet nicht „Inhalt nicht überschreiben",
sondern „Datei existiert, Finger weg" – inklusive Owner, Gruppe und Modus. Nachgestellt:
Datei mit `0644`, dann Task mit `force: false` + `group: daemon` + `mode: "0600"` →
Ergebnis unverändert `root:root 644`. Deshalb bei Muster C immer zwei Tasks.

**`recurse: true` ohne `mode`.** Mit `recurse` wirkt der Task auf das Verzeichnis und
alles darin. Gibst du dabei `mode` an, bekommt **jede Datei** den Verzeichnismodus –
samt `x`-Bit. Für reines Umeignen also `owner` + `group` + `recurse`, **kein** `mode`.
Das Verzeichnis selbst bekommt seinen Modus in einem eigenen Task.

**`--check` kann Rollen nicht prüfen, die ihren User selbst anlegen.** Im Check-Modus
entsteht der User nicht, also scheitert jeder folgende `chown` mit
*„failed to look up user"*. Ansible sagt es wörtlich: *„Create user up to this point in
real play"*. Vorgehen: einmal nur `users.yml` echt laufen lassen, danach ist der Check
für den Rest aussagekräftig.

**Chown-Wettrennen beim User-Wechsel.** Wechselt ein laufender Dienst den User, kann
der noch lebende alte Prozess (als root) nach dem `chown` eine Datei zurückschreiben –
sie gehört dann wieder root. Beobachtet bei zigbee2mqtt: `database.db` blieb beim ersten
Lauf `root:root`, erst der zweite Lauf hat es korrigiert. Entweder den Dienst vor dem
Chown stoppen oder nach dem Umstieg ein zweites Mal laufen lassen.

**Den Code-Baum nicht dem Dienstuser geben.** Gehört ein git-Repo einem anderen User
als dem, der git aufruft, verweigert git den Dienst:

```
fatal: detected dubious ownership in repository at '/opt/...'
```

Ansible arbeitet als root – ein `chown -R` auf das Repo bricht also den git-Task bei
jedem künftigen Lauf. Code bleibt `root:root` (lesbar für den Dienst), nur das
Datenverzeichnis geht an den Dienstuser. Nebeneffekt: der Dienst kann seinen eigenen
Code nicht verändern.

**`users.yml` nur, wo kein Paket den User anlegt.** Service-Pakete aus APT legen ihren
User im `postinst` selbst an (`grafana` → uid 102, `unpoller` → uid 999). Legt die Rolle
ihn *zusätzlich* an, entsteht eine zweite Quelle der Wahrheit: auf dem gewachsenen
Container ändert sie Attribute (z. B. Shell `/bin/false` → `/usr/sbin/nologin`), auf dem
frischen Node gewinnt die Rolle und das Paket überspringt den Schritt – mit womöglich
anderem Home. Entweder bewusst die Rolle besitzen lassen (dann alle Attribute explizit)
oder weglassen. Nicht beides halb. Eigene `users.yml` ist **Pflicht**, wo es kein Paket
gibt – `zigbee2mqtt` wird per git-clone installiert, dort muss die Rolle den User anlegen.

**HOME nicht vergessen.** `create_home: false` legt kein Home an, der Eintrag in
`/etc/passwd` existiert trotzdem. Zeigt er auf ein Verzeichnis, in das der Dienstuser
nicht schreiben darf, scheitern Tools, die dort Caches ablegen (npm/pnpm:
`~/.cache`, `~/.local/share`, `~/.npm`). Entweder `home:` auf ein Verzeichnis zeigen
lassen, das dem User gehört, oder das Tool aus dem Laufzeitpfad entfernen – bei
zigbee2mqtt reichte `ExecStart=/usr/bin/node index.js` statt `pnpm start`.

---

## 8. Checkliste für eine neue Rolle

1. `systemctl show <unit> -p User -p Group -p EnvironmentFiles` – **vor** dem Schreiben
2. Muster A, B oder C bestimmen (§2)
3. Verzeichnis **und** Datei: `owner`, `group`, `mode` alle drei explizit, dieselbe Gruppe
4. Schreibt der Dienst die Datei selbst? → `force: false` + eigener `file`-Task
5. Enthält die Datei ein Secret? → `other` muss `0` sein, immer
6. `service.yml` mit `state: started` **und** `enabled: true` **und** `daemon_reload: true`
7. `--check --diff` gegen den laufenden Container: Abweichungen bewusst entscheiden
8. Echter Lauf, dann **Dienst neu starten** – erst der Kaltstart beweist die Rechte
9. `journalctl -u <unit>` auf `EACCES` / `permission denied` prüfen
10. Noch ein Lauf: muss `changed=0` melden

### Warum Schritt 8 nicht optional ist

Rechte werden beim **Öffnen** einer Datei geprüft, nicht laufend. Ein `active` nach dem
Playbook sagt nur, dass ein bereits laufender Prozess weiterläuft. Ein Fehler zeigt sich
erst beim nächsten Neustart – also beim Reboot oder auf dem frischen Node. Dieselbe
Fehlerklasse wie ein Dienst, der läuft, aber nicht `enabled` ist.

---

## 9. Stand

| Rolle | Muster | Status |
|---|---|---|
| `grafana` | A | verifiziert, idempotent, Kaltstart geprüft |
| `zigbee2mqtt` | C | verifiziert, idempotent, läuft als eigener User |
| `unpoller` | A | verifiziert, idempotent; `service.yml` fehlt (Paket enabled selbst) |
| `proxmox_node` (pve-exporter) | A | bereits vollständig: `root:<dienst>` `0640` |
| `caddy`, `gatus`, `pihole` | B | `0600`; `owner`/`group` implizit, landet korrekt auf `root:root` |
| `cloudflared` | – | läuft als root (Unit stammt von `cloudflared service install`), Credentials `0600` – korrekt |
| `mosquitto` | C | Config enthält kein Secret; `/etc/mosquitto/passwd` ist `mosquitto:mosquitto 0600` – korrekt |
| `unbound`, `emmc_saver`, `crowdsec` | – | kein Secret, `mode` teilweise nicht gesetzt – unsauber, aber harmlos |

Wo „implizit" steht, fehlen `owner`/`group` im Task und das Ergebnis stimmt nur, weil
Ansible als root arbeitet. Das ist kein akutes Problem, aber es beschreibt nicht, was
gemeint ist – und es bricht, sobald die Datei auf einem frischen Node **neu** entsteht
und ein anderer User sie lesen müsste.

`lineinfile`/`blockinfile` auf fremden Systemdateien (`hostname`, `hardening`, `swap`)
brauchen **kein** `owner`/`group` – dort wäre es sogar falsch, weil es Eigentümer
fremder Dateien umbiegen würde.
