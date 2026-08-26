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

### Hinweise für den Betrieb

**Mosquitto komplett neu aufsetzen:** Beim Neubau des mosquitto-Containers gehen alle persistierten (retained) MQTT-Nachrichten verloren – u.a. die Home-Assistant-Discovery-Configs und der letzte bekannte Gerätezustand. Danach müssen alle MQTT-Clients (aktuell: zigbee2mqtt) manuell neu gestartet werden, damit sie sich neu verbinden und alles erneut publizieren:

```bash
ssh ansible@172.16.10.202
sudo systemctl restart zigbee2mqtt
```

Home-Assistant-Geräte sollten danach innerhalb weniger Sekunden wieder "available" werden.

ToDo:
- backup restore
- node-exporter proxmox: aktuell über API token gelöst, node-exporter dort installieren oder in den proxmox setup schieben?
- proxmox token und berechtigungen automatisch anlegen?
- Wrapper-Script für Container-Erstellung (kapselt `-e target_host=` und beim ersten Lauf `-u root`, um Tippfehler zu vermeiden)
- `container_vmid` dynamisch ermitteln lassen (nächste freie ID ab 201), statt sie fest in `hosts.yml` vorzugeben
- eventuell Wechsel von Uptime Kuma auf https://gatus.io (Config als YAML statt API/UI – passt besser zu Ansible)
- zigbee2mqtt läuft noch mit dem eingebauten Standard-`network_key`/`ext_pan_id` (nie individualisiert) – echte Zufallswerte generieren (`network_key` in den Vault) und in der Rolle setzen. Achtung: erfordert Neupairing aller Zigbee-Geräte, daher auf einen Termin mit Zeit dafür legen
