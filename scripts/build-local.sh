#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_DIRECTORY="$ROOT/local/signing"
export SIGNING_KEYCHAIN="$SIGNING_DIRECTORY/OpenDDPM.keychain-db"
export SIGNING_IDENTITY="OpenDDPM Local Development"
if [ ! -f "$SIGNING_KEYCHAIN" ] || [ ! -f "$SIGNING_DIRECTORY/password" ]; then
  echo "Local signing identity is missing. Restore the existing local/signing backup; do not regenerate an identity for each update." >&2
  exit 1
fi
security unlock-keychain -p "$(cat "$SIGNING_DIRECTORY/password")" "$SIGNING_KEYCHAIN"
exec "$ROOT/scripts/build.sh"
