import AppKit
import Observation

struct SettingsPreset: Identifiable {
    let id: String
    var name: String
    var values: [String: Any]
    var date: Date
}

// 現在の設定（Dock・外観・並び・ウィジェット・ディスプレイ専用の設定）を丸ごと保存し、切り替える
@Observable
final class SettingsPresets {
    static let shared = SettingsPresets()

    private static let storageKey = "settingsPresets"
    private(set) var presets: [SettingsPreset] = []

    private init() {
        let list = UserDefaults.standard.array(forKey: Self.storageKey) as? [[String: Any]] ?? []
        presets = list.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String, let values = d["values"] as? [String: Any]
            else { return nil }
            return SettingsPreset(id: id, name: name, values: values, date: d["date"] as? Date ?? .distantPast)
        }
    }

    private func persist() {
        let list: [[String: Any]] = presets.map { ["id": $0.id, "name": $0.name, "values": $0.values, "date": $0.date] }
        UserDefaults.standard.set(list, forKey: Self.storageKey)
    }

    private static func isTarget(_ key: String) -> Bool {
        DockSettings.isSnapshotKey(key) || DockModel.persistedKeys.contains(key)
    }

    // 標準ドメイン（グローバル設定を含まない）から読む
    private static func storedValues() -> [String: Any] {
        let d = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier, let domain = d.persistentDomain(forName: id) { return domain }
        return d.dictionaryRepresentation()
    }

    static func snapshot() -> [String: Any] {
        storedValues().filter { isTarget($0.key) }
    }

    func currentID() -> String? {
        let now = NSDictionary(dictionary: Self.snapshot())
        return presets.first { now.isEqual(to: $0.values) }?.id
    }

    @discardableResult
    func saveCurrent(name: String) -> SettingsPreset {
        let p = SettingsPreset(id: UUID().uuidString, name: name, values: Self.snapshot(), date: Date())
        presets.append(p)
        persist()
        return p
    }

    func overwrite(_ id: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].values = Self.snapshot()
        presets[i].date = Date()
        persist()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = trimmed
        persist()
    }

    func delete(_ id: String) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func apply(_ id: String) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let d = UserDefaults.standard
        let s = DockSettings.shared
        let wasHidingSystemDock = s.hideSystemDock
        let weather = (s.weatherCity, s.useCurrentLocation, s.temperatureUnit)

        // プリセットに無いキーは消して既定値に戻す
        for key in Self.storedValues().keys where Self.isTarget(key) && preset.values[key] == nil {
            d.removeObject(forKey: key)
        }
        for (key, value) in preset.values where Self.isTarget(key) {
            d.set(value, forKey: key)
        }

        DockSettings.reloadAll()
        DockModel.shared.reloadPersisted()
        if s.hideSystemDock != wasHidingSystemDock { SystemDock.setHidden(s.hideSystemDock) }
        if weather != (s.weatherCity, s.useCurrentLocation, s.temperatureUnit) { WidgetHub.shared.weather.refresh() }
    }

    func defaultName() -> String {
        var n = presets.count + 1
        while presets.contains(where: { $0.name == loc("プリセット %d", n) }) { n += 1 }
        return loc("プリセット %d", n)
    }
}
