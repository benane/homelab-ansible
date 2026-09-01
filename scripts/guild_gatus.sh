#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version aus den Rollen-Defaults (yq oder grep/awk)
VERSION="$(awk -F'"' '/^gatus_version:/{print $2}' "$ROOT/roles/gatus/defaults/main.yml")"
DEST="$ROOT/roles/gatus/files/gatus-${VERSION}-linux-amd64"

[[ -f "$DEST" ]] && { echo "$DEST existiert – fertig."; exit 0; }

BUILD="$(mktemp -d)"; trap 'rm -rf "$BUILD"' EXIT
git clone --depth 1 --branch "v${VERSION}" https://github.com/TwiN/gatus.git "$BUILD"

# Toolchain aus dem geklonten go.mod ziehen -> löst dein 1.27-Problem automatisch
TC="go$(awk '/^go [0-9]/{print $2}' "$BUILD/go.mod")"

( cd "$BUILD" && GOTOOLCHAIN="$TC" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o "$DEST" . )

file "$DEST"
