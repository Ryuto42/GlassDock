#!/bin/zsh
# リリース用の zip とアップデート情報（appcast.xml）を dist/ に作る
#   scripts/release.sh 1.0.1
# 作ったファイルを GitHub のリリースに添付すると、既存ユーザーに Sparkle 経由で配信される。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?使い方: scripts/release.sh <バージョン>  例: 1.0.1}"
REPO="Ryuto42/GlassDock"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"

[[ -s Resources/sparkle-public-key.txt ]] || { echo "先に scripts/setup-sparkle-keys.sh を実行してください" >&2; exit 1; }
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || echo "warning: コミットされていない変更があります" >&2

# CFBundleVersion は Sparkle が新旧の比較に使うため、必ず増える値にする
BUILD="$(date +%Y%m%d%H%M)"
VERSION="$VERSION" BUILD="$BUILD" ARCHS="arm64 x86_64" SIGN_IDENTITY="${SIGN_IDENTITY:--}" ./build.sh

rm -rf dist && mkdir -p dist
ZIP="dist/GlassDock-$VERSION.zip"

# Developer ID で署名し、NOTARY_PROFILE（xcrun notarytool store-credentials で作る）があれば公証する
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent build/GlassDock.app dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/GlassDock.app
  rm dist/notarize.zip
else
  echo "warning: 公証していないビルドです。初回起動時に「右クリック → 開く」が必要になります" >&2
fi

ditto -c -k --sequesterRsrc --keepParent build/GlassDock.app "$ZIP"

# 秘密鍵（キーチェーン）で zip に署名し、appcast.xml を作る
"$TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  dist

shasum -a 256 "$ZIP"
cat <<MSG

できました:
  $ZIP
  dist/appcast.xml

公開するには（内容を確認してから実行してください）:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION $ZIP dist/appcast.xml --title "GlassDock $VERSION" --generate-notes
MSG
