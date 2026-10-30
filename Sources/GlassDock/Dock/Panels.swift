import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    private let keyable: Bool

    init(level: NSWindow.Level, keyable: Bool = false) {
        self.keyable = keyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        // transient: Mission Control / Exposé 中は自動的に隠れる（標準 Dock と二重にならない）
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    // GlassDock は前面のアプリにならないため、ガラスが常に非アクティブの控えめな描画になる。
    // システムの Dock と同じ縁のハイライトを出すため、アクティブな見た目として扱わせる
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum BackgroundCursor {
    // GlassDock は前面のアプリにならないため、通常は NSCursor.set() やポインタの形の指定が無視される。
    // 下のウィンドウの縁で付いたサイズ変更のカーソルが Dock の上に残らないよう、背面からでも設定できるようにする
    static func enable() {
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func arrow() { NSCursor.arrow.set() }
}

// 透明部分のクリックは下のウィンドウへ抜け、非アクティブでも1クリックで反応させる
final class PassthroughHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ディスプレイ1つ分の Dock の状態
@Observable
final class DockContext {
    let id: String
    // このディスプレイで使う設定（専用の設定がなければ共通の設定）
    @ObservationIgnored let settings: DockSettings
    @ObservationIgnored weak var window: NSWindow?
    let visibility = DockVisibility()
    @ObservationIgnored let watcher = DockHoverWatcher()

    init(id: String, settings: DockSettings) {
        self.id = id
        self.settings = settings
        visibility.settings = settings
        visibility.isMouseInside = { [weak watcher] in watcher?.containsMouse() ?? false }
        visibility.isMouseAtEdge = { [weak watcher] in watcher?.edgeContainsMouse(settings.position) ?? false }
    }

    func key(_ itemID: String) -> String { "\(id)|\(itemID)" }
}

@MainActor
final class DockPanelController {
    static let shared = DockPanelController()

    private struct Dock {
        let panel: OverlayPanel
        let context: DockContext
        var screen: NSScreen
    }

    private var docks: [String: Dock] = [:]
    private let settings = DockSettings.shared
    private var observers: [NSObjectProtocol] = []

    var contexts: [DockContext] { docks.values.map(\.context) }

    func context(for window: NSWindow?) -> DockContext? {
        guard let window else { return nil }
        return docks.values.first { $0.panel === window }?.context
    }

    func start() {
        BackgroundCursor.enable()
        syncScreens()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { DockPanelController.shared.syncScreens() } })
        observeSettings()
    }

    func scheduleHideAll() {
        contexts.forEach { $0.visibility.scheduleHide() }
    }

    // どれか1つでも Dock が見えていれば、ウィジェットのデータ取得を動かす
    func updateWidgetVisibility() {
        let visible = contexts.contains { !$0.settings.autoHide || $0.visibility.revealed }
        WidgetHub.shared.setDockVisible(visible)
    }

    static func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "\($0)" } ?? screen.localizedName
    }

    // 外部ディスプレイの接続・切断や設定の切り替えに合わせて、Dock を作る・消す
    func syncScreens() {
        let screens = (settings.showOnAllDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1)))
            .filter { !settings.hiddenDisplays.contains(Self.screenID($0)) }
        let wanted = Dictionary(screens.map { (Self.screenID($0), $0) }, uniquingKeysWith: { a, _ in a })
        for id in docks.keys where wanted[id] == nil { removeDock(id) }
        for (id, screen) in wanted {
            DockSettings.remember(display: id, name: screen.localizedName)
            let desired = DockSettings.settings(forDisplay: id)
            if var dock = docks[id] {
                if dock.context.settings === desired {
                    dock.screen = screen
                    docks[id] = dock
                    continue
                }
                // 専用の設定に切り替わったら作り直す
                removeDock(id)
            }
            let context = DockContext(id: id, settings: desired)
            let p = OverlayPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow))))
            let root = DockRootView()
                .environment(desired)
                .environment(DockModel.shared)
                .environment(context)
            p.contentView = PassthroughHostingView(rootView: AnyView(root))
            p.appearance = desired.appearanceMode.nsAppearance
            context.window = p
            context.watcher.window = p
            docks[id] = Dock(panel: p, context: context, screen: screen)
            p.orderFrontRegardless()
            // 起動時や、あとから接続したディスプレイでも、自動的に隠す設定ならしばらくして隠す
            context.visibility.scheduleHide(after: 2)
        }
        layout()
    }

    // ホバー中に消えると、マウスの監視とタイマーが残り続けるため止めておく
    private func removeDock(_ id: String) {
        guard let dock = docks.removeValue(forKey: id) else { return }
        dock.context.watcher.end()
        dock.panel.orderOut(nil)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.showOnAllDisplays
            _ = settings.customDisplays
            _ = settings.hiddenDisplays
            for s in DockSettings.allInstances {
                _ = s.position
                _ = s.iconSize
                _ = s.magnifiedSize
                _ = s.magnificationStyle
                _ = s.paddingScale
                _ = s.alwaysShowLabels
                _ = s.layoutStyle
                _ = s.appearanceMode
                _ = s.autoHide
            }
        } onChange: {
            DispatchQueue.main.async {
                let c = DockPanelController.shared
                // コントロールセンターから自動的に隠す・拡大を切り替えたときは開いたままにする
                let preview = PreviewController.shared
                if !(preview.isPinned && preview.state.mode == .control) { preview.hide(animated: false) }
                PreviewController.shared.updateAppearance()
                for dock in c.docks.values { dock.panel.appearance = dock.context.settings.appearanceMode.nsAppearance }
                DockModel.shared.invalidateIconsIfNeeded()
                c.syncScreens()
                c.observeSettings()
                c.scheduleHideAll()
                c.updateWidgetVisibility()
                WindowFitter.shared.refit()
            }
        }
    }

    // 常に表示している Dock が画面の端から占める幅。自動的に隠すときは nil
    func reservedInset(on screen: NSScreen) -> (DockPosition, CGFloat)? {
        guard let dock = docks[Self.screenID(screen)] else { return nil }
        let s = dock.context.settings
        guard !s.autoHide else { return nil }
        let m = DockMetrics(s)
        return (s.position, m.barThickness + m.edgeMargin + (s.layoutStyle == .taskbar ? 0 : 3))
    }

    func layout() {
        for dock in docks.values {
            let s = dock.context.settings
            let t = DockMetrics(s).thickness
            let f = dock.screen.frame
            let menuBar = f.maxY - dock.screen.visibleFrame.maxY
            let frame: CGRect = switch s.position {
            case .bottom: CGRect(x: f.minX, y: f.minY, width: f.width, height: t)
            case .left: CGRect(x: f.minX, y: f.minY, width: t, height: f.height - menuBar)
            case .right: CGRect(x: f.maxX - t, y: f.minY, width: t, height: f.height - menuBar)
            }
            dock.panel.setFrame(frame, display: true)
        }
        WindowFitter.shared.updateReservations()
        publishReservedAreas()
    }

    static let reservedAreasKey = "reservedAreas"
    static let reservedAreasNotification = Notification.Name("com.ryuto.GlassDock.reservedAreasChanged")

    private func publishReservedAreas() {
        var areas: [String: [String: Any]] = [:]
        for (id, dock) in docks {
            let s = dock.context.settings
            let inset = reservedInset(on: dock.screen)?.1 ?? 0
            areas[id] = ["edge": s.position.rawValue, "inset": Double(inset), "autoHide": s.autoHide]
        }
        let defaults = UserDefaults.standard
        if let old = defaults.dictionary(forKey: Self.reservedAreasKey), NSDictionary(dictionary: old).isEqual(to: areas) { return }
        defaults.set(areas, forKey: Self.reservedAreasKey)
        postReservedAreasChanged()
    }

    func unpublishReservedAreas() {
        UserDefaults.standard.removeObject(forKey: Self.reservedAreasKey)
        UserDefaults.standard.synchronize()
        postReservedAreasChanged()
    }

    private func postReservedAreasChanged() {
        DistributedNotificationCenter.default().postNotificationName(Self.reservedAreasNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

