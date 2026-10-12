import AppKit
import Observation
import SwiftUI

@Observable
final class DockModel {
    static let shared = DockModel()

    private(set) var items: [DockItem] = []
    private(set) var badges: [String: String] = [:]
    private(set) var launching: Set<String> = []
    private(set) var iconRevision = 0
    private(set) var minimizedPIDs: Set<pid_t> = []
    private(set) var windowCounts: [pid_t: Int] = [:]
    var hoveredID: String?
    // どのディスプレイの Dock でホバーしているか
    var hoveredContextID: String?
    var draggingID: String?

    private(set) var pinnedApps: [URL] = []
    private(set) var pinnedFolders: [URL] = []
    private(set) var leadingWidgets: [WidgetKind] = []
    private(set) var trailingWidgets: [WidgetKind] = []
    private(set) var customIcons: [String: String] = [:]
    // 新しく届いたダウンロード（見るまで印を付ける）
    private(set) var freshDownloads: [URL] = []

    @ObservationIgnored private var badgeTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private let settings = DockSettings.shared
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var cgIconCache: [String: CGImage] = [:]

    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private init() {
        loadPinned()
        observeWorkspace()
        rebuild()
        updateBadgeTimer()
        DownloadWatcher.shared.onChange = { DockModel.shared.downloadsChanged(added: $0, current: $1) }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { DockModel.shared.invalidateIcons() }
        }
    }

    // MARK: - Persistence

    // プリセットに含める、Dock の並びに関するキー
    static let persistedKeys = ["pinnedApps", "pinnedFolders", "leadingWidgets", "trailingWidgets", "customIcons"]

    private func loadPinned() {
        let d = UserDefaults.standard
        readPersisted()
        if !d.bool(forKey: "didImportSystemDock") {
            importFromSystemDock()
            d.set(true, forKey: "didImportSystemDock")
        }
        savePinned()
    }

    private func readPersisted() {
        let d = UserDefaults.standard
        pinnedApps = (d.stringArray(forKey: "pinnedApps") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { $0.standardizedFileURL != Self.finderURL && FileManager.default.fileExists(atPath: $0.path) }
        pinnedFolders = (d.stringArray(forKey: "pinnedFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if d.object(forKey: "trailingWidgets") == nil {
            trailingWidgets = [.weather, .calendar]
        } else {
            trailingWidgets = (d.stringArray(forKey: "trailingWidgets") ?? []).compactMap(WidgetKind.init(rawValue:))
        }
        leadingWidgets = (d.stringArray(forKey: "leadingWidgets") ?? []).compactMap(WidgetKind.init(rawValue:))
        customIcons = d.dictionary(forKey: "customIcons") as? [String: String] ?? [:]
    }

    // プリセットの復元後に UserDefaults から読み直す（書き戻さない）
    func reloadPersisted() {
        readPersisted()
        invalidateIcons()
        rebuild()
        updateBadgeTimer()
    }

    func importFromSystemDock() {
        pinnedApps = SystemDock.persistentAppURLs().filter { $0.standardizedFileURL != Self.finderURL }
        pinnedFolders = SystemDock.persistentOtherURLs()
        if pinnedFolders.isEmpty, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            pinnedFolders = [downloads]
        }
        savePinned()
        rebuild()
    }

    private func savePinned() {
        let d = UserDefaults.standard
        d.set(pinnedApps.map(\.path), forKey: "pinnedApps")
        d.set(pinnedFolders.map(\.path), forKey: "pinnedFolders")
        d.set(leadingWidgets.map(\.rawValue), forKey: "leadingWidgets")
        d.set(trailingWidgets.map(\.rawValue), forKey: "trailingWidgets")
        d.set(customIcons, forKey: "customIcons")
    }

    // MARK: - Items

    func rebuild() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var runningByKey: [String: NSRunningApplication] = [:]
        for app in running {
            if let id = app.bundleIdentifier { runningByKey[id] = app }
            if let url = app.bundleURL { runningByKey[url.standardizedFileURL.path] = app }
        }
        func runningApp(for url: URL) -> NSRunningApplication? {
            if let id = Bundle(url: url)?.bundleIdentifier, let app = runningByKey[id] { return app }
            return runningByKey[url.standardizedFileURL.path]
        }

        var result: [DockItem] = []
        if settings.showControlCenter {
            result.append(.control)
            result.append(.divider("control"))
        }
        if !leadingWidgets.isEmpty {
            result.append(contentsOf: leadingWidgets.map(DockItem.widget))
            result.append(.divider("leading"))
        }

        result.append(.app(url: Self.finderURL, pinned: true, running: runningApp(for: Self.finderURL)))
        var used = Set(result.compactMap { $0.runningApp?.processIdentifier })
        for url in pinnedApps {
            let app = runningApp(for: url)
            let item = DockItem.app(url: url, pinned: true, running: app)
            guard !result.contains(where: { $0.id == item.id }) else { continue }
            if let app { used.insert(app.processIdentifier) }
            result.append(item)
        }

        if settings.showRunningApps {
            let extras = running
                .filter { !used.contains($0.processIdentifier) && $0.bundleURL != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
                .map { DockItem.app(url: $0.bundleURL!, pinned: false, running: $0) }
            if !extras.isEmpty {
                result.append(.divider("running"))
                result.append(contentsOf: extras)
            }
        }

        // 非表示にしたフォルダとゴミ箱は Dock に並べない（固定は解除しない）
        let folders = pinnedFolders.filter { !settings.hiddenFolders.contains($0.path) }
        if !folders.isEmpty || settings.showTrash {
            result.append(.divider("others"))
            result.append(contentsOf: folders.map(DockItem.folder))
            if settings.showTrash { result.append(.trash) }
        }

        if !trailingWidgets.isEmpty {
            result.append(.divider("trailing"))
            result.append(contentsOf: trailingWidgets.map(DockItem.widget))
        }

        if result != items { items = result }
        DownloadWatcher.shared.setActive(folders.contains { $0.standardizedFileURL.path == DownloadWatcher.folder.standardizedFileURL.path })
        WidgetHub.shared.update(Set(leadingWidgets + trailingWidgets))
        // 初期化中に DockModel.shared を再入しないよう、次のループで同期する
        DispatchQueue.main.async { MinimizeTracker.shared.sync(running) }
    }

    // MARK: - Icons

    func invalidateIcons() {
        iconCache.removeAll()
        cgIconCache.removeAll()
        iconRevision += 1
    }

    // Dock では CGImage を使う。NSImage のままだと拡大中に大きさが変わるたびに CPU で描き直される
    func cgIcon(for item: DockItem) -> CGImage? {
        _ = iconRevision
        if item.kind != .trash, let cached = cgIconCache[item.id] { return cached }
        let image = icon(for: item)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        if let cg { cgIconCache[item.id] = cg }
        return cg
    }

    func iconKey(for item: DockItem) -> String {
        item.bundleID ?? item.url?.path ?? item.id
    }

    func icon(for item: DockItem) -> NSImage {
        _ = iconRevision
        let key = item.id
        if item.kind != .trash, let cached = iconCache[key] { return cached }
        let raw: NSImage
        if let path = customIcons[iconKey(for: item)], let custom = NSImage(contentsOfFile: path) {
            raw = custom
        } else {
            switch item.kind {
            case .app(let url):
                // /Applications/Safari.app のようなリンクは、そのままだとエイリアスの矢印付きになるため実体を使う
                raw = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
            case .folder(let url):
                raw = NSWorkspace.shared.icon(forFile: url.path)
            case .trash:
                let empty = (try? FileManager.default.contentsOfDirectory(atPath: item.url?.path ?? "").isEmpty) ?? true
                raw = NSImage(named: empty ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage()
            case .divider, .widget, .control:
                raw = NSImage()
            }
        }
        let image = render(raw)
        iconCache[key] = image
        return image
    }

    // アイコンは描画時の外観で見た目が変わるため、ダーク／ライトを確定させてビットマップ化する
    private func render(_ image: NSImage) -> NSImage {
        // ディスプレイごとに大きさが違うことがあるため、一番大きい設定に合わせて描く
        let largest = DockSettings.allInstances.map(\.maxIconSize).max() ?? settings.maxIconSize
        let points = CGFloat(min(max(largest, 64), 256))
        let px = Int(points * 2)
        let appearance = settings.appearanceMode.nsAppearance ?? NSApp.effectiveAppearance
        var output = image
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = NSSize(width: points, height: points)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let result = NSImage(size: rep.size)
            result.addRepresentation(rep)
            output = result
        }
        return output
    }

    private var iconDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassDock/Icons", isDirectory: true)
    }

    // 設定ファイルが書き換えられても、アイコン用フォルダの外は消さない
    private func removeIconFile(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let dir = iconDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(dir) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func setCustomIcon(_ url: URL?, for item: DockItem) {
        let key = iconKey(for: item)
        if let url {
            let dir = iconDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
            if let old = customIcons[key] { removeIconFile(old) }
            customIcons[key] = dest.path
        } else if let old = customIcons.removeValue(forKey: key) {
            removeIconFile(old)
        }
        savePinned()
        invalidateIcons()
    }

    func chooseCustomIcon(for item: DockItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns]
        panel.message = loc("%@ のアイコンにする画像を選んでください", item.name)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { setCustomIcon(url, for: item) }
    }

    func freshDownloadCount(for item: DockItem) -> Int {
        guard case .folder(let url) = item.kind, url.standardizedFileURL.path == DownloadWatcher.folder.standardizedFileURL.path else { return 0 }
        return freshDownloads.count
    }

    func clearFreshDownloads(_ item: DockItem) {
        if freshDownloadCount(for: item) > 0 { freshDownloads = [] }
    }

    private func downloadsChanged(added urls: [URL], current: Set<String>) {
        // 届いたあとに消したり移動したりしたものは数えない
        let remaining = freshDownloads.filter { current.contains($0.lastPathComponent) }
        if remaining.count != freshDownloads.count { withAnimation(.smooth) { freshDownloads = remaining } }
        guard !urls.isEmpty else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { freshDownloads = Array((urls + freshDownloads).prefix(20)) }
        // 隠れている Dock も、しばらく出して知らせる
        for context in DockPanelController.shared.contexts where context.settings.autoHide {
            context.visibility.revealTemporarily(for: 4)
        }
    }

    func badge(for item: DockItem) -> String? {
        guard settings.showBadges, let url = item.url else { return nil }
        return badges[url.standardizedFileURL.path]
    }

    // MARK: - Actions

    func activate(_ item: DockItem) {
        switch item.kind {
        case .app(let url):
            if let app = item.runningApp, app.isActive, !app.isHidden {
                switch settings.activeClickAction {
                case .minimize:
                    // 前面のアプリを押したら全ウィンドウを最小化し、すべて最小化済みなら元に戻す
                    if WindowService.shared.minimizeAll(pid: app.processIdentifier) { return }
                    if WindowService.shared.restoreAll(pid: app.processIdentifier) { return }
                case .hide:
                    app.hide()
                    return
                case .none:
                    break
                }
            }
            if item.runningApp == nil, settings.launchBounce {
                launching.insert(item.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.launching.remove(item.id) }
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        case .folder(let url):
            NSWorkspace.shared.open(url)
        case .trash:
            if let url = item.url { NSWorkspace.shared.open(url) }
        case .widget(let kind):
            WidgetHub.shared.primaryAction(kind)
        case .control:
            PreviewController.shared.toggleControl(item)
        case .divider:
            break
        }
    }

    func setMinimized(_ pid: pid_t, _ on: Bool) {
        if on, !minimizedPIDs.contains(pid) { minimizedPIDs.insert(pid) }
        else if !on, minimizedPIDs.contains(pid) { minimizedPIDs.remove(pid) }
    }

    func setWindowCount(_ pid: pid_t, _ count: Int) {
        if windowCounts[pid] != count { windowCounts[pid] = count }
    }

    func windowCount(_ item: DockItem) -> Int {
        guard let pid = item.runningApp?.processIdentifier else { return 0 }
        return windowCounts[pid] ?? 0
    }

    func isMinimized(_ item: DockItem) -> Bool {
        guard let pid = item.runningApp?.processIdentifier else { return false }
        return minimizedPIDs.contains(pid)
    }

    func open(_ urls: [URL], with item: DockItem) -> Bool {
        switch item.kind {
        case .app(let app):
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .trash:
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            iconCache["trash"] = nil
            iconRevision += 1
            return true
        case .folder(let folder):
            // Finder と同じく、同じボリューム内なら移動、別のボリュームからはコピーにする（元ファイルを消さない）
            func volume(_ u: URL) -> NSObject? {
                (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            }
            let destVolume = volume(folder)
            for url in urls {
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                if let v = volume(url), let d = destVolume, v.isEqual(d) {
                    try? FileManager.default.moveItem(at: url, to: dest)
                } else {
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
            }
            return true
        case .divider, .widget, .control:
            return false
        }
    }

    func addToDock(_ urls: [URL]) {
        for url in urls {
            if url.pathExtension == "app" {
                pin(url)
            } else if url.hasDirectoryPath, !pinnedFolders.contains(url) {
                pinnedFolders.append(url)
            }
        }
        savePinned()
        rebuild()
    }

    func pin(_ url: URL) {
        guard url.standardizedFileURL != Self.finderURL, !pinnedApps.contains(url) else { return }
        pinnedApps.append(url)
        savePinned()
        rebuild()
    }

    func remove(_ item: DockItem) {
        switch item.kind {
        case .app(let url):
            pinnedApps.removeAll { $0 == url || Bundle(url: $0)?.bundleIdentifier == item.bundleID }
        case .folder(let url):
            pinnedFolders.removeAll { $0 == url }
        case .widget(let kind):
            leadingWidgets.removeAll { $0 == kind }
            trailingWidgets.removeAll { $0 == kind }
        default:
            return
        }
        savePinned()
        rebuild()
    }

    // MARK: - Widgets

    func hasWidget(_ kind: WidgetKind) -> Bool { leadingWidgets.contains(kind) || trailingWidgets.contains(kind) }

    func addWidget(_ kind: WidgetKind, leading: Bool = false) {
        guard !hasWidget(kind) else { return }
        if leading { leadingWidgets.append(kind) } else { trailingWidgets.append(kind) }
        savePinned()
        rebuild()
    }

    func setWidget(_ kind: WidgetKind, leading: Bool) {
        leadingWidgets.removeAll { $0 == kind }
        trailingWidgets.removeAll { $0 == kind }
        if leading { leadingWidgets.append(kind) } else { trailingWidgets.append(kind) }
        savePinned()
        rebuild()
    }

    func moveWidgets(leading: Bool, from source: IndexSet, to destination: Int) {
        if leading { leadingWidgets.move(fromOffsets: source, toOffset: destination) }
        else { trailingWidgets.move(fromOffsets: source, toOffset: destination) }
        savePinned()
        rebuild()
    }

    func canReorder(_ item: DockItem) -> Bool {
        switch item.kind {
        case .app(let url): item.isPinned && url != Self.finderURL
        case .folder, .widget: true
        default: false
        }
    }

    // ドラッグ中に隣のアイテムと入れ替える。direction は -1 か +1
    @discardableResult
    func move(_ item: DockItem, by direction: Int) -> Bool {
        func swap<T: Equatable>(_ list: inout [T], _ value: T) -> Bool {
            guard let i = list.firstIndex(of: value), list.indices.contains(i + direction) else { return false }
            list.swapAt(i, i + direction)
            return true
        }
        let moved: Bool
        switch item.kind {
        case .app(let url): moved = swap(&pinnedApps, url)
        case .folder(let url): moved = swap(&pinnedFolders, url)
        case .widget(let kind): moved = swap(&leadingWidgets, kind) || swap(&trailingWidgets, kind)
        default: moved = false
        }
        guard moved else { return false }
        savePinned()
        rebuild()
        return true
    }

    func movePinnedApps(from source: IndexSet, to destination: Int) {
        pinnedApps.move(fromOffsets: source, toOffset: destination)
        savePinned()
        rebuild()
    }

    func movePinnedFolders(from source: IndexSet, to destination: Int) {
        pinnedFolders.move(fromOffsets: source, toOffset: destination)
        savePinned()
        rebuild()
    }

    // MARK: - Observation

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.handle(name, app: app) }
            })
        }
    }

    private func handle(_ name: Notification.Name, app: NSRunningApplication?) {
        if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didActivateApplicationNotification,
           let app {
            launching = launching.filter { id in
                !(id == "app:" + (app.bundleIdentifier ?? "") || id == "app:" + (app.bundleURL?.path ?? ""))
            }
        }
        if name == NSWorkspace.didTerminateApplicationNotification, let app {
            WindowService.shared.purge(pid: app.processIdentifier)
        }
        if let app, name != NSWorkspace.didTerminateApplicationNotification {
            MinimizeTracker.shared.refresh(app.processIdentifier)
        }
        rebuild()
    }

    func updateBadgeTimer() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        guard settings.showBadges else {
            badges = [:]
            return
        }
        refreshBadges()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        badgeTimer = timer
    }

    private func refreshBadges() {
        let new = SystemDock.badges()
        if new != badges { badges = new }
    }
}
