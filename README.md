# homelab-ansible

## Nutzung

### Gesamten Bestand konfigurieren

`site.yml` wendet Grundkonfiguration, Hardening, Proxmox-Setup und Netzwerk auf alle bekannten Hosts an. Beliebig oft wiederholbar (idempotent):

```bash
ansible-playbook playbooks/site.yml
```

### Einzelnen Container erstellen/konfigurieren

`container_site.yml` erzeugt/konfiguriert genau einen LXC-Container und braucht daher den Ziel-Host als Extra-Var:

```bash
ansible-playbook playbooks/container_site.yml -e target_host=lxc-zigbee2mqtt
```

**Erster Lauf für einen neuen Container:** Der `ansible`-Service-User existiert noch nicht (den legt erst die `common`-Rolle an), daher muss die Verbindung beim allerersten Mal als `root` erfolgen:

```bash
ansible-playbook playbooks/container_site.yml -e target_host=lxc-zigbee2mqtt -u root
```

Ab dem zweiten Lauf greift wieder der Default aus `ansible.cfg` (`remote_user = ansible`) – `-u root` nicht mehr nötig. `ansible_user: root` sollte deshalb **nicht** dauerhaft in `hosts.yml` stehen bleiben.

ToDo:
- backup restore
- node-exporter proxmox: aktuell über API token gelöst, node-exporter dort installieren oder in den proxmox setup schieben?
- proxmox token und berechtigungen automatisch anlegen?
- Wrapper-Script für Container-Erstellung (kapselt `-e target_host=` und beim ersten Lauf `-u root`, um Tippfehler zu vermeiden)
