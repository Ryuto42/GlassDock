# コントリビューションガイド

GlassDock への協力をありがとうございます。

## 開発の始め方

1. Xcode 26 以降をインストールします
2. リポジトリをクローンし、`./build.sh run` でビルドして起動します
3. 初回はアクセシビリティと画面収録の許可が必要です

## コードの構成

| フォルダ | 内容 |
|---|---|
| `Sources/GlassDock/App` | 起動処理、権限、アップデート |
| `Sources/GlassDock/Dock` | Dock 本体の表示、項目、設定、ガラス |
| `Sources/GlassDock/Preview` | ホバー時のパネル、右クリックメニュー、コントロールセンター |
| `Sources/GlassDock/Services` | ウィンドウ操作、標準 Dock との連携、アプリ操作 |
| `Sources/GlassDock/Settings` | 設定画面 |
| `Sources/GlassDock/Switcher` | Option+Tab のウィンドウスイッチャー |
| `Sources/GlassDock/Widgets` | ウィジェットの種類・データ・表示 |

## 方針

- **軽さを優先します**：常時のポーリングは避け、通知やイベントで更新してください。定期処理が必要な場合は、表示中だけ動かします
- **プライバシーを守ります**：新しい通信先を増やす場合は、README のプライバシーの節も更新してください。ユーザーのデータをディスクに残す場合は、必要最小限にしてください
- **非公開 API**：使う場合は、存在を確かめてから呼び出し（`responds(to:)` など）、使えないときも落ちないようにしてください

## 翻訳

表示する文字列は日本語で書き、その日本語をキーにして英訳を引きます。

- SwiftUI の `Text("…")` などに直接書いた文字列は自動で訳されます。`String` として扱う文字列は `loc("…")`、数値などを含む文字列は `loc("%d 項目", count)` のように書いてください
- 英訳は `Resources/i18n/*.json` に `"日本語": "English"` の形で追加し、`python3 scripts/merge-strings.py` で `Resources/en.lproj/Localizable.strings` を作り直してください

## プルリクエスト

- 1 つのプルリクエストでは 1 つの変更にしてください
- UI の変更にはスクリーンショットか動画を添えてください
- `swift build -c release` が通り、新しい警告が増えていないことを確認してください
