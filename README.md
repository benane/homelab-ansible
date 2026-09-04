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
- proxmox token und berechtigungen automatisch anlegen?
- Wrapper-Script für Container-Erstellung (kapselt `-e target_host=` und beim ersten Lauf `-u root`, um Tippfehler zu vermeiden)
- `container_vmid` dynamisch ermitteln lassen (nächste freie ID ab 201), statt sie fest in `hosts.yml` vorzugeben
- eventuell Wechsel von Uptime Kuma auf https://gatus.io (Config als YAML statt API/UI – passt besser zu Ansible), bereits auf dem Wyse erfolgt. Heartbeats müssen noch eingerichtet werden. Auch: wie kann die Rolle mit einem LXC wiederverwendet werden?
- storyline:
    - cloudflared testen
    - heartbeats auf gatus
    - docker vom wyse entfernen
    - gatus auf lxc + passende endpoints
    - pihole und unbound baremetal auf rasppi und wyse
    - nebula_sync via ansible auf unraid
    - pihole lxc entfernen
- alle Versionen global sammeln und ein tool dafür, siehe untern
- cloudflared: von der Token-Methode auf die Config-Datei-Variante wechseln, damit das Routing versioniert in Ansible statt nur im Cloudflare-Dashboard liegt. Referenz: https://github.com/papanito/ansible-role-cloudflared (v.a. `configure_tunnels.yml` fürs Credentials-/Config-Template und `create_routes_dns.yml` für den DNS-Routing-Schritt, der bei dieser Methode zusätzlich nötig ist – Rest der Rolle ist für unseren Fall Overkill, siehe Chat-Review) -> super test für terraform
- esphome container mit pull der yaml configs aus github repo
- Container-Provisioning neu strukturieren: `playbooks/containers/bootstrap.yml` wird zur Rolle `proxmox_container` (nur Provisioning: create/start/tags, Defaults in `defaults/main.yml`); später analog `proxmox_vm`. Ein schlankes Orchestrierungs-Playbook (`guest_site.yml`) wählt LXC- vs. VM-Rolle und hängt danach `common` + `hardening` + Service-Rolle an. Service-Rollen bleiben eigenständig, werden **keine** Subrollen. Details: `docs/playbook-architecture.md`
  - Zwischenstand: Node und Storage sind schon inventory-gesteuert – `container_node` / `container_storage` je Host in `hosts.yml`, Fallback `proxmox_default_node` / `proxmox_default_storage` in `group_vars/all/proxmox.yml`. `bootstrap.yml` legt die Disk als `{{ ct_storage }}:{{ ct_disk }}` an. `lxc-mosquitto` (201) und `lxc-zigbee2mqtt` (202) damit auf `Corellia` + `nvme-zfs` festgenagelt.
- LXC 208 (`lxc-nginx-proxy`), 213 (`lxc-authentik`) und die HA-VM (`vm-hassio`) laufen physisch schon auf `Corellia`, sind im Inventory aber nur IP-Stubs. Beim Reproduzieren per Ansible: `container_vmid` / `container_role` / `container_node: Corellia` / `container_storage: nvme-zfs` nachziehen.
- Terraform evaluieren: erst nach Fertigstellung von `site.yml`, dann isoliert mit Cloudflare (DNS/Tunnel) als erstem Anwendungsfall, später ggf. Gast-Erstellung migrieren. Einschätzung und Einstiegsplan: `docs/terraform-evaluation.md`
- Versionen der neuen Dienste pinnen und Updates verfolgen: zentrale `versions.yml`, Benachrichtigung über newreleases.io/RSS, später Renovate (Dependency Dashboard + Changelog-PRs), optional eigenes HTML-Dashboard mit Repo-vs-installiert-Abgleich. Strategie und Reihenfolge: `docs/version-tracking.md`
