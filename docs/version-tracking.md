# Versionen pinnen & Updates verfolgen – Strategie

Lern- und Referenzdokument. **Kein Code**, sondern die Überlegung: Wie werden
die neuen Dienste mit **festgepinnten Versionen** installiert, und wie bekommt
man mit, dass es neue Versionen gibt – idealerweise auf einer Übersichtsseite
inklusive Changelog / Breaking Changes.

Stand: 2026-08-30. Ergebnis: **Renovate deckt ~80 % ab (als GitHub-Issue, nicht
als Web-Seite). Ein kleines eigenes Dashboard obendrauf ist ein sinnvolles,
überschaubares Projekt – aber erst später und aufbauend auf Renovates Daten,
nicht von Grund auf.**

---

## 1. Der Wunsch

Eine Übersichtsseite, die zeigt:
- welche Version je Dienst **aktuell im Repo gepinnt** ist,
- welche Version **aktuell verfügbar** ist,
- und die **Changes / Breaking Changes** aus den zugehörigen Update-PRs.

---

## 2. Grundprinzip: Versionen an einer Stelle

Unabhängig vom Tooling: alle gepinnten Versionen zentral halten, z. B.
`inventory/group_vars/all/versions.yml`:

```yaml
esphome_version: "2025.7.1"
zigbee2mqtt_version: "2.1.3"
cloudflared_version: "2025.7.0"
```

Die Rollen referenzieren nur noch diese Variablen. Vorteile:
- ein Ort für „was läuft gerade",
- eine Datei, auf die Renovate bzw. ein eigenes Tool zielt,
- saubere Git-Diffs pro Update.

**Exakt pinnen** (`2.1.3`, nicht `2.1`), damit jedes Update eine bewusste,
getestete Aktion ist.

---

## 3. Optionen, um neue Versionen mitzubekommen

| Weg | Aufwand | Was es liefert | Grenzen |
|---|---|---|---|
| **newreleases.io** | einmal Dienste eintragen | Mail/Discord/Telegram/Webhook bei jedem Release | reine Benachrichtigung, kein Abgleich |
| **RSS-Feeds** (`github.com/OWNER/REPO/releases.atom`) in Miniflux/FreshRSS | 1 LXC + Feeds pflegen | alle Releases an einem Ort, auch nicht-GitHub | kein Bezug zum Repo/System |
| **GitHub Watch → Custom → Releases** | pro Repo 1 Klick | Releases in GitHub-Notifications | verteilt, schlecht überblickbar |
| **What's Up Docker (WUD)** / **Diun** | 1 LXC | Web-Dashboard: laufender Container-Tag vs. neuester Tag, Changelog-Link, Notifications | nur Docker, liest **laufende Container**, nicht das Repo |
| **Renovate** | Config im Repo + App/Cronjob | automatische Update-PRs mit eingebetteten Release-Notes + Dependency-Dashboard-Issue | siehe unten |

---

## 4. Renovate im Detail

### Was es liefert

- **Dependency Dashboard** – ein Issue, das Renovate automatisch im Repo anlegt
  und pflegt: Liste aller erkannten Abhängigkeiten mit aktueller Version,
  verfügbaren Updates (gruppiert nach Patch/Minor/Major), Checkboxen zum
  Auslösen der PRs, Abschnitte für offene/fehlgeschlagene PRs. Das ist
  funktional die Tabelle „habe ich / gibt es".
- **Release Notes in jedem PR** – automatisch aus den GitHub-Releases gezogen
  und in die PR-Beschreibung eingebettet.
- Major-Updates werden separat gehalten und markiert (`⚠️`/Label).
- Optional **Merge-Confidence**-Badges (Verbreitung, Rückrollungen).
- Konfigurierbar: Patch automatisch mergen, Minor/Major nur als PR; Updates
  bündeln (z. B. „Sonntag früh"); einzelne Dienste ignorieren/pinnen.

### Was es nicht macht

- **Keine dedizierte Breaking-Changes-Extraktion.** Es zeigt die kompletten
  Release-Notes; ob „BREAKING" drinsteht, muss man lesen. (ESPHome und
  Zigbee2MQTT haben dafür immerhin feste Abschnitte.)
- **Kennt nur das Repo, nicht das laufende System.** Kann also nicht sagen „im
  Repo steht 2.1.3, auf dem LXC läuft noch 2.0.9".
- **Keine frei gestaltbare Web-Oberfläche.** Die gehostete Variante (Mend
  Developer Platform) hat eine, ist aber auf Firmen zugeschnitten.

### Ansible-Variablen für Renovate sichtbar machen

Freie Versions-Strings in YAML erkennt Renovate nicht von allein – es braucht
einen **Custom Manager** (regex) und einen Kommentar über der Variable, der die
Datenquelle nennt:

```yaml
# renovate: datasource=github-releases depName=esphome/esphome
esphome_version: "2025.7.1"
```

Docker-Tags, `docker-compose`, GitHub Actions und pip erkennt Renovate ohne
Zusatz-Config.

---

## 5. Eigenes Dashboard-Tool

**Nicht als Ersatz für Renovate, sondern als Anzeige-Schicht darüber.** Der
schwierige Teil – für viele Registries die „neueste Version" korrekt ermitteln,
Changelogs finden, SemVer sortieren – ist in Renovate gelöst und soll nicht
nachgebaut werden.

### Mehrwert gegenüber dem Dependency Dashboard

1. **Echte Web-Seite** statt GitHub-Issue (eigener kleiner LXC).
2. **Abgleich Repo ↔ laufendes System**: `versions.yml` gegen das, was per
   SSH/API auf den Containern wirklich installiert ist. Das kann **kein**
   fertiges Tool, weil es das eigene Setup ist – das ist das Alleinstellungs-
   merkmal.
3. **Breaking Changes aggregiert**: aus den offenen Renovate-PRs die
   Release-Notes ziehen und nur die „Breaking"-Abschnitte hervorheben.

### Billiger Bauweg

1. Renovate per Cron im Lookup-/Dry-Run laufen lassen und die Ergebnisse als
   JSON ausgeben lassen (Report-Datei bzw. `LOG_LEVEL=debug` +
   `--dry-run=lookup`) → Liste „package, current, latest, updates[]".
2. Dieses JSON + `versions.yml` + optional ein Ansible-Fakten-Abgleich einlesen.
3. Als statische HTML-Tabelle rendern (einfaches Python-Skript + Template,
   kein Framework nötig).

Der Versions-/Changelog-Teil kommt komplett von Renovate; selbst geschrieben
wird nur die Darstellung und der System-Abgleich.

---

## 6. Empfohlene Reihenfolge

1. **Jetzt:** zentrale `versions.yml` anlegen, alle neuen Dienste dort exakt
   pinnen.
2. **Jetzt:** die Handvoll Dienste bei **newreleases.io** eintragen (oder Feeds
   in einen RSS-Reader). Null Wartungsaufwand, nichts wird verpasst.
3. **Wenn es mehr Dienste werden:** Renovate aktivieren (GitHub App oder
   self-hosted Container/Cronjob), Custom Manager für `versions.yml`,
   Patch-Auto-Merge an. Updates kommen dann als PR mit Changelog.
4. **Optional, als Projekt:** kleines HTML-Dashboard aus Renovate-JSON +
   `versions.yml` + „wirklich installiert"-Abgleich.

### Sonderfall: nur Container

Sind die neuen Dienste überwiegend Docker-Container, ist **What's Up Docker**
sofort einsatzbereit für den „gibt es was Neues"-Blick (laufender Tag vs.
neuester Tag, Changelog-Link, Notifications) – ohne Repo-Abgleich.

---

## 7. Technische Hinweise für später

- **Renovate self-hosted**: läuft als Container (`renovate/renovate`), braucht
  nur ein Repo-Token und eine `renovate.json` im Repo. Kein Server-Dauerbetrieb
  nötig – ein Cronjob pro Tag reicht.
- **Datasources** für den Custom Manager: `github-releases`, `github-tags`,
  `docker`, `pypi` decken hier fast alles ab. `depName` = `owner/repo` bzw.
  Image-Name.
- **RSS-Feed-URLs**: Releases `…/releases.atom`, Tags `…/tags.atom` (für
  Projekte ohne gepflegte Releases).
- **Registry-Tags ad hoc prüfen** ohne Image-Pull:
  `skopeo list-tags docker://<image>` oder `regctl tag ls <image>`.
- **Verzeichnis** für ein eigenes Dashboard-Tool: eigenes Top-Level (z. B.
  `tools/version-dashboard/`), nicht in `roles/` oder `playbooks/` mischen.
