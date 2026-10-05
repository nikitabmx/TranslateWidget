#!/bin/bash
set -euo pipefail

# Builds a UNIVERSAL (arm64 + x86_64), ad-hoc-signed TranslateWidget.app and
# bundles it with the install guide into a single zip to hand to someone else.
# Universal so it runs on both Apple Silicon and Intel Macs.
#
# Output:
#   dist/TranslateWidget/TranslateWidget.app
#   dist/TranslateWidget/УСТАНОВКА.md
#   dist/TranslateWidget.zip   <- send this one file
#
# Note: ad-hoc signed, NOT notarized — the recipient must bypass Gatekeeper once
# (right-click → Open, or `xattr -dr com.apple.quarantine` after copying). See
# УСТАНОВКА.md.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TranslateWidget"
DIST="$ROOT/dist"
STAGE="$DIST/$APP_NAME"           # folder that gets zipped (app + guide)
APP="$STAGE/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
WORK="$(mktemp -d)"
DEPLOY="13.0"

FRAMEWORKS=(-framework Cocoa -framework WebKit -framework Carbon -framework AVFoundation -framework Speech)

echo "==> Clean dist"
rm -rf "$DIST"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Bundle metadata + icon"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/icon-fluted.png" ]; then
  if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ROOT/Resources/icon-fluted.png" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    "$ROOT/tools/make_icns.sh" >/dev/null
  fi
fi
cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

build_arch() {  # $1 = arch (arm64 | x86_64)
  local arch="$1"
  echo "==> Compiling for $arch"
  clang -arch "$arch" -mmacosx-version-min="$DEPLOY" -c -fobjc-arc "$ROOT/Sources/ObjCExceptionCatcher.m" -o "$WORK/objc-$arch.o"
  swiftc -O \
    "$ROOT"/Sources/*.swift \
    "$WORK/objc-$arch.o" \
    -import-objc-header "$ROOT/Sources/ObjCExceptionCatcher.h" \
    -target "$arch-apple-macos$DEPLOY" \
    -o "$WORK/$APP_NAME-$arch" \
    "${FRAMEWORKS[@]}"
}

build_arch arm64
if build_arch x86_64; then
  echo "==> Creating universal binary"
  lipo -create "$WORK/$APP_NAME-arm64" "$WORK/$APP_NAME-x86_64" -output "$MACOS_DIR/$APP_NAME"
else
  echo "   (x86_64 build failed — shipping arm64-only)"
  cp "$WORK/$APP_NAME-arm64" "$MACOS_DIR/$APP_NAME"
fi

echo "==> Architectures:"
lipo -info "$MACOS_DIR/$APP_NAME"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> Adding install guide"
cp "$ROOT/УСТАНОВКА.md" "$STAGE/УСТАНОВКА.md"

echo "==> Zipping bundle"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$APP_NAME.zip" )

rm -rf "$WORK"
echo "==> Done:"
echo "    $STAGE/  (app + guide)"
echo "    $DIST/$APP_NAME.zip  <- send this"
