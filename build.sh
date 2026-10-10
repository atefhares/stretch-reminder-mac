#!/bin/bash
# Puts the installer together from its three parts:
#   installer/installer-template.sh   the install / test / status / uninstall script
#   src/main.swift                    the app
#   assets/icon-1024.png              the app icon
# and writes dist/install-stretch-reminder.sh (one self-contained file).
#
#   bash build.sh            build the installer
#   bash build.sh install    build it, then install the app from it

set -euo pipefail
cd "$(dirname "$0")"

TEMPLATE="installer/installer-template.sh"
SOURCE="src/main.swift"
ICON="assets/icon-1024.png"
OUT="dist/install-stretch-reminder.sh"

for file in "$TEMPLATE" "$SOURCE" "$ICON"; do
  if [ ! -f "$file" ]; then
    echo "Missing $file" >&2
    exit 1
  fi
done

# The markers that end the embedded parts must never appear inside them.
if grep -q '^STRETCH_SWIFT_SOURCE$' "$SOURCE"; then
  echo "src/main.swift contains a line that is exactly STRETCH_SWIFT_SOURCE; rename it." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
base64 < "$ICON" | tr -d '\n' | fold -w 76 > "$WORK/icon.b64"
echo >> "$WORK/icon.b64"

mkdir -p dist
awk -v source="$SOURCE" -v icon="$WORK/icon.b64" '
  $0 == "@@SWIFT_SOURCE@@" { while ((getline line < source) > 0) print line; close(source); next }
  $0 == "@@ICON_BASE64@@"  { while ((getline line < icon) > 0) print line; close(icon); next }
  { print }
' "$TEMPLATE" > "$OUT"

bash -n "$OUT"
echo "Built $OUT"

if [ "${1:-}" = "install" ]; then
  bash "$OUT"
else
  echo "Install with:  bash $OUT"
fi
