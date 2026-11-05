#!/bin/zsh
# Builds Vitals.app and installs it to ~/Applications.
#   ./build.sh            build, install, launch
#   ./build.sh --no-open  build and install only
#
# Sources are copied to ~/Library/Caches/VitalsBuild and compiled there, because OneDrive
# touches files mid-build ("modified during the build") and its extended attributes
# break code signing.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Vitals"
SCRATCH="$HOME/Library/Caches/VitalsBuild"
SRC="$SCRATCH/src"
STAGE="$SCRATCH/stage"
APP="$STAGE/$APP_NAME.app"
DEST_DIR="$HOME/Applications"

echo "→ Compiling (release)…"
mkdir -p "$SRC"
rsync -a --delete Package.swift Sources "$SRC/"
if ! swift build -c release --package-path "$SRC" --scratch-path "$SCRATCH/build" > "$SCRATCH/build.log" 2>&1; then
  grep -E 'error' "$SCRATCH/build.log" || cat "$SCRATCH/build.log"
  echo "✗ Build failed (full log: $SCRATCH/build.log)"
  exit 1
fi
BIN="$SCRATCH/build/release/$APP_NAME"

echo "→ Assembling $APP_NAME.app…"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --export-icon "$STAGE/icon_1024.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$STAGE/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$STAGE/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>local.vitals.monitor</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal system monitor</string>
</dict>
</plist>
PLIST

echo "→ Signing (ad hoc)…"
/usr/bin/xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "→ Installing to $DEST_DIR…"
mkdir -p "$DEST_DIR"
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "tell application id \"local.vitals.monitor\" to quit" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
  sleep 1
fi
rm -rf "$DEST_DIR/$APP_NAME.app"
ditto "$APP" "$DEST_DIR/$APP_NAME.app"
echo "✓ Installed $DEST_DIR/$APP_NAME.app"

if [[ "${1:-}" != "--no-open" ]]; then
  open "$DEST_DIR/$APP_NAME.app"
fi
