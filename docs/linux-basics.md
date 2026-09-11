# Linux-Basics für Service-Rollen

Lern- und Referenzdokument. Kein Ansible, sondern das Fundament darunter: wie ein
Linux-System aufgebaut ist, was „installieren" wirklich heißt, wie systemd Dienste
verwaltet. Durchgehend am Beispiel der `victoriametrics`-Rolle, damit es konkret bleibt.

---

## 1. Das Dateisystem — wer wohnt wo

Linux folgt dem **Filesystem Hierarchy Standard (FHS)**. Kein technischer Zwang, aber
alles hält sich dran, und Distributionen/systemd setzen es voraus. Eine Wurzel `/`,
kein `C:\`. Andere Platten werden *irgendwo in den Baum* eingehängt (gemountet).

| Pfad | Was | Beispiel |
|---|---|---|
| `/etc` | **Konfiguration**, systemweit, Text, statisch | `/etc/victoriametrics/scrape.yml`, `/etc/systemd/system/*.service` |
| `/var` | **Variable Daten** — wächst/ändert sich im Betrieb: DBs, Logs, Caches, Queues | — |
| `/var/lib` | Persistenter Zustand von Diensten (nicht Logs, nicht Cache) | `/var/lib/victoria-metrics/` (die TSDB) |
| `/var/log` | Logs — aber moderne Dienste loggen ins Journal (§4) | — |
| `/var/cache` | Wegwerfbare Zwischenstände (Download-Cache o.ä.) | Kandidat für den Tarball-Download |
| `/usr` | Programme + Libraries, **read-only im Betrieb**, kommen vom Paketmanager | — |
| `/usr/bin`, `/usr/sbin` | Paketmanager-Programme (`sbin` = eher Admin/root) | `apt`, `systemctl` |
| `/usr/local/bin` | **Selbst** installierte Binaries. Der Paketmanager fasst `/usr/local` nie an | `victoria-metrics-prod` |
| `/opt` | Fremdsoftware mit **eigenem Unterbaum** (`/opt/foo/bin`, `/opt/foo/etc`) | — |
| `/home` | Nutzerverzeichnisse. Dienste haben hier **nichts** zu suchen | `/home/benedikt` |
| `/root` | Home von `root` (nicht `/home/root`) | — |
| `/tmp` | Temporär, wird geleert (Reboot oder Timer). Weltschreibbar | — |
| `/run` | Laufzeitkram seit Boot (PID-Dateien, Sockets), im RAM, weg nach Reboot | systemd-Sockets |
| `/proc`, `/sys` | Keine echten Dateien — Kernel-Schnittstellen als Dateien (`cat /proc/cpuinfo`) | — |
| `/dev` | Geräte als Dateien (`/dev/sda`, `/dev/null`) | `/dev/disk/by-id/...` in der ZFS-Rolle |
| `/boot` | Kernel + Bootloader | — |
| `/bin`, `/sbin`, `/lib` | Heute nur Symlinks nach `/usr/...` ("usr merge") | — |

**Faustregel, die 90% erklärt:** Config → `/etc`. Veränderliche Daten → `/var`.
Selbst installierte Binary → `/usr/local/bin`. Paketmanager-Zeug → `/usr`.
Fremdsoftware mit eigenem Baum → `/opt`.

Deshalb hat die `victoriametrics`-Rolle **drei** Verzeichnisse mit **unterschiedlichen
Besitzern**:

| Verzeichnis | Besitzer | Warum |
|---|---|---|
| `/etc/victoriametrics` | `root` | Config, VM liest nur. `ProtectSystem=strict` macht es ohnehin read-only |
| `/var/lib/victoria-metrics` | `victoriametrics` | Daten, VM schreibt. Bekommt als einziges `ReadWritePaths` |
| `/usr/local/bin` | `root` | Binary, alle dürfen ausführen, niemand außer root schreiben |

Die Trennung ist kein Selbstzweck: Backup sichert `/var/lib`, nicht die Binary; die
systemd-Sandbox kann `/usr` + `/etc` sperren und nur `/var/lib` freigeben.

### Directory-Mode vs. File-Mode

Häufige Verwechslung. Das `x`-Bit bedeutet bei einer **Datei** „ausführbar", bei
einem **Verzeichnis** „darf betreten/durchquert werden".

- **Verzeichnis** → `0755` (`rwxr-xr-x`): Besitzer darf ändern, alle dürfen rein und
  auflisten. `0644` auf einem Verzeichnis = du kannst es sehen, aber nicht `cd`
  hineinmachen. Deshalb sind *alle* Verzeichnisse `0755`, auch das Config-Verzeichnis.
- **Config-Datei** → `0644` (`rw-r--r--`): Besitzer schreibt, alle lesen, niemand
  führt aus.
- **Binary** → `0755`: braucht das `x`-Bit zum Ausführen.
- **Config-Datei mit Secret** (API-Token) → `0640` (Gruppe darf lesen) oder `0600`
  (nur Besitzer). Nicht `0644` — sonst liest jeder lokale User den Token.

---

## 2. Was ist ein Tarball

`tar` = "**t**ape **ar**chive", aus der Bandlaufwerk-Zeit. Packt **viele Dateien +
ihre Rechte/Struktur in eine einzige Datei**. `tar` komprimiert **nicht**, es klebt
nur zusammen. Die Kompression macht ein zweites Programm:

| Endung | Bedeutung |
|---|---|
| `.tar` | nur zusammengeklebt |
| `.tar.gz` / `.tgz` | tar, dann mit **gzip** komprimiert ← "Tarball" |
| `.tar.zst` | mit **zstd** (neuer, schneller — die Proxmox-Templates) |
| `.tar.xz`, `.tar.bz2` | andere Kompressoren |

Von Hand:

```bash
tar -xzf datei.tar.gz    # eXtrahieren, z = gzip, f = diese Datei
tar -tzf datei.tar.gz    # nur den Inhalt lisTen, ohne zu entpacken
```

Ansibles `unarchive`-Modul macht dasselbe, nur idempotent. Im VictoriaMetrics-Tarball
steckt genau eine Datei: `victoria-metrics-prod` (die Binary).

---

## 3. Wie Software auf ein System kommt

### a) Paketmanager (der Normalfall)

`apt` (Debian), `dnf` (Fedora), `pacman` (Arch). Ein `.deb` ist ein Archiv mit:
den Dateien (landen unter `/usr`, `/etc`, …), Metadaten (Version, Abhängigkeiten),
pre/post-install-Skripten. `apt`:

- löst **Abhängigkeiten** auf (Paket X braucht Library Y)
- lädt aus **Repositories** — die Quellen in `/etc/apt/sources.list.d/` (die die
  `proxmox_node`-Rolle umbiegt)
- verifiziert **GPG-Signaturen**
- verfolgt, welche Datei zu welchem Paket gehört → sauberes Update/Remove

Nachteil: du kriegst die Version, die im Repo liegt, oft älter.

### b) Fertige Binary herunterladen (der VictoriaMetrics-Fall)

Go-/Rust-Programme sind meist **statisch gelinkt**: eine einzelne Datei, keine
externen Libraries nötig. Der Hersteller baut sie und legt sie als GitHub-Release ab.
Du lädst sie, legst sie nach `/usr/local/bin`, machst sie ausführbar, fertig.

Vorteil: exakt deine Version, sofort. Nachteil: **du bist jetzt der Paketmanager** —
Updates, Checksummen, Aufräumen musst du selbst machen. Genau das baut die Rolle nach:
`get_url` (laden + Checksum-Prüfung), `unarchive` (entpacken), eigener systemd-Service,
Version in `defaults/main.yml`.

### c) Aus Quellcode bauen

`./configure && make && make install`. Compiler übersetzt Quellcode → Binary,
`make install` kopiert nach `/usr/local`. Selten nötig. Die `gatus`-Rolle macht es
per Skript.

### Was heißt „installieren" überhaupt

Kein magischer Registrierungs-Akt wie bei Windows. Installieren =

1. Dateien an die richtigen Stellen kopieren (Binary → `bin`, Config → `etc`, …)
2. ausführbar machen (`chmod +x`)
3. optional einen Service einrichten, damit es automatisch läuft

Ein Programm ist einfach eine Datei mit `x`-Bit, die der Kernel in einen Prozess
verwandelt, wenn man sie aufruft.

**`PATH`:** Tippst du `victoria-metrics-prod`, sucht die Shell die Verzeichnisse aus
der Umgebungsvariable `$PATH` ab (`echo $PATH` → `/usr/local/bin:/usr/bin:/bin:…`).
`/usr/local/bin` ist drin — deshalb landet die Binary dort. Liegt sie woanders,
brauchst du den vollen Pfad (wie im `ExecStart` der Unit).

---

## 4. Prozesse, Daemons, systemd

### Prozess

Ein laufendes Programm. Hat eine PID, einen Besitzer (User), Speicher, offene Dateien.
Stirbt, wenn das Programm sich beendet oder gekillt wird.

### Daemon

Ein Prozess, der **im Hintergrund dauerläuft** und Dienste anbietet, statt einmal zu
laufen und sich zu beenden. Kein Terminal, kein UI — wartet auf Ereignisse
(Netzwerk-Requests, Timer, Signale). Das `d` in `sshd`, `dockerd`, `systemd`.

VictoriaMetrics als Daemon: startet, öffnet Port 8428, wartet auf HTTP-Requests und
scrapet alle X Sekunden seine Targets — endlos, bis gestoppt.

### Das Problem, das systemd löst

Wer startet den Daemon beim Boot? Wer startet ihn neu, wenn er abstürzt? Wer sammelt
seine Logs? Wer sorgt für Reihenfolge (erst Netzwerk, dann VM)? Früher: handgeschriebene
Shell-Skripte in `/etc/init.d` (SysV-Init). Fehleranfällig, kein einheitliches
Verhalten.

**systemd** ist der erste Prozess, den der Kernel startet (**PID 1**), und die „Mutter"
aller anderen. Init-Prozess **+** Service-Manager: startet, überwacht, stoppt alles
andere und räumt Zombie-Prozesse ab.

### Unit

systemds Grundeinheit. Eine `.service`-Unit beschreibt einen Daemon. Es gibt auch
`.timer` (wie Cron), `.socket`, `.mount`, `.target` (Gruppen). Zwei Orte:

- `/lib/systemd/system/` — Units vom Paketmanager
- `/etc/systemd/system/` — Units vom Admin (**du**). Gewinnt bei Namensgleichheit.
  Deshalb schreibt die Rolle dorthin.

### `systemctl` — die Fernbedienung

```bash
systemctl start|stop|restart victoriametrics
systemctl enable victoriametrics       # beim Boot automatisch starten (legt Symlink an)
systemctl disable victoriametrics
systemctl status victoriametrics        # läuft's? PID, Speicher, letzte Logzeilen
systemctl enable --now victoriametrics  # enable + start in einem
```

`enable` ≠ `start`. `enable` sagt „beim nächsten Boot", `start` sagt „jetzt". Die
Rolle macht beides (`state: started, enabled: true`).

### `daemon-reload`

systemd liest die Unit-Dateien beim Start **einmal** ein und cached sie. Änderst du
`/etc/systemd/system/victoriametrics.service`, weiß systemd nichts davon, bis
`systemctl daemon-reload` alle Units neu einliest. Das ist **kein** Dienst-Neustart —
nur das Neu-Einlesen der Beschreibungen. Danach brauchst du noch ein `restart`, damit
der Dienst mit der neuen Unit läuft.

Deshalb hat der Handler `daemon_reload: true` **und** `state: restarted`: Beschreibung
neu lesen, dann Dienst mit ihr neu starten.

### `journalctl` — die Logs

systemd fängt **stdout/stderr** jedes Dienstes ab und schreibt es ins **Journal**:

```bash
journalctl -u victoriametrics -f              # live mitlesen (follow)
journalctl -u victoriametrics -e              # ans Ende springen
journalctl -u victoriametrics --since "10 min ago"
```

Moderne Daemons (VM, gatus) loggen **absichtlich nach stdout**, nicht in eigene
Logdateien — die Umgebung (systemd) kümmert sich ums Wohin. Das ist die „12-Factor"-Idee.

### Lebenszyklus einer Service-Unit

1. `systemctl start` → systemd liest die Unit
2. prüft `[Unit]`-Abhängigkeiten (`After=`, `Requires=`, `Wants=`)
3. legt User/Gruppe fest (`User=`, `Group=`), wendet Sandboxing an (`ProtectSystem=`, …)
4. führt `ExecStart=` aus → neuer Prozess
5. überwacht ihn. Stirbt er → `Restart=`-Policy greift (`always`, `on-failure`, `no`)
6. `systemctl stop` → `SIGTERM` an den Prozess, nach `TimeoutStopSec` `SIGKILL`

---

## 5. Eine systemd-Unit Zeile für Zeile

Am Beispiel `victoriametrics.service`:

```ini
[Unit]
Description=VictoriaMetrics service     # Text in `systemctl status`
After=network-online.target            # erst starten NACHDEM Netzwerk oben ist (nur Reihenfolge)
Wants=network-online.target            # dieses target mitziehen; scheitert's, starte trotzdem
```

- `After=` = **Reihenfolge**, keine Abhängigkeit.
- `Wants=` = **schwache** Abhängigkeit („zieh mit, aber wenn's scheitert, starte trotzdem").
- `Requires=` = **harte** Abhängigkeit (scheitert die Abhängigkeit, scheitert der Dienst).
- `network.target` heißt nur „Netzwerk-Stack konfiguriert", `network-online.target`
  heißt „verbunden" — für einen Scraper letzteres.

```ini
[Service]
Type=simple            # der ExecStart-Prozess IST der Dienst (kein Forken, kein Ready-Signal)
LimitNOFILE=2097152    # max. offene Datei-Deskriptoren (TSDBs öffnen viele Dateien)
User=victoriametrics   # als dieser User laufen, NICHT root
Group=victoriametrics
ExecStart=/usr/local/bin/victoria-metrics-prod -storageDataPath=… -httpListenAddr=:8428 …
```

- `Type=simple` = Normalfall für moderne Daemons: laufen im Vordergrund, systemd hält
  sie. `Type=notify` wäre, wenn das Programm systemd aktiv „ich bin bereit" meldet.
- `User=` ist das **Sicherheitsmodell**: läuft VM als root und hat einen Bug, ist die
  ganze Maschine offen. Läuft es als `victoriametrics` mit `nologin`-Shell und Zugriff
  nur auf `/var/lib/victoria-metrics`, ist der Schaden begrenzt.

```ini
Restart=always                    # egal warum der Prozess endet — neu starten
SyslogIdentifier=victoriametrics  # Name im Journal
```

```ini
PrivateTmp=yes             # eigenes /tmp, isoliert von anderen Prozessen
ProtectHome=yes            # /home, /root unsichtbar für den Dienst
NoNewPrivileges=yes        # der Prozess kann nie mehr Rechte kriegen (kein setuid)
ProtectSystem=strict       # das GESAMTE Dateisystem read-only …
ReadWritePaths=/var/lib/victoria-metrics   # … außer hier
ProtectKernelModules=true  # darf keine Kernelmodule laden
ProtectKernelTunables=yes  # darf /proc/sys nicht schreiben
```

Das ist **systemd-Sandboxing**. Jede Zeile nimmt dem Prozess eine Fähigkeit weg, die
ein Metrik-Sammler nicht braucht. Wird VM kompromittiert, kann der Angreifer nicht ins
Dateisystem schreiben (außer Data-Dir), keine Module laden, keine Rechte eskalieren.
Kostenlos, nur Textzeilen. Referenz: `man systemd.exec`.

```ini
[Install]
WantedBy=multi-user.target   # bei `systemctl enable`: starte, wenn das System "multi-user" erreicht
```

`multi-user.target` = „System hochgefahren, Netzwerk, Mehrbenutzer, kein
Grafik-Desktop" — der Normalzustand eines Servers. `WantedBy=` ist der Mechanismus
hinter `enable`: es legt einen Symlink in `multi-user.target.wants/` auf die Unit an.
Mehr ist `enable` nicht.

---

## 6. User & Rechte — das Minimum

- Jede Datei hat **Besitzer** (User), **Gruppe**, **Mode** (rwx für Besitzer / Gruppe /
  Rest). `ls -l` zeigt's: `-rwxr-xr-x root root`.
- `chmod 0755` = Besitzer rwx (7), Gruppe + Rest r-x (5). `0644` = kein Ausführen.
- **System-User** (`system: true`, UID < 1000): kein Home, `nologin`-Shell, niemand
  loggt sich als der ein. Existiert nur, damit ein Dienst *als jemand ≠ root* läuft.
- Eigener User **pro Dienst** (nicht `nobody`): Isolation. Läuft alles als `nobody`,
  kann ein kompromittierter Dienst die Dateien jedes anderen `nobody`-Dienstes lesen.
- `root` (UID 0) ignoriert Modes, darf alles → so wenig wie möglich als root.

---

## 7. Weitere Bausteine

- **Environment-Variablen:** Key-Value-Paare, die ein Prozess vom Elternprozess erbt
  (`PATH`, `HOME`, `LANG`). Ein Dienst kriegt sie über `Environment=` /
  `EnvironmentFile=` in der Unit. `printenv` zeigt deine.
- **Ports:** ein Daemon „lauscht" auf einem Port (VM: 8428). Ports < 1024 dürfen nur
  root bzw. Prozesse mit `CAP_NET_BIND_SERVICE` — deshalb laufen Webdienste auf
  8080/8428/… und ein Reverse Proxy davor auf 443.
- **Exit-Codes:** ein Prozess endet mit einer Zahl. `0` = ok, alles andere = Fehler.
  `Restart=on-failure` schaut darauf. `echo $?` zeigt den letzten.
- **Signale:** `SIGTERM` (freundlich: „beende dich") → `SIGKILL` (nicht abfangbar).
  `systemctl stop` schickt erst TERM, wartet, dann KILL. `SIGHUP` heißt bei vielen
  Daemons „lies deine Config neu".
- **stdin / stdout / stderr:** drei Standard-Kanäle jedes Prozesses. Bei einem Daemon:
  stdin tot, stdout + stderr → Journal.
- **Symlinks:** Verweis auf eine andere Datei (`ln -s ziel name`). `systemctl enable`
  legt einen an.
- **`man` und `--help`:** `man systemd.exec` = vollständige Referenz für die
  `[Service]`-Optionen. `victoria-metrics-prod --help` = jede Flag. Das sind die
  Quellen, nicht Stack Overflow.

---

## 8. Wie man aufhört, blind abzutippen

Eine Methode, kein Wissen:

1. **Jede Zeile muss einen Zweck haben, den du benennen kannst.** Nicht erklärbar →
   nachschlagen (`man systemd.exec`) oder rauswerfen und schauen, was passiert. Lieber
   eine kurze Unit, die du verstehst, als eine lange kopierte.
2. **Pfade gegen die FHS-Faustregel prüfen.** „Warum `/opt`? Ist das Fremdsoftware mit
   eigenem Baum? Nein → gehört woanders hin."
3. **`--help` / `man` vor Google.** Bei `-promscrape.config` →
   `victoria-metrics-prod --help | grep promscrape`.
4. **Nach dem Deploy nachsehen, nicht nur `changed=0` glauben:**
   ```bash
   systemctl status victoriametrics
   journalctl -u victoriametrics -e
   ss -tlnp | grep 8428          # lauscht er auf dem Port?
   ls -l /var/lib/victoria-metrics   # schreibt er Daten?
   curl -s localhost:8428/health
   ```
5. **Ein Ding pro Iteration ändern.** Unit anpassen → `daemon-reload` → `restart` →
   `status` → Logs. Nicht fünf Zeilen gleichzeitig.
6. **Fragen „was passiert, wenn das fehlt?"** `ReadWritePaths` auskommentieren, neu
   starten, den Fehler im Journal lesen. Jetzt weißt du, wofür die Zeile da ist.
