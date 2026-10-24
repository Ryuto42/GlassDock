import AppKit
import SwiftUI

enum PreviewPhase {
    case hidden, seed, open
}

// hover: ホバーで出て離れると消える / menu・control: クリックで開き、外側のクリックか Esc で閉じる
enum PreviewMode {
    case hover, menu, control
}

@Observable
final class PreviewState {
    var item: DockItem?
    var windows: [WindowInfo] = []
    var phase: PreviewPhase = .hidden
    var anchor: CGPoint = .zero
    var seedLength: CGFloat = 40
    var contentSize: CGSize = .zero
    var contentFrame: CGRect = .zero
    var hovering = false
    var mode: PreviewMode = .hover
    var dockSettings: DockSettings = .shared
    var dockMenu: [String] = []
    var folderEntries: [FolderEntry] = []
    var folderTotal = 0

    var contentKey: String { "\(mode)-\(item?.id ?? "")" }
}

@MainActor
final class PreviewController {
    static let shared = PreviewController()

    let state = PreviewState()
    var iconFrames: [String: CGRect] = [:]
    // いまホバーやクリックの対象になっているディスプレイの Dock
    weak var activeContext: DockContext? {
        didSet { if state.dockSettings !== dockSettings { state.dockSettings = dockSettings } }
    }
    private var dockPanel: NSWindow? { activeContext?.window }

    private var panel: OverlayPanel?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var monitors: [Any] = []
    private var watchTimer: Timer?
    // プレビューの中身に関する設定は共通、位置やアニメーションはホバーした Dock の設定に従う
    private let settings = DockSettings.shared
    private var dockSettings: DockSettings { activeContext?.settings ?? .shared }
    let menuSearch = MenuSearch()
    let session = PanelSession()

    var isVisible: Bool { state.phase != .hidden }
    var isPinned: Bool { state.mode != .hover && state.phase != .hidden }

    init() {
        installClickMonitor()
    }

    // MARK: - Menu / Control center

    func showMenu(for item: DockItem) {
        showWork?.cancel()
        hideWork?.cancel()
        menuSearch.reset()
        state.dockMenu = []
        show(item, immediate: true, mode: .menu)
        // 標準 Dock の右クリックメニューにあるアプリ独自の項目を取り込む
        guard case .app(let url) = item.kind, let pid = item.runningApp?.processIdentifier else { return }
        Task {
            let windowTitles = await Task.detached(priority: .userInitiated) {
                Set(WindowService.axSnapshot(pid: pid).values.compactMap(\.title))
            }.value
            let titles = await AppActions.dockMenuTitles(for: url, excluding: windowTitles)
            guard self.state.mode == .menu, self.state.item?.id == item.id, !titles.isEmpty else { return }
            withAnimation(self.dockSettings.spring(0.34, damping: 0.85)) { self.state.dockMenu = titles }
        }
    }

    func toggleControl(_ item: DockItem) {
        if isPinned, state.mode == .control {
            hide(animated: true)
        } else {
            show(item, immediate: true, mode: .control)
        }
    }

    // 右クリック・外側のクリック・Esc をまとめて扱う
    // 自分のウィンドウ宛てのイベントだけを見るローカルモニタは常に置く
    private func installClickMonitor() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            nonisolated(unsafe) let e = event
            let keep = MainActor.assumeIsolated { PreviewController.shared.handleLocal(e) != nil }
            return keep ? event : nil
        }) { monitors.append(local) }
    }

    // 他のアプリへのクリックや Esc を見るグローバルモニタは、メニューなどを開いている間だけ置く
    private var globalMonitor: Any?

    private func updateGlobalMonitor() {
        if isPinned, globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
                nonisolated(unsafe) let e = event
                MainActor.assumeIsolated { PreviewController.shared.handleGlobal(e) }
            }
        } else if !isPinned, let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            if event.keyCode == 53, isPinned {
                hide(animated: true)
                return nil
            }
            return event
        }
        let isRight = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        if let panel, event.window === panel {
            let p = event.locationInWindow
            let local = CGPoint(x: p.x, y: panel.frame.height - p.y)
            if isPinned, !state.contentFrame.insetBy(dx: -4, dy: -4).contains(local) { hide(animated: true) }
            return event
        }
        if let ctx = DockPanelController.shared.context(for: event.window) {
            if !isPinned { activeContext = ctx }
            let model = DockModel.shared
            let hovered = model.hoveredID.flatMap { id in model.items.first { $0.id == id } }
            if isRight, let item = hovered {
                if isPinned { finishHide() }
                showMenu(for: item)
                return nil
            }
            if isPinned, !(state.mode == .control && hovered?.kind == .control) { hide(animated: true) }
            return event
        }
        if isPinned, event.type != .keyDown { hide(animated: true) }
        return event
    }

    private func handleGlobal(_ event: NSEvent) {
        guard isPinned else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 { hide(animated: true) }
            return
        }
        hide(animated: true)
    }

    // MARK: - Hover

    func hoverBegan(_ item: DockItem, in context: DockContext) {
        guard DockModel.shared.draggingID == nil, !isPinned else { return }
        if activeContext !== context, state.phase != .hidden { hide(animated: false) }
        activeContext = context
        hideWork?.cancel()
        showWork?.cancel()
        if state.phase == .open {
            show(item, immediate: true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.show(item, immediate: false) }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.previewDelay, execute: work)
        }
    }

    func hoverEnded(_ item: DockItem) {
        showWork?.cancel()
        guard !isPinned else { return }
        scheduleHide()
    }

    func previewHover(_ inside: Bool) {
        state.hovering = inside
        guard !isPinned else { return }
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.hovering, DockModel.shared.hoveredID == nil else { return }
            self.hide(animated: true)
            activeContext?.visibility.scheduleHide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Show / Hide

    func show(_ item: DockItem, immediate: Bool, mode: PreviewMode = .hover) {
        guard let screen = dockPanel?.screen ?? NSScreen.screens.first else { return }
        let panel = ensurePanel()
        let frame = panelFrame(on: screen)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }

        let current = DockModel.shared.items.first { $0.id == item.id } ?? item
        let changed = state.item?.id != current.id || state.mode != mode
        let anchor = anchorPoint(for: current, panel: panel)
        let isMusic = NowPlayingService.playerName(for: current.bundleID) != nil
        // カレンダーを開き直したら今日に戻す
        if changed, current.widgetKind == .calendar { WidgetHub.shared.calendar.resetSelection() }
        // フォルダは中身を先に読み込み、開いたあとに大きさが変わらないようにする
        if mode == .hover, case .folder(let url) = current.kind, changed {
            let loaded = FolderEntry.load(url)
            state.folderEntries = loaded.entries
            state.folderTotal = loaded.total
        }
        let needsWindows = current.widgetKind == nil && current.isRunning && (settings.previewEnabled || mode == .menu)
        if mode == .hover && isMusic && current.isRunning { WidgetHub.shared.media.startProgress() } else { WidgetHub.shared.media.stopProgress() }
        generation += 1
        let gen = generation

        if state.phase == .open {
            guard changed else {
                withAnimation(dockSettings.spring(0.34, damping: 0.82)) { state.anchor = anchor }
                return
            }
            // 別のアイコンへ移ったときは、新しい中身が揃うまで今の表示を残し、一度にまとめて切り替える
            if needsWindows {
                reload(for: current) { [weak self] windows in
                    guard let self, gen == self.generation else { return }
                    // 一覧が遅れて届き、待ちきれずに先に切り替えていたときは一覧だけ反映する（届いた一覧を捨てないように）
                    if self.state.item?.id == current.id, self.state.mode == mode {
                        self.apply(windows)
                    } else {
                        self.swap(to: current, mode: mode, anchor: anchor, windows: windows, gen)
                    }
                }
                startRefresh()
                let work = DispatchWorkItem { [weak self] in self?.swap(to: current, mode: mode, anchor: anchor, windows: [], gen) }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            } else {
                loadTask?.cancel()
                stopRefresh()
                whenThumbnailsReady(current, mode: mode, gen) { [weak self] in self?.swap(to: current, mode: mode, anchor: anchor, windows: [], gen) }
            }
            return
        }

        openWork?.cancel()
        if changed { session.reset() }
        state.anchor = anchor
        state.item = current
        state.mode = mode
        state.windows = []
        if needsWindows {
            reload(for: current) { [weak self] windows in
                guard let self, gen == self.generation else { return }
                self.state.windows = windows
                self.open(gen)
            }
            startRefresh()
            // ウィンドウ一覧の取得が遅いときも待ちすぎない
            let work = DispatchWorkItem { [weak self] in self?.open(gen) }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            loadTask?.cancel()
            stopRefresh()
            whenThumbnailsReady(current, mode: mode, gen) { [weak self] in self?.open(gen) }
        }
    }

    // フォルダはサムネイルを先に用意してから開き、開く途中でアイコンが差し替わらないようにする
    private func whenThumbnailsReady(_ item: DockItem, mode: PreviewMode, _ gen: Int, _ action: @escaping () -> Void) {
        guard mode == .hover, case .folder = item.kind, !state.folderEntries.isEmpty else {
            action()
            return
        }
        var done = false
        let finish = { [weak self] in
            guard !done, let self, gen == self.generation else { return }
            done = true
            action()
        }
        let entries = state.folderEntries
        Task {
            await withTaskGroup(of: Void.self) { group in
                for e in entries {
                    group.addTask { @MainActor in _ = await ThumbnailCache.shared.load(e.url, size: 104) }
                }
            }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    }

    private func swap(to item: DockItem, mode: PreviewMode, anchor: CGPoint, windows: [WindowInfo], _ gen: Int) {
        guard gen == generation, state.phase == .open, state.item?.id != item.id || state.mode != mode else { return }
        openWork?.cancel()
        defer { updateGlobalMonitor() }
        session.reset()
        withAnimation(dockSettings.spring(0.38, damping: 0.84)) {
            state.anchor = anchor
            state.item = item
            state.mode = mode
            state.windows = windows
        }
    }

    // 透明部分ではホバー終了が届かないことがあるため、表示中だけカーソル位置を確かめて取り残しを防ぐ
    private func startWatching() {
        guard watchTimer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { PreviewController.shared.checkPointer() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func checkPointer() {
        // 閉じる途中（しずくの段階）に hide を呼び直すと閉じきらなくなるため、開いているときだけ確かめる
        guard state.phase == .open, !isPinned, let panel else { return }
        let p = NSEvent.mouseLocation
        let inPanel = state.contentFrame.insetBy(dx: -6, dy: -6)
            .contains(CGPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y))
        var inDock = false
        if let dock = dockPanel {
            inDock = (activeContext?.watcher.barRect ?? .zero).insetBy(dx: -2, dy: -2)
                .contains(CGPoint(x: p.x - dock.frame.minX, y: dock.frame.maxY - p.y))
        }
        if state.hovering != inPanel { state.hovering = inPanel }
        if !inDock, DockModel.shared.hoveredID != nil { DockModel.shared.hoveredID = nil }
        if !inPanel && !inDock {
            hide(animated: true)
            activeContext?.visibility.scheduleHide()
        }
    }

    // アイコンの上に小さなしずくを置き、次のフレームでパネルの形へ変形させる
    private func open(_ gen: Int) {
        guard gen == generation, state.item != nil else { return }
        openWork?.cancel()
        startWatching()
        updateGlobalMonitor()
        switch state.phase {
        case .open:
            return
        case .hidden:
            state.phase = .seed
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation, self.state.phase == .seed else { return }
                withAnimation(self.dockSettings.spring(0.46, damping: 0.7)) { self.state.phase = .open }
            }
        case .seed:
            withAnimation(dockSettings.spring(0.46, damping: 0.7)) { state.phase = .open }
        }
    }

    func hide(animated: Bool) {
        showWork?.cancel()
        hideWork?.cancel()
        openWork?.cancel()
        loadTask?.cancel()
        stopRefresh()
        generation += 1
        let gen = generation
        state.hovering = false
        guard state.phase != .hidden else {
            // 開く前（ウィンドウ一覧の取得待ちなど）に離れたときも、再生位置の更新や前面に出したパネルを残さない
            if state.item != nil { finishHide() }
            return
        }
        guard animated else {
            finishHide()
            return
        }
        // 開くときと同じく、ガラスと中身を一緒にしずくへ戻してから消す
        withAnimation(dockSettings.spring(0.28, damping: 0.88)) { state.phase = .seed }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 / dockSettings.animationSpeed) { [weak self] in
            guard let self, gen == self.generation else { return }
            withAnimation(.easeOut(duration: 0.1)) { self.state.phase = .hidden }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard gen == self.generation else { return }
                self.finishHide()
            }
        }
    }

    private func finishHide() {
        stopWatching()
        defer { updateGlobalMonitor() }
        WidgetHub.shared.media.stopProgress()
        state.mode = .hover
        state.phase = .hidden
        state.item = nil
        state.windows = []
        session.reset()
        panel?.orderOut(nil)
        activeContext?.visibility.scheduleHide()
    }

    // プレビュー用の透明なパネルが Dock に重なると、Dock 上のマウスの動きを横取りしてホバーが止まるため、
    // Dock の部分を除いた範囲に置く
    private func panelFrame(on screen: NSScreen) -> CGRect {
        let f = screen.frame
        let t = DockMetrics(dockSettings).thickness - 4
        return switch dockSettings.position {
        case .bottom: CGRect(x: f.minX, y: f.minY + t, width: f.width, height: f.height - t)
        case .left: CGRect(x: f.minX + t, y: f.minY, width: f.width - t, height: f.height)
        case .right: CGRect(x: f.minX, y: f.minY, width: f.width - t, height: f.height)
        }
    }

    private func anchorPoint(for item: DockItem, panel: NSWindow) -> CGPoint {
        guard let dock = dockPanel, let ctx = activeContext, let f = iconFrames[ctx.key(item.id)] else { return state.anchor }
        let screenRect = CGRect(x: dock.frame.minX + f.minX, y: dock.frame.maxY - f.maxY, width: f.width, height: f.height)
        let local = CGPoint(x: screenRect.midX - panel.frame.minX, y: panel.frame.maxY - screenRect.midY)
        // パネルは Dock の手前（thickness - 4）から始まるので、パネルの縁から 8pt 離して置く
        let gap: CGFloat = 8
        state.seedLength = max(24, min(f.width, f.height) * 0.8)
        return switch dockSettings.position {
        case .bottom: CGPoint(x: local.x, y: panel.frame.height - gap)
        case .left: CGPoint(x: gap, y: local.y)
        case .right: CGPoint(x: panel.frame.width - gap, y: local.y)
        }
    }

    // MARK: - Loading

    func reload(for target: DockItem? = nil, completion: (([WindowInfo]) -> Void)? = nil) {
        guard let item = target ?? state.item, let pid = item.runningApp?.processIdentifier else { return }
        loadTask?.cancel()
        let maxSide = CGFloat(settings.previewSize)
        loadTask = Task { [weak self] in
            let service = WindowService.shared
            let windows = await service.windows(pid: pid)
            guard let self, !Task.isCancelled else { return }
            if let completion {
                completion(windows)
            } else if self.state.item?.id == item.id {
                self.apply(windows)
            }
            let images = await service.captureThumbnails(for: windows, maxSide: maxSide)
            guard !Task.isCancelled, self.state.item?.id == item.id, !images.isEmpty else { return }
            self.apply(self.state.windows.map { w in
                var w = w
                if let img = images[w.id] { w.thumbnail = img }
                return w
            })
        }
    }

    // 一覧の順番は前回のまま保ち、サムネイルだけの更新はアニメーションさせない（チラつき防止）
    private func apply(_ windows: [WindowInfo]) {
        let order = Dictionary(state.windows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = windows.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        guard sorted != state.windows else { return }
        let structural = sorted.map(\.id) != state.windows.map(\.id)
            || zip(sorted, state.windows).contains { $0.title != $1.title || $0.isMinimized != $1.isMinimized }
        if structural && state.phase == .open {
            withAnimation(dockSettings.spring(0.34, damping: 0.82)) { state.windows = sorted }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { state.windows = sorted }
        }
    }

    private func startRefresh() {
        stopRefresh()
        guard settings.livePreview else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    func focus(_ window: WindowInfo) {
        hide(animated: true)
        WindowService.shared.focus(window)
    }

    func close(_ window: WindowInfo) {
        WindowService.shared.close(window)
        withAnimation(dockSettings.spring()) { state.windows.removeAll { $0.id == window.id } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.reload() }
    }

    func minimize(_ window: WindowInfo) {
        WindowService.shared.minimize(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.reload() }
    }

    func updateAppearance() {
        panel?.appearance = dockSettings.appearanceMode.nsAppearance
    }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let p = OverlayPanel(level: .popUpMenu, keyable: true)
        p.appearance = dockSettings.appearanceMode.nsAppearance
        let root = PreviewHost(state: state)
        p.contentView = PassthroughHostingView(rootView: AnyView(root))
        panel = p
        return p
    }
}

// ホバーした Dock の設定をプレビューに渡す
private struct PreviewHost: View {
    let state: PreviewState

    var body: some View {
        PreviewRootView(state: state)
            .environment(state.dockSettings)
            .environment(DockModel.shared)
    }
}

