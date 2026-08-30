# Runbook: Proxmox-Node in den Cluster joinen

Manuelle Schritte, um eine per `site.yml` vorbereitete Node in den bestehenden
Cluster aufzunehmen. Warum manuell: siehe ganz unten.

Beispiel hier: **Corellia** (pve-node02, 172.16.10.50) joint zu **Alderaan**
(pve-node01, 172.16.10.10). QDevice läuft auf **Mustafar** (wyse-3040,
172.16.10.60).

---

## 0. Vorbedingungen auf der neuen Node

Alles über `site.yml` erledigt – vor dem Join einmal gegenprüfen:

```bash
ssh root@172.16.10.50 '
  getent hosts Corellia;             # muss 172.16.10.50 liefern, NICHT 127.x
  timedatectl | grep synchronized;   # yes
  pvecm status 2>&1 | head -1;       # "does not exist … part of a cluster?" = standalone
'
```

Der ZFS-Pool `nvme-zfs` ist für den Join egal – er liegt nicht in `/etc/pve` und
bleibt erhalten.

---

## 1. SSH von der neuen Node zu Alderaan freischalten

`pvecm add` läuft **auf Corellia** und meldet sich per SSH als `root` bei Alderaan
an. Alderaan hat `PasswordAuthentication no` (hardening-Rolle) → Corellias
root-Key muss in Alderaans cluster-weite `authorized_keys`.

Vom Control-Node (Mac):

```bash
ansible pve-node02 -u root -m fetch \
  -a "src=/root/.ssh/id_rsa.pub dest=/tmp/corellia_root.pub flat=yes"

ansible pve-node01 -u root -m ansible.posix.authorized_key \
  -a "user=root path=/etc/pve/priv/authorized_keys manage_dir=false key='$(cat /tmp/corellia_root.pub)'"
```

(Falls das Modul mit der pmxcfs-Datei zickt: stattdessen `lineinfile` /
`blockinfile` auf denselben Pfad.)

Test:
```bash
ssh root@172.16.10.50 'ssh -o StrictHostKeyChecking=accept-new root@172.16.10.10 hostname'
# -> "Alderaan", ohne Passwortabfrage
```

---

## 2. Der Join

```bash
ssh root@172.16.10.50
pvecm add 172.16.10.10 --link0 172.16.10.50
```

- Fingerprint von Alderaan mit `yes` bestätigen
- **root-Passwort von Alderaan** eingeben
- ~1 Minute warten

> ⚠️ Beim Join wird Corellias `/etc/pve` durch die **Cluster-Kopie ersetzt**.
> Node-lokale PVE-Config auf Corellia (Storage-Einträge, lokale User) geht dabei
> verloren – deshalb kommt der `pvesm`-Eintrag für `nvme-zfs` erst **nach** dem
> Join (Schritt 4). Der zpool selbst bleibt.

Danach auf **beiden** Nodes:
```bash
pvecm status      # 2 Nodes, "Quorate"
pvecm nodes
```

Web-UI auf Corellia: neu einloggen (Zertifikat wurde neu erzeugt), oder einfach
Alderaans UI nutzen – die managt jetzt beide.

### Wenn der Join schiefgeht

Zurück auf standalone (auf Corellia):
```bash
systemctl stop pve-cluster corosync
pmxcfs -l
rm /etc/pve/corosync.conf
rm -rf /etc/corosync/*
killall pmxcfs
systemctl start pve-cluster
```
Dann Ursache fixen (fast immer: Namensauflösung / SSH zu Alderaan / Zeit) und
Schritt 2 neu.

---

## 3. QDevice einrichten (2-Node-Quorum)

2 Nodes = 2 Stimmen → fällt eine aus, hat die andere kein Quorum und der Cluster
wird read-only. Der Wyse als QDevice gibt die dritte Stimme.

```bash
# auf BEIDEN Cluster-Nodes:
apt install -y corosync-qdevice

# auf dem Wyse (172.16.10.60):
apt install -y corosync-qnetd

# von EINER Cluster-Node:
pvecm qdevice setup 172.16.10.60
```

`pvecm qdevice setup` braucht root-SSH zum Wyse. Hat der Wyse `PasswordAuthentication
no` (hardening lief), vorher den root-Key der Cluster-Node in
`/root/.ssh/authorized_keys` des Wyse legen – oder dort kurz Passwort-Auth
aktivieren und danach zurückdrehen.

Prüfen: `pvecm status` → 3 „Total votes", ein „Qdevice"-Block.

---

## 4. Post-Join per Ansible (`proxmox_cluster`-Rolle – noch zu bauen)

Ab hier ist `/etc/pve` cluster-weit, das läuft `run_once` gegen eine Node:

- **Storage:** `pvesm add zfspool nvme-zfs --pool nvme-zfs --nodes Alderaan,Corellia --content images,rootdir`
  (idempotent über `pvesm status`-Check; auf die Nodes beschränkt, die den Pool haben)
- **Firewall:** erst Regeln in `cluster.fw` / `host.fw`, **dann** `enable` –
  das Aktivieren wirkt sofort clusterweit
- **Replikation:** erst wenn Alderaans NVMe-Pool existiert

---

## Warum die zwei `pvecm`-Befehle nicht automatisiert sind

- **Einmalig pro Node, jemals.** Corellia joint genau einmal. Automatisierungs-ROI ≈ 0.
- **Interaktiv** – root-Passwort-Prompt und Fingerprint-Bestätigung. Nicht-interaktiv
  nur mit `expect`/`sshpass`-Gebastel.
- **Hohe Sprengkraft** – ein halb-gejointer Cluster ist übler aufzuräumen als der
  manuelle Schritt.
- `community.proxmox` (2.0.0) hat **kein** Cluster-Join-Modul.

Alles drumherum – Key-Preseed (Schritt 1), `proxmox_cluster`-Rolle (Schritt 4) –
ist sauber automatisierbar und gehört auch in Ansible. Nur der Bootstrap-Moment
bleibt Handarbeit.

---

## API-Token / `ansible@pve` – kein Thema für den Join

Der API-Token liegt in `/etc/pve/user.cfg` und ist damit **cluster-weit**. Sobald
Corellia gejoint ist, hat sie Alderaans `ansible@pve`-User + Token + ACLs
automatisch – für Corellia ist am Token **nichts** zu tun.

`site.yml` gegen Alderaan zu fahren braucht den Token ebenfalls nicht
(`common`/`hardening`/`proxmox_node` laufen alle per SSH-root). Der Token wird nur
von den Container-/VM-Provisioning-Playbooks gebraucht und existiert bereits
(Secret im Vault).

Die ToDo „proxmox token und berechtigungen automatisch anlegen" ist reine
Reproduzierbarkeit (Disaster Recovery): eine Rolle, die `pveum user add` /
`pveum user token add` / `pveum acl modify` einmalig `run_once` ausführt. Haken:
`pveum user token add` zeigt das Secret nur ein einziges Mal – die Rolle kann es
erzeugen, aber das Secret muss man danach von Hand in den Vault kopieren.
Semi-manuell, kein Blocker.
