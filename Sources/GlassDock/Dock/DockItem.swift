import AppKit

enum DockItemKind: Equatable {
    case app(URL)
    case folder(URL)
    case trash
    case divider
    case widget(WidgetKind)
    case control
}

struct DockItem: Identifiable, Equatable {
    let id: String
    let kind: DockItemKind
    let name: String
    var bundleID: String?
    var isPinned: Bool
    var runningApp: NSRunningApplication?

    var isRunning: Bool { runningApp != nil }

    var url: URL? {
        switch kind {
        case .app(let u), .folder(let u): u
        case .trash: FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        case .divider, .widget, .control: nil
        }
    }

    var widgetKind: WidgetKind? {
        if case .widget(let k) = kind { return k }
        return nil
    }

    var widthFactor: CGFloat { widgetKind?.widthFactor ?? 1 }

    static func app(url: URL, pinned: Bool, running: NSRunningApplication? = nil) -> DockItem {
        let bundle = Bundle(url: url)
        let id = bundle?.bundleIdentifier ?? running?.bundleIdentifier
        let name = running?.localizedName
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return DockItem(
            id: "app:" + (id ?? url.path),
            kind: .app(url),
            name: name,
            bundleID: id,
            isPinned: pinned,
            runningApp: running
        )
    }

    static func folder(url: URL) -> DockItem {
        DockItem(
            id: "folder:" + url.path,
            kind: .folder(url),
            name: FileManager.default.displayName(atPath: url.path),
            isPinned: true
        )
    }

    static func widget(_ kind: WidgetKind) -> DockItem {
        DockItem(id: "widget:" + kind.rawValue, kind: .widget(kind), name: kind.title, isPinned: true)
    }

    static let control = DockItem(id: "control", kind: .control, name: loc("コントロールセンター"), isPinned: true)

    static let trash = DockItem(id: "trash", kind: .trash, name: loc("ゴミ箱"), isPinned: true)

    static func divider(_ tag: String) -> DockItem {
        DockItem(id: "divider:" + tag, kind: .divider, name: "", isPinned: true)
    }

    nonisolated static func == (a: DockItem, b: DockItem) -> Bool {
        a.id == b.id && a.isPinned == b.isPinned && a.runningApp?.processIdentifier == b.runningApp?.processIdentifier
    }
}
