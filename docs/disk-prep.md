# Runbook: Platte für den `nvme-zfs`-Pool vorbereiten

Wenn `storage.yml` abbricht, weil die Zielplatte nicht leer ist (alte
Installation, altes LVM, altes Dateisystem), muss sie **von Hand** gewischt
werden. Bewusst nicht in Ansible – siehe „Warum manuell" unten.

Ausgangslage hier: eine Node wurde neu auf der SATA-SSD installiert, die NVMe
enthält aber noch die vorherige Proxmox-Installation.

---

## 1. Zielplatte identifizieren

```bash
ls -l /dev/disk/by-id/ | grep nvme          # by-id-Name der Datenplatte
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS         # Überblick, was wo hängt
```

**Vergewissern**, dass es NICHT die Boot-Platte ist:
```bash
findmnt /                                    # zeigt, auf welchem Device / liegt
lsblk -no PKNAME "$(findmnt -no SOURCE /)"   # deren physisches Device
```
Die NVMe darf hier **nicht** auftauchen.

---

## 2. Altes LVM entfernen (falls vorhanden)

```bash
vgs                                          # Volume Groups auflisten
# Alt-Installation heißt meist "pve-OLD-<hex>" (Installer benennt Konflikt-VG um)
vgremove -f pve-OLD-XXXXXXXX
pvremove /dev/nvme0n1p3                       # PV-Partition (Pfad aus lsblk)
```

---

## 3. Signaturen und Partitionstabelle löschen

```bash
wipefs -a /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3   # FS-/ESP-Signaturen
sgdisk --zap-all /dev/nvme0n1                            # GPT + Backup-GPT weg
partprobe /dev/nvme0n1 2>/dev/null || blockdev --rereadpt /dev/nvme0n1
```

`partprobe` fehlt auf minimalem PVE (Paket `parted`) – `sgdisk` schreibt die
Kernel-Sicht meist schon selbst neu, sonst `blockdev --rereadpt`.

**Prüfen** – die Platte muss jetzt blank sein, ohne `p1/p2/p3`:
```bash
lsblk /dev/nvme0n1
wipefs /dev/nvme0n1                          # darf nichts mehr ausgeben
```

---

## 4. Tote EFI-Einträge aufräumen (nur wenn die Platte einen alten ESP hatte)

```bash
efibootmgr -v
# Einträge, die auf die GPT-GUID der gelöschten ESP-Partition zeigen:
efibootmgr -b XXXX -B
```
Vorher sicherstellen, dass der aktive Boot-Eintrag auf die **SATA**-SSD zeigt und
in der Bootreihenfolge vorn steht – sonst bootet die Firmware ins Leere.

---

## 5. Weiter mit Ansible

```bash
ansible-playbook playbooks/site.yml --limit <node>
```
`storage.yml` sieht jetzt die leere Platte und legt `nvme-zfs` an.
Danach prüfen: `zpool status` – Member muss der `by-id`-Name sein, nicht `nvme0n1`.

---

## Warum manuell

- **Sprengkraft.** `wipefs -a` / `sgdisk --zap-all` / `vgremove -f` in einer Rolle,
  die bei jedem `site.yml` läuft, zerstört bei einer falschen Variable die Node –
  ohne Rückfrage, ohne Rückweg.
- **Keine echte Idempotenz.** „Platte wischen" ist eine destruktive Einmal-Aktion,
  kein Ziel-Zustand. Die nötigen Guards („nur wenn Fremd-Signatur da") sind genau
  die Stelle, an der ein Bug katastrophal wird.
- **Läuft einmal pro Platte, jemals.** Risiko/Nutzen ist mies.

Arbeitsteilung: **Ansible erstellt Pools auf sauberen Platten, ein Mensch macht
Platten bewusst sauber.** `storage.yml` bricht mit klarer Meldung ab, wenn die
Platte nicht leer ist – dann dieses Runbook.
