#!/bin/zsh
# DragConvert.app'i derler, paketler ve ad-hoc imzalar.
#
#   scripts/build-app.sh            → build/DragConvert.app
#   scripts/build-app.sh --install  → ayrıca ~/Applications/DragConvert.app (çalışan kopya kapatılıp yenisi açılır)
#   CONFIG=debug scripts/build-app.sh
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
VERSION=1.0.0
BUILD_NUMBER=$(date +%Y%m%d%H%M)
APP="$ROOT/build/DragConvert.app"

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/DragConvert" "$APP/Contents/MacOS/DragConvert"
# Hata ayıklama sembolleri derleme klasörünün yolunu (kullanıcı adı dahil) taşır; dağıtılan uygulamada gereksiz.
[[ "$CONFIG" == release ]] && strip -S -x "$APP/Contents/MacOS/DragConvert"

# SwiftPM kaynak paketleri (ör. Formats.json geldiğinde) Resources altına.
for bundle in "$BIN"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Derlenmiş ffmpeg varsa (scripts/build-ffmpeg.sh) pakete girer.
# Paylaşılan libav* dylib'leri programların yanında (@executable_path), sürüm bağlantıları korunarak.
if [[ -x "$ROOT/Vendor/ffmpeg/bin/ffmpeg" ]]; then
  cp -P "$ROOT"/Vendor/ffmpeg/bin/* "$APP/Contents/Helpers/"
fi

# Uygulama ikonu: scripts/make-icon.swift'ten, değişmedikçe önbellekten.
ICON_CACHE="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICON_CACHE" || "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE" ]]; then
  ICONSET="$ROOT/build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET/icon_512x512@2x.png"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DragConvert</string>
  <key>CFBundleIdentifier</key><string>io.github.emirberk04.DragConvert</string>
  <key>CFBundleName</key><string>DragConvert</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDisplayName</key><string>DragConvert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>DragConvert asks Word, PowerPoint and Excel to save documents as PDF and other Office formats.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc imza: Apple Silicon imzasız kodu çalıştırmaz; kişisel kullanım için Developer ID gerekmez.
for tool in "$APP"/Contents/Helpers/*(N); do
  [[ -L "$tool" ]] || codesign --force --sign - "$tool"
done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Hazır: $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/DragConvert.app"
  mkdir -p "$HOME/Applications"
  pkill -x DragConvert 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Kuruldu ve açıldı: $DEST"
fi
