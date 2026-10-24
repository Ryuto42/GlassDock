import AppKit
import ApplicationServices

enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedKey = "savedSystemDockState"

    static func metrics() -> (tileSize: Double, largeSize: Double, magnification: Bool, position: String) {
        func number(_ key: String) -> Double? { (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.doubleValue }
        let tile = number("tilesize") ?? 48
        let large = number("largesize") ?? 64
        let mag = (CFPreferencesCopyAppValue("magnification" as CFString, domain) as? Bool) ?? false
        let orientation = (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String) ?? "bottom"
        return (tile, max(large, tile), mag, orientation)
    }

    static func persistentAppURLs() -> [URL] {
        urls(forKey: "persistent-apps")
    }

    static func persistentOtherURLs() -> [URL] {
        urls(forKey: "persistent-others").filter { $0.hasDirectoryPath }
    }

    private static func urls(forKey key: String) -> [URL] {
        // 隠している間は書き換えているので、元の並びを読む
        let saved = UserDefaults.standard.dictionary(forKey: savedKey)?[key]
        let value: Any? = saved.flatMap { ($0 as? String) == "__none__" ? nil : $0 } ?? CFPreferencesCopyAppValue(key as CFString, domain).map { $0 as Any }
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let tile = item["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let str = file["_CFURLString"] as? String
            else { return nil }
            let url = URL(string: str) ?? URL(fileURLWithPath: str)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // 隠している間に書き換える標準 Dock の設定（今の値から、隠している間の値を作る）。
    // no-bouncing は通知でアプリのアイコンが弾んで表に出てくるのを防ぐ。
    // ダウンロード完了ではフォルダのスタックが弾んで表に出てくるため、フォルダのスタックを一時的に外す
    private static let managed: [(key: String, value: (CFPropertyList?) -> CFPropertyList)] = [
        ("autohide", { _ in true as CFBoolean }),
        ("autohide-delay", { _ in 1000.0 as CFNumber }),
        ("no-bouncing", { _ in true as CFBoolean }),
        ("persistent-others", { current in
            let items = current as? [[String: Any]] ?? []
            return items.filter { ($0["tile-type"] as? String) != "directory-tile" } as CFArray
        }),
    ]

    // 元の設定を保存してから、システム Dock を実質的に出てこなくする。すでにその状態なら Dock を再起動しない
    static func setHidden(_ hidden: Bool) {
        let d = UserDefaults.standard
        if hidden {
            var state = d.dictionary(forKey: savedKey) ?? [:]
            let currents = managed.map { CFPreferencesCopyAppValue($0.key as CFString, domain) }
            // 以前のバージョンで保存した状態に無い項目は、書き換える前の値をここで足す
            for (i, (key, _)) in managed.enumerated() where state[key] == nil {
                state[key] = currents[i] ?? "__none__" as CFString
            }
            // 途中で強制終了しても次の起動で戻せるよう、書き換える前に元の値を保存しておく
            d.set(state, forKey: savedKey)
            var changed = false
            for (i, (key, make)) in managed.enumerated() {
                let value = make(currents[i])
                if !(currents[i].map { CFEqual($0, value) } ?? false) {
                    write(key, value)
                    changed = true
                }
            }
            guard changed else { return }
        } else {
            guard let state = d.dictionary(forKey: savedKey) else { return }
            for (key, _) in managed {
                let v = state[key]
                write(key, v == nil || (v as? String) == "__none__" ? nil : v as CFPropertyList?)
            }
            d.removeObject(forKey: savedKey)
        }
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    static var hasSavedState: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    private static func write(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }

    // システム Dock の AX ツリーからバッジ（未読数など）を読む
    nonisolated static func badges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        for list in root.children where list.role == kAXListRole {
            for item in list.children {
                guard let label: String = item.attribute("AXStatusLabel"), !label.isEmpty,
                      let url: URL = item.attribute(kAXURLAttribute)
                else { continue }
                result[url.standardizedFileURL.path] = label
            }
        }
        return result
    }
}

extension AXUIElement {
    nonisolated func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        if T.self == URL.self, let v = value, CFGetTypeID(v) == CFURLGetTypeID() {
            return (v as! CFURL) as URL as? T
        }
        return value as? T
    }

    nonisolated var children: [AXUIElement] { attribute(kAXChildrenAttribute) ?? [] }
    nonisolated var role: String? { attribute(kAXRoleAttribute) }

    @discardableResult
    nonisolated func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    nonisolated func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}
