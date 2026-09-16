#!/usr/bin/env bash
set -e

KEY_PATH="$HOME/.ssh/id_ed25519_ansible"

echo "==> Prüfe Ansible SSH-Key..."
if [ ! -f "$KEY_PATH" ]; then
    echo "==> Generiere neuen Ansible SSH-Key..."
    ssh-keygen -t ed25519 -C "ansible-control-node" -f "$KEY_PATH" -N ""
    echo "==> Key erfolgreich erstellt unter $KEY_PATH"
else
    echo "==> Ansible SSH-Key existiert bereits."
fi

# Ansible installieren (Beispiel für macOS via brew)
if ! command -v ansible &> /dev/null; then
    echo "==> Installiere Ansible..."
    brew install ansible
fi

echo "==> Setup abgeschlossen! Dein Public Key lautet:"
cat "${KEY_PATH}.pub"
