#!/bin/bash
set -euo pipefail

# Builds TranslateWidget.app in the project folder, installs it into
# /Applications and (re)launches it from there — one installed copy, so macOS
# permissions (Accessibility, Screen Recording…) belong to a single app.

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TranslateWidget"
APP="$ROOT/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Quitting any running instance"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Copying Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# (Re)build the launcher icon if the source art is newer than the icns (or it's missing).
if [ -f "$ROOT/Resources/icon-fluted.png" ]; then
  if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ROOT/Resources/icon-fluted.png" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> Building launcher icon (AppIcon.icns)"
    "$ROOT/tools/make_icns.sh" >/dev/null
  fi
fi

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "==> Copying app icon"
  cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

echo "==> Compiling Objective-C sources"
OBJC_OBJECTS=()
for m in "$ROOT"/Sources/*.m; do
  [ -e "$m" ] || continue
  obj="$m.o"
  clang -c -fobjc-arc "$m" -o "$obj"
  OBJC_OBJECTS+=("$obj")
done

echo "==> Compiling Swift sources"
swiftc -O \
  "$ROOT"/Sources/*.swift \
  ${OBJC_OBJECTS[@]+"${OBJC_OBJECTS[@]}"} \
  -import-objc-header "$ROOT/Sources/ObjCExceptionCatcher.h" \
  -o "$MACOS_DIR/$APP_NAME" \
  -framework Cocoa \
  -framework WebKit \
  -framework Carbon \
  -framework AVFoundation \
  -framework Speech \
  -framework ServiceManagement

# Clean up intermediate Objective-C objects.
rm -f "$ROOT"/Sources/*.m.o

# Sign with a stable identity when there is one, so macOS keeps the granted
# permissions (Accessibility, Screen Recording…) across rebuilds — an ad-hoc
# signature changes with every build and macOS treats each build as a new app.
# SIGN_IDENTITY overrides; otherwise the first "Apple Development" certificate
# in the keychain. (Builds for other people — tools/build_dist.sh — stay ad-hoc,
# so they don't carry this certificate's name.)
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Code signing with \"$SIGN_IDENTITY\""
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" || {
    echo "   (signing with the certificate failed — falling back to ad-hoc)"
    codesign --force --deep --sign - "$APP"
  }
else
  echo "==> Ad-hoc code signing (no signing certificate — permissions reset on every build)"
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"
fi

# Strip the quarantine flag so Gatekeeper doesn't show "unidentified developer".
# (Locally built apps usually aren't quarantined, but this guarantees it.)
echo "==> Removing quarantine attribute"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Installing to $INSTALLED"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

echo "==> Relaunching $APP_NAME"
open "$INSTALLED"

echo "==> Done: $INSTALLED"
