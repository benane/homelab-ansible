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

**Vorbedingung, die man prüfen muss:** Muster B hilft nur, wenn der Dienst die Variable
**nicht in seine Config zurückschreibt**. Sonst liegt das Secret hinterher an zwei Stellen
statt an einer, und das ist strikt schlechter.

Gemessen an zwei Diensten:

| | Start | mtime der Config | Ergebnis |
|---|---|---|---|
| grafana | 17:29:52 | 17:29:46 – **davor** | schreibt nicht zurück → B funktioniert |
| zigbee2mqtt | 17:25:08 | 17:25:08.665 – **auf die Sekunde** | serialisiert die Einstellungen beim Start und trägt das Passwort in Klartext ein |

Bei z2m war das Secret danach in `/etc/zigbee2mqtt/.env` **und** in `configuration.yaml`.
Der Umbau wurde deshalb zurückgenommen. Erkennbar ist es zusätzlich an der Position: z2m
schrieb die `password:`-Zeile ans Ende des Blocks, nicht dorthin, wo das Template sie hatte –
die Signatur einer maschinellen Serialisierung. Siehe
[Issue #27077](https://github.com/Koenkk/zigbee2mqtt/issues/27077); betrifft nicht nur das
HA-Add-on, sondern auch Standalone-Installationen.

**Der Test kostet einen Neustart:** Secret aus der Config entfernen, Dienst neu starten,
`mtime` gegen die Startzeit vergleichen. Liegt sie auf der Startsekunde, hat der Dienst
geschrieben.

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
User im `postinst` selbst an. Legt die Rolle ihn *zusätzlich* an, entsteht eine zweite
Quelle der Wahrheit – und sie gewinnt nur halb: UID/GID willst du nicht festnageln
(Kollisionsrisiko), also bleibt ein Besitzanspruch, der Attribute verändert, ohne sie zu
kontrollieren. Beobachtet bei `unpoller`: die Rolle stellte die Shell von `/bin/false` auf
`/usr/sbin/nologin` um, ohne dass es jemand wollte. Dazu läuft `users.yml` **vor**
`install.yml` – der vorab angelegte User lässt das `postinst` seinen eigenen Schritt
überspringen, und das tut womöglich mehr als nur den User anzulegen.

**Regel in diesem Repo:** die Rolle legt den User genau dann an, wenn es sonst niemand tut.

| Rolle | legt den User an |
|---|---|
| `grafana` | APT-Paket (uid 102) |
| `unpoller` | APT-Paket (uid 999) |
| `zigbee2mqtt` | **die Rolle** – git-clone, es gibt kein Paket |

Beim Weglassen auf die Reihenfolge achten: `install.yml` muss vor `dirs.yml` laufen, damit
die Gruppe existiert, wenn das Config-Verzeichnis sie braucht.

**Der Dienst kann auch nur die *Metadaten* zurückschreiben.** Bei z2m war es der Inhalt,
bei Pi-hole sind es Owner und Modus: Pi-hole normalisiert `/etc/pihole` nach jedem Start auf
`pihole:pihole 0640`. Die Rolle deklarierte `root` / `0600` und verlor nach jedem Neustart –
`--check` stand dauerhaft auf `changed`, ohne dass es jemandem auffiel.

Diagnose dafür: **mtime gegen ctime vergleichen.** `chown`/`chmod` ändern nur die ctime,
ein Schreibvorgang auch die mtime.

```bash
stat -c "mtime=%y%nctime=%z" <datei>
```

Liegt die ctime später, hat nach Ansible noch jemand Rechte geändert:

```
mtime = 2026-09-25 10:44:38   ← Ansible schrieb den Inhalt
ctime = 2026-09-25 10:45:02   ← 24 s später: Pi-hole chownte
```

Daraus folgt eine Arbeitsteilung, die man einfach aufschreiben muss: **Ansible besitzt den
Inhalt, der Dienst besitzt die Metadaten.** Dann braucht es kein `force: false` – nur die
Werte, die der Dienst ohnehin durchsetzt.

**Ob du nachgibst oder deinen Wert durchsetzt, hängt davon ab, wie oft die andere Seite ihn
zurücksetzt:**

| | wer setzt zurück | wie oft | Entscheidung |
|---|---|---|---|
| `pihole` | Pi-hole selbst | bei jedem Neustart | nachgeben: `pihole:pihole 0640` deklarieren |
| `grafana` | das `postinst` beim Paket-Upgrade | selten | durchsetzen: `0750` deklarieren, die Rolle konvergiert wieder |

Bei grafana setzt das `postinst` die Verzeichnisse unter `/etc/grafana` auf `0755` zurück –
belegt an einem `apt full-upgrade` (13.2.2 → 13.2.3): `configure` um 11:27:09, ctime der
Verzeichnisse 11:27:10. Die **Dateien** behielten dabei ihre `0640`, nur die Verzeichnisse
wurden geöffnet. Das `changed` nach einem Upgrade ist deshalb nützliches Signal, kein Ärgernis.

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
| `grafana` | A + B | Admin-Passwort in `/etc/grafana/.env` (`root:root 0600`) via systemd-Drop-in; `grafana.ini` enthält kein Secret mehr; verifiziert, idempotent |
| `zigbee2mqtt` | C | verifiziert, idempotent, läuft als eigener User. Muster B hier **nicht möglich** – z2m schreibt das Passwort zurück (siehe §2) |
| `unpoller` | A | verifiziert, idempotent; User kommt vom Paket; `service.yml` fehlt (Paket enabled selbst) |
| `proxmox_node` (pve-exporter) | A | bereits vollständig: `root:<dienst>` `0640` |
| `caddy`, `gatus` | B | `0600`; `owner`/`group` implizit, landet korrekt auf `root:root` |
| `pihole` | B + C | `pihole-FTL.env` ist `pihole:pihole 0640` (Pi-hole erzwingt es), Drop-in `root:root 0644` – verifiziert, `changed=0` |
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
