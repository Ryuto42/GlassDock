#!/bin/zsh
# GlassDock のビルド
#   ./build.sh            build/GlassDock.app を作る
#   ./build.sh run        作ってそのまま起動する
#   ./build.sh install    /Applications にインストールして起動する
#
# 環境変数
#   SIGN_IDENTITY   署名に使う証明書（未指定なら Apple Development、なければアドホック署名）
#   ARCHS           "arm64" または "arm64 x86_64"（既定は arm64）
#   VERSION / BUILD Info.plist のバージョンを上書きする（リリース時に使う）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/GlassDock.app"
ARCHS="${ARCHS:-arm64}"
arch_flags=()
for a in ${=ARCHS}; do arch_flags+=(--arch "$a"); done

swift build -c release "${arch_flags[@]}"
BIN="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/GlassDock" "$APP/Contents/MacOS/GlassDock"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"; done

PLIST="$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

# アップデート検証用の公開鍵（秘密ではない）。scripts/setup-sparkle-keys.sh で作る
if [[ -s Resources/sparkle-public-key.txt ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(tr -d '[:space:]' < Resources/sparkle-public-key.txt)" "$PLIST"
else
  echo "warning: Resources/sparkle-public-key.txt がないため、このビルドでは自動アップデートが無効です" >&2
fi

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

# Sparkle の中身は内側から順に署名する（--deep は使わない）
# 公証には Developer ID 署名とタイムスタンプが必要
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == *"Developer ID"* ]] && TIMESTAMP="--timestamp"
sign() { codesign --force "$TIMESTAMP" --options runtime --sign "$IDENTITY" "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --entitlements Resources/GlassDock.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST"), signed: ${IDENTITY/-/ad-hoc})"

case "${1:-}" in
  run)
    pkill -x GlassDock || true
    sleep 0.5
    open "$APP"
    ;;
  install)
    pkill -x GlassDock || true
    sleep 0.5
    rm -rf /Applications/GlassDock.app
    ditto "$APP" /Applications/GlassDock.app
    open /Applications/GlassDock.app
    echo "Installed /Applications/GlassDock.app"
    ;;
esac
