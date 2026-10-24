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
    // 隠しているアプリ。表示し直した通知の時点ではアプリの isHidden がまだ古いことがあるため、通知の内容で直接更新する
    private(set) var hiddenPIDs: Set<pid_t> = []
    // 普段は Dock に出るアプリが、ウィンドウを閉じるなどしてバックグラウンドで動いているもの
    private(set) var backgroundPIDs: Set<pid_t> = []
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
    @ObservationIgnored private var badgeLoading = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var policyObservers: [pid_t: NSKeyValueObservation] = [:]
    @ObservationIgnored private var dockAppCache: [String: Bool] = [:]
    // 本体が終了したあとも、起動したプロセスが残っているアプリ（バンドルのパス → プロセス）
    @ObservationIgnored private var lingering: [String: [pid_t]] = [:]
    @ObservationIgnored private var lingeringScan: (running: Bool, again: Bool) = (false, false)
    @ObservationIgnored private var lingeringTimer: Timer?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private let settings = DockSettings.shared
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var cgIconCache: [String: CGImage] = [:]
    @ObservationIgnored private var renderedFor = ""

    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private init() {
        loadPinned()
        hiddenPIDs = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))
        observeWorkspace()
        rebuild()
        scanLingering()
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
        commit()
    }

    private func commit() {
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
        let candidates = NSWorkspace.shared.runningApplications.filter(isDockApp)
        observePolicies(candidates)
        let running = candidates.filter { $0.activationPolicy == .regular || $0.isFinishedLaunching }
        let background = Set(running.filter { $0.activationPolicy != .regular }.map(\.processIdentifier))
        if background != backgroundPIDs { backgroundPIDs = background }
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
        func lingeringPIDs(for url: URL) -> [pid_t] {
            lingering[url.standardizedFileURL.path] ?? []
        }
        for url in pinnedApps {
            let app = runningApp(for: url)
            var item = DockItem.app(url: url, pinned: true, running: app)
            if app == nil { item.lingeringPIDs = lingeringPIDs(for: url) }
            guard !result.contains(where: { $0.id == item.id }) else { continue }
            if let app { used.insert(app.processIdentifier) }
            result.append(item)
        }

        if settings.showRunningApps {
            let apps = running
                .filter { !used.contains($0.processIdentifier) && $0.bundleURL != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
                .map { DockItem.app(url: $0.bundleURL!, pinned: false, running: $0) }
            let shown = Set((result + apps).compactMap { $0.url?.standardizedFileURL.path })
            let leftovers = lingering.keys.sorted().filter { !shown.contains($0) && runningByKey[$0] == nil }.map { path in
                var item = DockItem.app(url: URL(fileURLWithPath: path), pinned: false)
                item.lingeringPIDs = lingering[path] ?? []
                return item
            }
            let extras = apps + leftovers
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
        IconColor.reset()
        renderedFor = renderSignature
        iconRevision += 1
    }

    // 描く大きさか外観が変わったときだけ描き直す（大きさのスライダーを動かすたびに全アイコンを描き直さない）
    func invalidateIconsIfNeeded() {
        if renderSignature != renderedFor { invalidateIcons() }
    }

    // ディスプレイごとに大きさが違うことがあるため、一番大きい設定に合わせて描く
    private var renderPoints: CGFloat {
        let largest = DockSettings.allInstances.map(\.maxIconSize).max() ?? settings.maxIconSize
        return CGFloat(min(max(largest, 64), 256))
    }

    private var renderAppearance: NSAppearance { settings.appearanceMode.nsAppearance ?? NSApp.effectiveAppearance }

    private var renderSignature: String { "\(renderPoints)|\(renderAppearance.name.rawValue)" }

    // ゴミ箱は中身の有無で絵が変わるため、状態ごとに覚えておく（拡大中に毎回描き直さない）
    private func cacheKey(for item: DockItem) -> String {
        guard item.kind == .trash else { return item.id }
        return Self.isTrashEmpty(item.url) ? "trash.empty" : "trash.full"
    }

    private static func isTrashEmpty(_ url: URL?) -> Bool {
        guard let url else { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !names.contains { !$0.hasPrefix(".") }
    }

    // Dock では CGImage を使う。NSImage のままだと拡大中に大きさが変わるたびに CPU で描き直される
    func cgIcon(for item: DockItem) -> CGImage? {
        _ = iconRevision
        let key = cacheKey(for: item)
        if let cached = cgIconCache[key] { return cached }
        let image = icon(for: item, key: key)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        if let cg { cgIconCache[key] = cg }
        return cg
    }

    func iconKey(for item: DockItem) -> String {
        item.bundleID ?? item.url?.path ?? item.id
    }

    func icon(for item: DockItem) -> NSImage {
        icon(for: item, key: cacheKey(for: item))
    }

    private func icon(for item: DockItem, key: String) -> NSImage {
        _ = iconRevision
        if let cached = iconCache[key] { return cached }
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
                raw = NSImage(named: key == "trash.empty" ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage()
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
        let points = renderPoints
        let px = Int(points * 2)
        var output = image
        renderAppearance.performAsCurrentDrawingAppearance {
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
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { freshDownloads = urls + freshDownloads }
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
            FileViewer.open(url)
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

    func isBackground(_ item: DockItem) -> Bool {
        if item.isLingering { return true }
        guard let pid = item.runningApp?.processIdentifier else { return false }
        return backgroundPIDs.contains(pid)
    }

    func forceQuitLingering(_ item: DockItem) {
        LingeringApps.forceQuit(item.lingeringPIDs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scanLingering() }
    }

    // lsappinfo を呼ぶのでメインスレッドの外で調べる。残っているあいだだけ、なくなったかを時々確かめる
    func scanLingering() {
        guard !lingeringScan.running else {
            lingeringScan.again = true
            return
        }
        lingeringScan = (true, false)
        Task {
            let found = await Task.detached(priority: .utility) { LingeringApps.scan() }.value
            let again = lingeringScan.again
            lingeringScan = (false, false)
            if found != lingering {
                lingering = found
                rebuild()
            }
            if found.isEmpty {
                lingeringTimer?.invalidate()
                lingeringTimer = nil
            } else if lingeringTimer == nil {
                let timer = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { DockModel.shared.scanLingering() } }
                timer.tolerance = 2
                RunLoop.main.add(timer, forMode: .common)
                lingeringTimer = timer
            }
            if again { scanLingering() }
        }
    }

    // 普通のアプリに加え、Info.plist ではメニューバー常駐（LSUIElement）や背景専用でないのに、
    // 今はバックグラウンドで動いているアプリも Dock に出す（標準 Dock と同じ）
    private func isDockApp(_ app: NSRunningApplication) -> Bool {
        if app.activationPolicy == .regular { return true }
        guard let url = app.bundleURL, url.pathExtension == "app",
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let path = url.standardizedFileURL.path
        if let cached = dockAppCache[path] { return cached }
        let roots = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        var result = false
        if roots.contains(where: path.hasPrefix), !path.dropLast(4).contains(".app/"),
           let info = Bundle(url: url)?.infoDictionary {
            func flag(_ key: String) -> Bool {
                (info[key] as? Bool) ?? (info[key] as? NSNumber)?.boolValue ?? ((info[key] as? String).map { $0 == "1" || $0.lowercased() == "yes" || $0.lowercased() == "true" } ?? false)
            }
            result = !flag("LSUIElement") && !flag("LSBackgroundOnly")
        }
        dockAppCache[path] = result
        return result
    }

    // 動いている途中で前面に出る・バックグラウンドに回る切り替えは通知が来ないので、KVO で見る
    private func observePolicies(_ apps: [NSRunningApplication]) {
        let pids = Set(apps.map(\.processIdentifier))
        for pid in policyObservers.keys where !pids.contains(pid) { policyObservers[pid] = nil }
        for app in apps where policyObservers[app.processIdentifier] == nil {
            policyObservers[app.processIdentifier] = app.observe(\.activationPolicy) { [weak self] _, _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
        }
    }

    func isHidden(_ item: DockItem) -> Bool {
        guard let pid = item.runningApp?.processIdentifier else { return false }
        return hiddenPIDs.contains(pid)
    }

    func isMinimized(_ item: DockItem) -> Bool {
        guard let pid = item.runningApp?.processIdentifier else { return false }
        return minimizedPIDs.contains(pid)
    }

    func open(_ urls: [URL], with item: DockItem) -> Bool {
        // ドロップで届くのはファイルだけにする（Web の URL などは受け付けない）
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        switch item.kind {
        case .app(let app):
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .trash:
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            // 中身の有無を確かめ直して描き直す
            iconRevision += 1
            return true
        case .folder(let folder):
            // Finder と同じく、同じボリューム内なら移動、別のボリュームからはコピーにする（元ファイルを消さない）
            func volume(_ u: URL) -> NSObject? {
                // シンボリックリンクは、リンクの置き場所ではなく実体のボリュームで比べる
                (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
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
        for url in urls where url.isFileURL {
            if url.pathExtension == "app" {
                pin(url)
            } else if url.hasDirectoryPath, !pinnedFolders.contains(url) {
                pinnedFolders.append(url)
            }
        }
        commit()
    }

    func pin(_ url: URL) {
        guard url.standardizedFileURL != Self.finderURL, !pinnedApps.contains(url) else { return }
        pinnedApps.append(url)
        commit()
    }

    func remove(_ item: DockItem) {
        switch item.kind {
        case .app(let url):
            pinnedApps.removeAll { $0 == url || (item.bundleID != nil && Bundle(url: $0)?.bundleIdentifier == item.bundleID) }
        case .folder(let url):
            pinnedFolders.removeAll { $0 == url }
        case .widget(let kind):
            leadingWidgets.removeAll { $0 == kind }
            trailingWidgets.removeAll { $0 == kind }
        default:
            return
        }
        commit()
    }

    // MARK: - Widgets

    func hasWidget(_ kind: WidgetKind) -> Bool { leadingWidgets.contains(kind) || trailingWidgets.contains(kind) }

    func addWidget(_ kind: WidgetKind, leading: Bool = false) {
        guard !hasWidget(kind) else { return }
        if leading { leadingWidgets.append(kind) } else { trailingWidgets.append(kind) }
        commit()
    }

    func setWidget(_ kind: WidgetKind, leading: Bool) {
        leadingWidgets.removeAll { $0 == kind }
        trailingWidgets.removeAll { $0 == kind }
        if leading { leadingWidgets.append(kind) } else { trailingWidgets.append(kind) }
        commit()
    }

    func moveWidgets(leading: Bool, from source: IndexSet, to destination: Int) {
        if leading { leadingWidgets.move(fromOffsets: source, toOffset: destination) }
        else { trailingWidgets.move(fromOffsets: source, toOffset: destination) }
        commit()
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
        commit()
        return true
    }

    func movePinnedApps(from source: IndexSet, to destination: Int) {
        pinnedApps.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    func movePinnedFolders(from source: IndexSet, to destination: Int) {
        pinnedFolders.move(fromOffsets: source, toOffset: destination)
        commit()
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
            // 変わらないときに代入すると、全アイコンが描き直される
            let remaining = launching.filter { id in
                !(id == "app:" + (app.bundleIdentifier ?? "") || id == "app:" + (app.bundleURL?.path ?? ""))
            }
            if remaining != launching { launching = remaining }
        }
        if name == NSWorkspace.didTerminateApplicationNotification, let app {
            WindowService.shared.purge(pid: app.processIdentifier)
            // 終了の直後は LaunchServices の状態がまだ変わっていないことがある
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scanLingering() }
        }
        if name == NSWorkspace.didLaunchApplicationNotification, !lingering.isEmpty { scanLingering() }
        if let pid = app?.processIdentifier {
            switch name {
            case NSWorkspace.didHideApplicationNotification: hiddenPIDs.insert(pid)
            case NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification: hiddenPIDs.remove(pid)
            default: break
            }
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

    // 標準 Dock の AX ツリーを読むと時間がかかることがあるため、メインスレッドの外で読む
    private func refreshBadges() {
        guard !badgeLoading else { return }
        badgeLoading = true
        Task.detached(priority: .utility) {
            let new = SystemDock.badges()
            await MainActor.run {
                let model = DockModel.shared
                model.badgeLoading = false
                if model.settings.showBadges, new != model.badges { model.badges = new }
            }
        }
    }
}
