import Foundation

// 日本語の文字列をそのままキーにして、Resources/<言語>.lproj/Localizable.strings から訳を引く。
// SwiftUI の Text("…") などに直接書いた文字列は自動で引かれるので、String として扱う文字列だけこれを通す
nonisolated func loc(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

// 書式付き。キーには %@ や %d を含める（例: loc("%d 項目", count)）
nonisolated func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: loc(key), locale: Locale.current, arguments: args)
}

// 設定で選ぶ表示言語。アプリの AppleLanguages を書き換え、再起動して反映する
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ja, en
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: loc("システムに合わせる")
        case .ja: "日本語"
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        guard let langs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = langs.first else { return .system }
        return first.hasPrefix("ja") ? .ja : first.hasPrefix("en") ? .en : .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
