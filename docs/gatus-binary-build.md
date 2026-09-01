# Gatus-Binary bauen – Ablauf & Script erklärt

Lern- und Referenzdokument. Erklärt, warum wir Gatus selbst kompilieren, wie
der Ablauf beim Versions-Update aussieht, und was das Build-Script Zeile für
Zeile macht (inkl. `awk`, das vorher niemand kannte).

---

## 1. Warum überhaupt selbst bauen

`TwiN/gatus` veröffentlicht auf GitHub **keine fertigen Binaries** – nur
Quellcode-Tarballs und ein Container-Image (`ghcr.io/twin/gatus`). Für den
Wyse ist das Image völlig ok (Podman-Quadlet). Für den LXC 204 soll Gatus aber
**bare-metal** laufen (siehe Rollen-Dispatch `gatus_deployment: container |
baremetal`) – dafür braucht es ein echtes Linux-Binary.

Gatus ist in Go geschrieben. Go kompiliert zu **einer einzigen ausführbaren
Datei** pro Ziel-Betriebssystem/Architektur. Mit `GOOS=linux GOARCH=amd64`
lässt sich das auf dem Mac für die Ziel-Maschine (LXC, x86-64-Linux)
"cross-kompilieren" – du baust auf Maschine A ein Programm, das nur auf
Maschine B läuft.

**Einmalig pro Version**, nicht bei jedem Ansible-Lauf: das fertige Binary
landet in `roles/gatus/files/` und wird von der `baremetal`-Rolle per
`ansible.builtin.copy` einfach kopiert.

---

## 2. Der Ablauf beim Versions-Update

1. `gatus_version` in `roles/gatus/defaults/main.yml` auf die neue Version
   setzen (z. B. `"5.37.0"`).
2. Build-Script laufen lassen (siehe unten – erzeugt
   `roles/gatus/files/gatus-<version>-linux-amd64`).
3. Das **alte** Binary aus `roles/gatus/files/` löschen (bleibt in der
   Git-History erhalten, falls je gebraucht).
4. `git add` beides (Defaults-Änderung + neues Binary), committen.
5. Deployen: `ansible-playbook playbooks/08a_gatus.yml -l lxc-gatus`. Die
   `copy`-Task erkennt die neue Datei (andere Prüfsumme) und `notify`t den
   Restart-Handler.

---

## 3. Wo das Script hingehört

**Wichtig:** das Script muss nach `scripts/build-gatus.sh` (Repo-Root, neben
`scripts/setup_control_node.sh`) – **nicht** nach `roles/gatus/scripts/`.
Zwei Gründe:

- Ansible-Rollen kennen nur `tasks/`, `handlers/`, `templates/`, `files/`,
  `defaults/`, `vars/`, `meta/` als Konvention. Ein `scripts/`-Unterordner in
  einer Rolle ist unüblich und wird von nichts automatisch aufgerufen – das
  Script ist ein Werkzeug für *dich am Mac*, kein Teil des Rollen-Inhalts.
- Das Script bestimmt seinen eigenen Speicherort so:
  ```bash
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  ```
  `dirname "$0"` = der Ordner, in dem das Script liegt. `/..` geht davon eine
  Ebene hoch. Das Script **geht davon aus**, dass "eine Ebene über meinem
  eigenen Ordner" das Repo-Root ist. Liegt es unter `roles/gatus/scripts/`,
  landet `ROOT` bei `roles/gatus/` – falsch, dann sucht die nächste Zeile
  `roles/gatus/roles/gatus/defaults/main.yml`, was es nicht gibt. Liegt es
  unter `scripts/` (Repo-Root/scripts/), stimmt `ROOT`.

Auch der Dateiname sollte `build-gatus.sh` heißen (aktuell `guild_gatus.sh` –
Tippfehler).

---

## 4. Das Script Zeile für Zeile

```bash
#!/usr/bin/env bash
set -euo pipefail
```
Shebang (mit welchem Programm die Datei ausgeführt wird) + drei
Sicherheitsschalter: **`e`** = bei jedem Fehler sofort abbrechen (statt
stur weiterzulaufen), **`u`** = eine nicht gesetzte Variable ist ein Fehler
(schützt vor Tippfehlern bei Variablennamen), **`o pipefail`** = eine Pipe
(`a | b`) gilt als fehlgeschlagen, wenn *irgendein* Glied fehlschlägt, nicht
nur das letzte.

```bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
```
Ermittelt das Repo-Root relativ zum Script selbst (siehe Abschnitt 3).

```bash
VERSION="$(awk -F'"' '/^gatus_version:/{print $2}' "$ROOT/roles/gatus/defaults/main.yml")"
```
Liest die Version aus `defaults/main.yml`, statt sie im Script zu duplizieren
– eine Quelle der Wahrheit. Was `awk` hier tut, siehe Abschnitt 5.

```bash
DEST="$ROOT/roles/gatus/files/gatus-${VERSION}-linux-amd64"

[[ -f "$DEST" ]] && { echo "$DEST existiert – fertig."; exit 0; }
```
Zielpfad zusammenbauen. Existiert die Datei schon (Version schon gebaut),
sofort raus – idempotent, kein unnötiger Build.

```bash
BUILD="$(mktemp -d)"; trap 'rm -rf "$BUILD"' EXIT
```
`mktemp -d` legt ein leeres, garantiert eindeutiges Temp-Verzeichnis an (z. B.
`/tmp/tmp.Xk3fP2`) und gibt seinen Pfad zurück. `trap '...' EXIT` sagt: „egal
wie das Script endet – normal, per Fehler, per Abbruch – räume danach `$BUILD`
weg." Verhindert liegen gebliebene Temp-Ordner.

```bash
git clone --depth 1 --branch "v${VERSION}" https://github.com/TwiN/gatus.git "$BUILD"
```
Klont **nur** den einen Tag (`--depth 1` = ohne die komplette Historie, viel
schneller) in das Temp-Verzeichnis.

```bash
TC="go$(awk '/^go [0-9]/{print $2}' "$BUILD/go.mod")"
```
Liest aus dem gerade geklonten `go.mod`, welche Go-Version *dieses* Gatus
verlangt (Zeile `go 1.26.3`), und baut daraus `go1.26.3`. Löst genau das
Problem, das du hattest: dein lokales Go war neuer (1.27) als das, wogegen
Gatus getestet ist – mit `GOTOOLCHAIN=go1.26.3` lädt Go automatisch exakt die
passende Version und baut damit, egal was lokal installiert ist.

```bash
( cd "$BUILD" && GOTOOLCHAIN="$TC" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "$DEST" . )
```
Die Klammern `( ... )` starten eine **Subshell** – das `cd` darin wirkt nur
innerhalb der Klammern, dein eigentliches Terminal bleibt im ursprünglichen
Verzeichnis. Darin: `go build` mit den drei Zielangaben aus Abschnitt 1
(`CGO_ENABLED=0` = statisch, ohne C-Abhängigkeiten).

```bash
file "$DEST"
```
Prüft die entstandene Datei (`file`-Kommando erkennt Dateitypen). Erwartete
Ausgabe: `ELF 64-bit LSB executable, x86-64, ... statically linked`.

---

## 5. `awk` in aller Kürze

`awk` ist ein kleines Werkzeug, das eine Textdatei **zeilenweise** liest. Für
jede Zeile prüft es ein Muster und führt bei Treffer eine Aktion aus:

```
awk 'MUSTER {AKTION}' datei
```

Es zerlegt außerdem jede Zeile automatisch in **Felder** (Wörter), standardmäßig getrennt
durch Leerzeichen – ansprechbar als `$1`, `$2`, … (`$0` = die ganze Zeile).

**Aufruf 1:**
```bash
awk -F'"' '/^gatus_version:/{print $2}' defaults/main.yml
```
- `-F'"'` ändert das Trennzeichen von Leerzeichen auf `"` (Anführungszeichen).
  Die Zeile `gatus_version: "5.36.0"` zerfällt damit in: Feld 1 =
  `gatus_version: `, Feld 2 = `5.36.0`, Feld 3 = `` (leer, nach dem
  schließenden Quote).
- `/^gatus_version:/` ist das Muster: eine Regex, „Zeile beginnt mit
  `gatus_version:`" (`^` = Zeilenanfang).
- `{print $2}` = bei Treffer Feld 2 ausgeben → `5.36.0`.

**Aufruf 2:**
```bash
awk '/^go [0-9]/{print $2}' go.mod
```
- Kein `-F` → Standard-Trennzeichen Leerzeichen. Die Zeile `go 1.26.3` wird zu
  Feld 1 = `go`, Feld 2 = `1.26.3`.
- Muster `/^go [0-9]/` = „Zeile beginnt mit `go `, gefolgt von einer Ziffer" –
  trifft nur die Versionszeile, nicht z. B. `google.golang.org/...` im
  `require`-Block.
- `{print $2}` → `1.26.3`.

`awk` ist damit ein simpler Text-Grep-und-Zerschneid-Werkzeug – kein
YAML-Verständnis, es matcht stur Zeilenmuster. Solange die Datei so aussieht
wie erwartet, funktioniert es; ändert sich das Format der Zeile, bricht es
lautlos (findet einfach nichts).

---

## 6. `yq` als robustere Alternative (optional)

`yq` ist zu YAML das, was `jq` zu JSON ist: ein Werkzeug, das die Datei
**strukturell** versteht (Schlüssel, Verschachtelung, Listen, Typen) statt nur
Textzeilen zu matchen.

```bash
yq '.gatus_version' roles/gatus/defaults/main.yml
```
liefert direkt `5.36.0` – unabhängig davon, ob dort einfache oder doppelte
Anführungszeichen stehen, ob die Zeile eingerückt ist, oder ob der Key unter
einem anderen Elternknoten hängt.

Nicht installiert (`brew install yq`). Für diese eine flache Datei tut es
`awk` genauso; bei komplexeren YAML-Strukturen (verschachtelt, Listen) ist
`yq` deutlich robuster und lesbarer.

---

## 7. Alternative ganz ohne Kompilieren

Das offizielle Container-Image enthält bereits das fertige Linux-amd64-Binary
unter `/gatus`. Mit Podman/Docker am Mac lässt es sich einfach herausziehen,
ganz ohne Go/Toolchain-Ärger:

```bash
podman pull --platform linux/amd64 ghcr.io/twin/gatus:v5.36.0
CID=$(podman create ghcr.io/twin/gatus:v5.36.0)
podman cp "$CID":/gatus ./gatus-5.36.0-linux-amd64
podman rm "$CID"
```

Braucht Podman/Docker lokal (aktuell nicht installiert, siehe
[[wyse-bootstrap]] zum Thema Container-Runtime am Wyse) – als Fallback gut zu
wissen, falls der Go-Build mal wieder zickt.
