import SwiftUI

protocol LabeledOption: RawRepresentable, CaseIterable, Identifiable, Hashable where RawValue == String {
    var label: String { get }
}

extension LabeledOption {
    var id: String { rawValue }
}

enum DockPosition: String, LabeledOption {
    case bottom, left, right
    var label: String {
        switch self {
        case .bottom: loc("下")
        case .left: loc("左")
        case .right: loc("右")
        }
    }
    var isVertical: Bool { self != .bottom }
}

enum DockMaterial: String, LabeledOption {
    case liquidGlass, clearGlass, frosted, solid
    var label: String {
        switch self {
        case .liquidGlass: loc("リキッドグラス")
        case .clearGlass: loc("クリア")
        case .frosted: loc("すりガラス")
        case .solid: loc("単色")
        }
    }
}

enum DockLayoutStyle: String, LabeledOption {
    case floating, taskbar
    var label: String {
        switch self {
        case .floating: loc("フローティング")
        case .taskbar: loc("タスクバー")
        }
    }
}

enum AppearanceMode: String, LabeledOption {
    case system, light, dark
    var label: String {
        switch self {
        case .system: loc("システム")
        case .light: loc("ライト")
        case .dark: loc("ダーク")
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum MagnificationStyle: String, LabeledOption {
    case none, standard, wave, lift
    var label: String {
        switch self {
        case .none: loc("なし")
        case .standard: loc("標準")
        case .wave: loc("波")
        case .lift: loc("持ち上げ")
        }
    }
}

enum IndicatorStyle: String, LabeledOption {
    case dot, bar, glow, card, none
    var label: String {
        switch self {
        case .dot: loc("ドット")
        case .bar: loc("バー")
        case .glow: loc("グロー")
        case .card: loc("カード")
        case .none: loc("なし")
        }
    }
}

enum IconStyle: String, LabeledOption {
    case original, monochrome, tinted
    var label: String {
        switch self {
        case .original: loc("オリジナル")
        case .monochrome: loc("モノクロ")
        case .tinted: loc("色付き")
        }
    }
}

enum HoverEffect: String, LabeledOption {
    case none, glow, shine
    var label: String {
        switch self {
        case .none: loc("なし")
        case .glow: loc("グロー")
        case .shine: loc("ハイライト")
        }
    }
}

enum DividerStyle: String, LabeledOption {
    case line, space, none
    var label: String {
        switch self {
        case .line: loc("線")
        case .space: loc("余白")
        case .none: loc("なし")
        }
    }
}

enum ActiveClickAction: String, LabeledOption {
    case minimize, hide, none
    var label: String {
        switch self {
        case .minimize: loc("最小化")
        case .hide: loc("隠す")
        case .none: loc("何もしない")
        }
    }
}

enum TemperatureUnit: String, LabeledOption {
    case celsius, fahrenheit
    var label: String { self == .celsius ? "℃" : "℉" }
}

@Observable
final class DockSettings {
    static let shared = DockSettings(prefix: "")

    @ObservationIgnored private let defaults = UserDefaults.standard
    // ディスプレイ専用の設定は "display.<ID>." を前に付けたキーに保存する
    @ObservationIgnored let keyPrefix: String

    // 配置と挙動
    var position: DockPosition { didSet { save(position.rawValue, "position") } }
    var layoutStyle: DockLayoutStyle { didSet { save(layoutStyle.rawValue, "layoutStyle") } }
    var autoHide: Bool { didSet { save(autoHide, "autoHide") } }
    var activeClickAction: ActiveClickAction { didSet { save(activeClickAction.rawValue, "activeClickAction") } }
    var showRunningApps: Bool { didSet { save(showRunningApps, "showRunningApps") } }
    var showBadges: Bool { didSet { save(showBadges, "showBadges") } }
    var hideSystemDock: Bool { didSet { save(hideSystemDock, "hideSystemDock") } }
    var animationSpeed: Double { didSet { save(animationSpeed, "animationSpeed") } }
    var launchBounce: Bool { didSet { save(launchBounce, "launchBounce") } }
    var showControlCenter: Bool { didSet { save(showControlCenter, "showControlCenter") } }
    var showOnAllDisplays: Bool { didSet { save(showOnAllDisplays, "showOnAllDisplays") } }
    var showTrash: Bool { didSet { save(showTrash, "showTrash") } }
    var hiddenFolders: [String] { didSet { save(hiddenFolders, "hiddenFolders") } }

    // 背景
    var material: DockMaterial { didSet { save(material.rawValue, "material2") } }
    var appearanceMode: AppearanceMode { didSet { save(appearanceMode.rawValue, "appearanceMode") } }
    var tintHex: String { didSet { save(tintHex, "tintHex") } }
    var tintStrength: Double { didSet { save(tintStrength, "tintStrength") } }
    var cornerRatio: Double { didSet { save(cornerRatio, "cornerRatio") } }
    var borderWidth: Double { didSet { save(borderWidth, "borderWidth") } }
    var borderOpacity: Double { didSet { save(borderOpacity, "borderOpacity") } }
    var shadowStrength: Double { didSet { save(shadowStrength, "shadowStrength") } }
    var paddingScale: Double { didSet { save(paddingScale, "paddingScale") } }
    var darkTransparency: Double { didSet { save(darkTransparency, "darkTransparency") } }

    // アイコン
    var iconSize: Double { didSet { save(iconSize, "iconSize") } }
    var spacing: Double { didSet { save(spacing, "spacing") } }
    var magnificationStyle: MagnificationStyle { didSet { save(magnificationStyle.rawValue, "magnificationStyle") } }
    var magnifiedSize: Double { didSet { save(magnifiedSize, "magnifiedSize") } }
    var magnificationRange: Double { didSet { save(magnificationRange, "magnificationRange") } }
    var iconStyle: IconStyle { didSet { save(iconStyle.rawValue, "iconStyle") } }
    var iconTintHex: String { didSet { save(iconTintHex, "iconTintHex") } }
    var dimInactive: Bool { didSet { save(dimInactive, "dimInactive") } }
    var dimMinimized: Bool { didSet { save(dimMinimized, "dimMinimized") } }
    var indicatorShowsWindowCount: Bool { didSet { save(indicatorShowsWindowCount, "indicatorShowsWindowCount") } }
    var iconShadow: Bool { didSet { save(iconShadow, "iconShadow") } }
    var hoverEffect: HoverEffect { didSet { save(hoverEffect.rawValue, "hoverEffect") } }
    var alwaysShowLabels: Bool { didSet { save(alwaysShowLabels, "alwaysShowLabels") } }
    var indicator: IndicatorStyle { didSet { save(indicator.rawValue, "indicator") } }
    var indicatorHex: String { didSet { save(indicatorHex, "indicatorHex") } }
    var dividerStyle: DividerStyle { didSet { save(dividerStyle.rawValue, "dividerStyle") } }
    var badgeHex: String { didSet { save(badgeHex, "badgeHex") } }

    // プレビュー
    var previewEnabled: Bool { didSet { save(previewEnabled, "previewEnabled") } }
    var previewSize: Double { didSet { save(previewSize, "previewSize") } }
    var previewDelay: Double { didSet { save(previewDelay, "previewDelay") } }
    var livePreview: Bool { didSet { save(livePreview, "livePreview") } }
    var windowSwitcherEnabled: Bool { didSet { save(windowSwitcherEnabled, "windowSwitcherEnabled") } }

    // ウィジェット
    var weatherCity: String { didSet { save(weatherCity, "weatherCity") } }
    var useCurrentLocation: Bool { didSet { save(useCurrentLocation, "useCurrentLocation") } }
    var temperatureUnit: TemperatureUnit { didSet { save(temperatureUnit.rawValue, "temperatureUnit") } }
    var clock24h: Bool { didSet { save(clock24h, "clock24h") } }
    var clockSeconds: Bool { didSet { save(clockSeconds, "clockSeconds") } }
    var worldClocks: [String] { didSet { save(worldClocks, "worldClocks") } }
    var focusMinutes: Double { didSet { save(focusMinutes, "focusMinutes") } }
    var breakMinutes: Double { didSet { save(breakMinutes, "breakMinutes") } }

    // 専用の設定にしたディスプレイの ID（共通の設定にだけ保存する）
    var customDisplays: [String] { didSet { save(customDisplays, "customDisplays") } }
    // Dock を出さないディスプレイの ID（共通の設定にだけ保存する）
    var hiddenDisplays: [String] { didSet { save(hiddenDisplays, "hiddenDisplays") } }

    private init(prefix: String) {
        keyPrefix = prefix
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: prefix + key) as? T ?? fallback }
        func option<T: LabeledOption>(_ key: String, _ fallback: T) -> T { T(rawValue: value(key, fallback.rawValue)) ?? fallback }
        let system = SystemDock.metrics()

        position = option("position", DockPosition(rawValue: system.position) ?? .bottom)
        layoutStyle = option("layoutStyle", DockLayoutStyle.floating)
        autoHide = value("autoHide", false)
        activeClickAction = option("activeClickAction", ActiveClickAction.minimize)
        showRunningApps = value("showRunningApps", true)
        showBadges = value("showBadges", true)
        hideSystemDock = value("hideSystemDock", false)
        animationSpeed = value("animationSpeed", 1.0)
        launchBounce = value("launchBounce", true)
        showControlCenter = value("showControlCenter", true)
        showOnAllDisplays = value("showOnAllDisplays", true)
        showTrash = value("showTrash", true)
        hiddenFolders = value("hiddenFolders", [String]())
        dimMinimized = value("dimMinimized", true)
        indicatorShowsWindowCount = value("indicatorShowsWindowCount", true)

        material = option("material2", DockMaterial.liquidGlass)
        appearanceMode = option("appearanceMode", AppearanceMode.system)
        tintHex = value("tintHex", "#FFFFFF")
        tintStrength = value("tintStrength", 0.0)
        cornerRatio = value("cornerRatio", 0.42)
        borderWidth = value("borderWidth", 0.0)
        borderOpacity = value("borderOpacity", 0.3)
        shadowStrength = value("shadowStrength", 0.0)
        paddingScale = value("paddingScale", 1.0)
        darkTransparency = value("darkTransparency", 0.15)

        iconSize = value("iconSize", system.tileSize)
        spacing = value("spacing", 1.0)
        magnificationStyle = option("magnificationStyle", system.magnification ? MagnificationStyle.standard : .none)
        magnifiedSize = value("magnifiedSize", max(system.largeSize, system.tileSize + 16))
        magnificationRange = value("magnificationRange", 2.8)
        iconStyle = option("iconStyle", IconStyle.original)
        iconTintHex = value("iconTintHex", "#7A8CFF")
        dimInactive = value("dimInactive", false)
        iconShadow = value("iconShadow", false)
        hoverEffect = option("hoverEffect", HoverEffect.none)
        alwaysShowLabels = value("alwaysShowLabels", false)
        indicator = option("indicator", IndicatorStyle.dot)
        indicatorHex = value("indicatorHex", "")
        dividerStyle = option("dividerStyle", DividerStyle.line)
        badgeHex = value("badgeHex", "#FF3B30")

        previewEnabled = value("previewEnabled", true)
        previewSize = value("previewSize", 200.0)
        previewDelay = value("previewDelay", 0.12)
        livePreview = value("livePreview", true)
        windowSwitcherEnabled = value("windowSwitcherEnabled", true)

        weatherCity = value("weatherCity", "")
        useCurrentLocation = value("useCurrentLocation", true)
        temperatureUnit = option("temperatureUnit", TemperatureUnit.celsius)
        clock24h = value("clock24h", true)
        clockSeconds = value("clockSeconds", false)
        worldClocks = value("worldClocks", ["America/New_York", "Europe/London"])
        focusMinutes = value("focusMinutes", 25.0)
        breakMinutes = value("breakMinutes", 5.0)
        customDisplays = prefix.isEmpty ? value("customDisplays", [String]()) : []
        hiddenDisplays = prefix.isEmpty ? value("hiddenDisplays", [String]()) : []
    }

    // プリセットの復元で読み直している間は、読んだ値を書き戻さない
    @ObservationIgnored private var reloading = false

    private func save(_ value: Any, _ key: String) {
        guard !reloading else { return }
        defaults.set(value, forKey: keyPrefix + key)
    }

    // MARK: - プリセット用のスナップショット

    private typealias Field = (key: String, copy: (DockSettings, DockSettings) -> Void)

    private static func field<T: Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<DockSettings, T>) -> Field {
        (key, { to, from in if to[keyPath: path] != from[keyPath: path] { to[keyPath: path] = from[keyPath: path] } })
    }

    // UserDefaults に保存する項目の一覧。設定を足したらここにも加える（プリセットの保存・復元に使う）
    private static let fields: [Field] = [
        field("position", \.position), field("layoutStyle", \.layoutStyle), field("autoHide", \.autoHide),
        field("activeClickAction", \.activeClickAction), field("showRunningApps", \.showRunningApps),
        field("showBadges", \.showBadges), field("hideSystemDock", \.hideSystemDock),
        field("animationSpeed", \.animationSpeed), field("launchBounce", \.launchBounce),
        field("showControlCenter", \.showControlCenter), field("showOnAllDisplays", \.showOnAllDisplays),
        field("showTrash", \.showTrash), field("hiddenFolders", \.hiddenFolders),
        field("material2", \.material), field("appearanceMode", \.appearanceMode), field("tintHex", \.tintHex),
        field("tintStrength", \.tintStrength), field("cornerRatio", \.cornerRatio), field("borderWidth", \.borderWidth),
        field("borderOpacity", \.borderOpacity), field("shadowStrength", \.shadowStrength),
        field("paddingScale", \.paddingScale), field("darkTransparency", \.darkTransparency),
        field("iconSize", \.iconSize), field("spacing", \.spacing), field("magnificationStyle", \.magnificationStyle),
        field("magnifiedSize", \.magnifiedSize), field("magnificationRange", \.magnificationRange),
        field("iconStyle", \.iconStyle), field("iconTintHex", \.iconTintHex), field("dimInactive", \.dimInactive),
        field("dimMinimized", \.dimMinimized), field("indicatorShowsWindowCount", \.indicatorShowsWindowCount),
        field("iconShadow", \.iconShadow), field("hoverEffect", \.hoverEffect), field("alwaysShowLabels", \.alwaysShowLabels),
        field("indicator", \.indicator), field("indicatorHex", \.indicatorHex), field("dividerStyle", \.dividerStyle),
        field("badgeHex", \.badgeHex),
        field("previewEnabled", \.previewEnabled), field("previewSize", \.previewSize),
        field("previewDelay", \.previewDelay), field("livePreview", \.livePreview),
        field("windowSwitcherEnabled", \.windowSwitcherEnabled),
        field("weatherCity", \.weatherCity), field("useCurrentLocation", \.useCurrentLocation),
        field("temperatureUnit", \.temperatureUnit), field("clock24h", \.clock24h), field("clockSeconds", \.clockSeconds),
        field("worldClocks", \.worldClocks), field("focusMinutes", \.focusMinutes), field("breakMinutes", \.breakMinutes),
        field("customDisplays", \.customDisplays), field("hiddenDisplays", \.hiddenDisplays),
    ]

    private static let fieldKeys = Set(fields.map(\.key))

    // 共通の設定のキーか、"display.<ID>." を付けたディスプレイ専用のキーなら true
    static func isSnapshotKey(_ key: String) -> Bool {
        if fieldKeys.contains(key) { return true }
        guard key.hasPrefix("display.") else { return false }
        let rest = key.dropFirst("display.".count)
        guard let dot = rest.firstIndex(of: ".") else { return false }
        return fieldKeys.contains(String(rest[rest.index(after: dot)...]))
    }

    // UserDefaults の値を読み直してメモリ上の設定に反映する
    func reload() {
        let fresh = DockSettings(prefix: keyPrefix)
        reloading = true
        for f in Self.fields { f.copy(self, fresh) }
        reloading = false
    }

    static func reloadAll() {
        shared.reload()
        for id in profiles.keys where !shared.customDisplays.contains(id) { profiles[id] = nil }
        for p in profiles.values { p.reload() }
    }

    // MARK: - ディスプレイ専用の設定

    private static var profiles: [String: DockSettings] = [:]

    static var allInstances: [DockSettings] {
        [shared] + shared.customDisplays.map(settings(forDisplay:))
    }

    // 専用の設定がなければ共通の設定を返す
    static func settings(forDisplay id: String) -> DockSettings {
        guard shared.customDisplays.contains(id) else { return shared }
        if let p = profiles[id] { return p }
        let p = DockSettings(prefix: "display.\(id).")
        profiles[id] = p
        return p
    }

    static func setCustom(_ on: Bool, display id: String) {
        if on {
            guard !shared.customDisplays.contains(id) else { return }
            let p = DockSettings(prefix: "display.\(id).")
            p.copyAppearance(from: shared)
            profiles[id] = p
            shared.customDisplays.append(id)
        } else {
            let prefix = "display.\(id)."
            let d = UserDefaults.standard
            for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) { d.removeObject(forKey: key) }
            profiles[id] = nil
            shared.customDisplays.removeAll { $0 == id }
        }
    }

    // ディスプレイの名前を覚えておく（外したあとも設定画面に名前を出すため）
    static func remember(display id: String, name: String) {
        var names = UserDefaults.standard.dictionary(forKey: "displayNames") as? [String: String] ?? [:]
        guard names[id] != name else { return }
        names[id] = name
        UserDefaults.standard.set(names, forKey: "displayNames")
    }

    // 設定画面で付けた名前があればそれを、なければ macOS の名前を使う
    static func displayName(_ id: String) -> String {
        let d = UserDefaults.standard
        if let alias = (d.dictionary(forKey: "displayAliases") as? [String: String])?[id], !alias.isEmpty { return alias }
        if let name = (d.dictionary(forKey: "displayNames") as? [String: String])?[id], !name.isEmpty { return name }
        return loc("ディスプレイ %@", id)
    }

    static func systemDisplayName(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "displayNames") as? [String: String])?[id]
    }

    static func rename(display id: String, to name: String) {
        var aliases = UserDefaults.standard.dictionary(forKey: "displayAliases") as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        aliases[id] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(aliases, forKey: "displayAliases")
    }

    // 一度でも接続したディスプレイ
    static var knownDisplays: [String] {
        let names = UserDefaults.standard.dictionary(forKey: "displayNames") as? [String: String] ?? [:]
        return Array(Set(names.keys).union(shared.customDisplays).union(shared.hiddenDisplays))
    }

    // 専用の設定・名前・非表示の指定をすべて消し、一覧からも外す（接続中なら共通の設定で表示し直す）
    static func forget(display id: String) {
        setCustom(false, display: id)
        shared.hiddenDisplays.removeAll { $0 == id }
        let d = UserDefaults.standard
        for key in ["displayNames", "displayAliases"] {
            var dict = d.dictionary(forKey: key) as? [String: String] ?? [:]
            dict[id] = nil
            d.set(dict, forKey: key)
        }
    }

    // 配置・外観・アイコンに関する項目だけを写す（ウィジェットやプレビューの設定は共通のまま）
    func copyAppearance(from o: DockSettings) {
        position = o.position; layoutStyle = o.layoutStyle; autoHide = o.autoHide
        animationSpeed = o.animationSpeed; launchBounce = o.launchBounce
        material = o.material; appearanceMode = o.appearanceMode; tintHex = o.tintHex; tintStrength = o.tintStrength
        cornerRatio = o.cornerRatio; borderWidth = o.borderWidth; borderOpacity = o.borderOpacity
        shadowStrength = o.shadowStrength; paddingScale = o.paddingScale; darkTransparency = o.darkTransparency
        iconSize = o.iconSize; spacing = o.spacing; magnificationStyle = o.magnificationStyle
        magnifiedSize = o.magnifiedSize; magnificationRange = o.magnificationRange
        iconStyle = o.iconStyle; iconTintHex = o.iconTintHex; dimInactive = o.dimInactive; dimMinimized = o.dimMinimized
        iconShadow = o.iconShadow; hoverEffect = o.hoverEffect; alwaysShowLabels = o.alwaysShowLabels
        indicator = o.indicator; indicatorHex = o.indicatorHex; indicatorShowsWindowCount = o.indicatorShowsWindowCount
        dividerStyle = o.dividerStyle; badgeHex = o.badgeHex
    }

    var magnification: Bool { magnificationStyle == .standard || magnificationStyle == .wave }

    var maxIconSize: Double {
        switch magnificationStyle {
        case .standard, .wave: max(magnifiedSize, iconSize)
        case .lift, .none: iconSize
        }
    }

    var tint: Color {
        get { Color(hex: tintHex) }
        set { tintHex = newValue.hexString }
    }

    var iconTint: Color {
        get { Color(hex: iconTintHex) }
        set { iconTintHex = newValue.hexString }
    }

    var indicatorColor: Color {
        get { indicatorHex.isEmpty ? .primary : Color(hex: indicatorHex) }
        set { indicatorHex = newValue.hexString }
    }

    var badgeColor: Color {
        get { Color(hex: badgeHex) }
        set { badgeHex = newValue.hexString }
    }

    func spring(_ response: Double = 0.32, damping: Double = 0.78) -> Animation {
        .spring(response: response / max(animationSpeed, 0.1), dampingFraction: damping)
    }

    func matchSystemDock() {
        let system = SystemDock.metrics()
        apply(.tahoe)
        position = DockPosition(rawValue: system.position) ?? .bottom
        iconSize = system.tileSize
        magnificationStyle = system.magnification ? .standard : .none
        magnifiedSize = max(system.largeSize, system.tileSize + 16)
    }

    func apply(_ preset: DockPreset) {
        material = preset.material
        tintHex = preset.tintHex
        tintStrength = preset.tintStrength
        cornerRatio = preset.cornerRatio
        borderWidth = preset.borderWidth
        borderOpacity = preset.borderOpacity
        shadowStrength = preset.shadowStrength
        indicator = preset.indicator
        indicatorHex = preset.indicatorHex
        iconStyle = preset.iconStyle
        iconTintHex = preset.iconTintHex
        hoverEffect = preset.hoverEffect
        layoutStyle = preset.layoutStyle
        dividerStyle = preset.dividerStyle
        appearanceMode = preset.appearanceMode
    }
}

struct DockPreset: Identifiable {
    let id: String
    let name: String
    var material: DockMaterial = .liquidGlass
    var tintHex = "#FFFFFF"
    var tintStrength = 0.0
    var cornerRatio = 0.42
    var borderWidth = 0.0
    var borderOpacity = 0.3
    var shadowStrength = 0.0
    var indicator: IndicatorStyle = .dot
    var indicatorHex = ""
    var iconStyle: IconStyle = .original
    var iconTintHex = "#7A8CFF"
    var hoverEffect: HoverEffect = .none
    var layoutStyle: DockLayoutStyle = .floating
    var dividerStyle: DividerStyle = .line
    var appearanceMode: AppearanceMode = .system

    static let tahoe = DockPreset(id: "tahoe", name: loc("Tahoe"))
    static let all: [DockPreset] = [
        .tahoe,
        DockPreset(id: "clear", name: loc("クリア"), material: .clearGlass, cornerRatio: 0.5),
        DockPreset(id: "midnight", name: loc("ミッドナイト"), material: .liquidGlass, tintHex: "#0B1030", tintStrength: 0.55,
                   borderWidth: 0.5, borderOpacity: 0.25, shadowStrength: 0.4, indicator: .bar, indicatorHex: "#8FA2FF",
                   appearanceMode: .dark),
        DockPreset(id: "aurora", name: loc("オーロラ"), material: .liquidGlass, tintHex: "#7B5CFF", tintStrength: 0.35,
                   cornerRatio: 0.5, indicator: .glow, indicatorHex: "#B9A8FF", hoverEffect: .glow),
        DockPreset(id: "sakura", name: loc("サクラ"), material: .liquidGlass, tintHex: "#FF8FB8", tintStrength: 0.3,
                   indicator: .dot, indicatorHex: "#FFC2D8", hoverEffect: .shine, appearanceMode: .light),
        DockPreset(id: "mono", name: loc("モノ"), material: .frosted, cornerRatio: 0.3, indicator: .bar,
                   iconStyle: .monochrome, dividerStyle: .space),
        DockPreset(id: "taskbar", name: loc("タスクバー"), material: .frosted, cornerRatio: 0, borderWidth: 0.5,
                   borderOpacity: 0.2, indicator: .card, layoutStyle: .taskbar),
        DockPreset(id: "neon", name: loc("ネオン"), material: .solid, tintHex: "#0A0A12", tintStrength: 0.85, cornerRatio: 0.35,
                   borderWidth: 1.2, borderOpacity: 0.9, shadowStrength: 0.6, indicator: .glow, indicatorHex: "#00F0FF",
                   iconStyle: .original, hoverEffect: .glow, appearanceMode: .dark),
    ]
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
    }
}
