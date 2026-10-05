#!/bin/bash
set -euo pipefail

# Builds the launcher icon — a proper multi-resolution AppIcon.icns (so it renders
# crisply in Finder, Launchpad, Spotlight and Get Info) from the high-res source
# PNG. The old icns held a single 512px image, which several launchers reject.
#
# Usage: make_icns.sh [source.png] [out.icns]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Resources/icon-fluted.png}"
OUT="${2:-$ROOT/Resources/AppIcon.icns}"

if [ ! -f "$SRC" ]; then
  echo "Source icon not found: $SRC" >&2
  exit 1
fi

WORK="$(mktemp -d)"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

# size -> filename (each retina @2x is twice the point size).
gen() { sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$WORK"
echo "Wrote $OUT"
