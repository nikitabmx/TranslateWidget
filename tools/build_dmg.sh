#!/bin/bash
set -euo pipefail

# Builds dist/TranslateWidget.dmg — the drag-to-install disk image: the app,
# an Applications shortcut with an arrow between them, and the install guide.
# Rebuilds the universal app via build_dist.sh first (SKIP_BUILD=1 reuses the
# existing dist/TranslateWidget/TranslateWidget.app).
#
# Arranging the window drives Finder through AppleScript, so macOS may ask once
# to allow controlling Finder. If that's denied, the DMG still works — just
# with Finder's default icon layout.
#
# Finder quirks this works around (macOS 26):
#  - icon view options only stick when set directly on the window, not through
#    a variable (that yields a detached copy);
#  - Finder deletes .VolumeIcon.icns while it lays the window out, so the
#    volume icon goes in afterwards;
#  - path bar / status bar / tab bar visibility are the user's global settings
#    (setting them per window would change them for every Finder window), so
#    the window is sized with room for them instead.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TranslateWidget"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
GUIDE="УСТАНОВКА.md"
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW_DMG="$WORK/rw.dmg"
trap 'rm -rf "$WORK"' EXIT

# Window geometry — keep in sync with make_dmg_background.swift.
WIN_X=200
WIN_Y=120
WIN_W=600
WIN_H=474        # ~380pt of content + title bar + room for a tab bar / path bar
ICON_SIZE=100
ROW_Y=165        # icon centers
GUIDE_Y=300

if [ "${SKIP_BUILD:-0}" != "1" ] || [ ! -d "$APP" ]; then
  "$ROOT/tools/build_dist.sh"
fi

echo "==> Staging DMG contents"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/$GUIDE" "$STAGE/$GUIDE"

echo "==> Rendering window background"
swift "$ROOT/tools/make_dmg_background.swift" "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

echo "==> Creating writable image"
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ -format UDRW -ov "$RW_DMG" -quiet
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="$(echo "$ATTACH_OUT" | grep 'Apple_HFS' | sed -E 's/.*Apple_HFS[[:space:]]+//')"
VOLUME="$(basename "$MOUNT")"

arrange_window() {
  osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
    repeat 2 times -- the first pass can land before a fresh window is ready
      set arrangement of icon view options of container window to not arranged
      set icon size of icon view options of container window to $ICON_SIZE
      set text size of icon view options of container window to 13
      set background picture of icon view options of container window to file ".background:background.tiff"
      set position of item "$APP_NAME.app" of container window to {160, $ROW_Y}
      set position of item "Applications" of container window to {440, $ROW_Y}
      set position of item "$GUIDE" of container window to {300, $GUIDE_Y}
      close
      delay 1
      open
      delay 1
    end repeat
    close
  end tell
end tell
EOF
}

# True once Finder has flushed our icon view settings to the volume's .DS_Store.
layout_saved() {
  python3 - "$MOUNT/.DS_Store" "$ICON_SIZE" <<'PY'
import plistlib, re, sys
try:
    data = open(sys.argv[1], 'rb').read()
except OSError:
    sys.exit(1)
m = re.search(rb'icvpblob', data)
if not m or b'bwspblob' not in data:
    sys.exit(1)
length = int.from_bytes(data[m.end():m.end() + 4], 'big')
view = plistlib.loads(data[m.end() + 4:m.end() + 4 + length])
saved = (view.get('iconSize') == float(sys.argv[2]) and view.get('backgroundType') == 2
         and view.get('arrangeBy') == 'none')
sys.exit(0 if saved else 1)
PY
}

echo "==> Arranging the Finder window"
arranged=0
for pass in 1 2 3; do
  arrange_window >/dev/null || break
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if layout_saved; then arranged=1; break; fi
    sleep 1
  done
  [ "$arranged" = 1 ] && break
  echo "   (Finder hasn't saved the layout yet — retrying)"
done
if [ "$arranged" = 1 ]; then
  # Don't carry the build machine's tab bar over to the recipient's window.
  # Finder may still flush the store once more after closing the window, which
  # would undo the patch — so wait it out, patch, and re-check.
  sleep 3
  for _ in 1 2 3; do
    python3 "$ROOT/tools/dmg_hide_tabbar.py" "$MOUNT/.DS_Store" >/dev/null || { echo "   (left the tab bar setting as is)"; break; }
    sleep 2
    python3 "$ROOT/tools/dmg_hide_tabbar.py" "$MOUNT/.DS_Store" | grep -q "already hidden" && break
  done
else
  echo "   (couldn't arrange the window — the DMG will use Finder's default layout)"
fi

echo "==> Volume icon"
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$MOUNT" 2>/dev/null || true

# Open the window automatically when the image is mounted (unsupported on some Macs).
bless --folder "$MOUNT" --openfolder "$MOUNT" 2>/dev/null || true

sync
for attempt in 1 2 3 4 5; do
  hdiutil detach "$DEVICE" -quiet && break
  sleep 1
  [ "$attempt" = 5 ] && hdiutil detach "$DEVICE" -force -quiet
done

echo "==> Compressing"
hdiutil convert "$RW_DMG" -format ULFO -o "$DMG" -ov -quiet

echo "==> Done: $DMG"
