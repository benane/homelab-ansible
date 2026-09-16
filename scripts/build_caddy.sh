#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version aus den Rollen-Defaults (yq oder grep/awk)
VERSION="$(awk -F'"' '/^caddy_version:/{print $2}' "$ROOT/roles/caddy/defaults/main.yml")"
DEST="$ROOT/roles/caddy/files/caddy-${VERSION}-linux-amd64"

[[ -f "$DEST" ]] && { echo "$DEST existiert – fertig."; exit 0; }

command -v xcaddy >/dev/null || { echo "xcaddy fehlt – siehe docs/service-registry-plan.md Phase 1"; exit 1; }

# GOOS und GOARCH müssen zu caddy_binary_architecture in defaults/main.yml passen
(CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    xcaddy build v${VERSION} \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --output "$DEST")

file "$DEST"
