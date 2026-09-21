#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <host> [weitere ansible-playbook-Optionen, z.B. -u root]" >&2
    exit 1
fi

host="$1"; shift

# Zwei getrennte Aufrufe, bewusst: --limit gilt für den ganzen ansible-playbook-Prozess,
# ein angehängtes service_registry.yml würde vom selben --limit mitgefiltert und
# die Konsumenten-Plays (Caddy/Pi-hole/cloudflared/Gatus) würden übersprungen.
ansible-playbook "$ROOT/playbooks/container_site.yml" --limit "$host" "$@"
ansible-playbook "$ROOT/playbooks/service_registry.yml"
