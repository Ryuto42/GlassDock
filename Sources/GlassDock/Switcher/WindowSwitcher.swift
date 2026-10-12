import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import SwiftUI

@_silgen_name("_AXUIElementGetWindow")
nonisolated private func switcherAXGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@Observable
final class SwitcherState {
    var windows: [WindowInfo] = []
    var thumbnails: [CGWindowID: CGImage] = [:]
    var appNames: [pid_t: String] = [:]
    var icons: [pid_t: NSImage] = [:]
    var selectedID: CGWindowID?
    var query = ""
    var searching = false
    var visible = false
    var cardWidth: CGFloat = 220
    var maxColumns = 1
    var maxGridHeight: CGFloat = 600

    var items: [WindowInfo] {
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || (appNames[$0.pid] ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var columns: Int { max(1, min(items.count, maxColumns)) }

    static let spacing: CGFloat = 12
    static let cardPadding: CGFloat = 8
    static let headerHeight: CGFloat = 22
    var thumbHeight: CGFloat { (cardWidth * 0.6).rounded() }
    var cardSize: CGSize {
        CGSize(width: cardWidth + Self.cardPadding * 2, height: Self.headerHeight + 6 + thumbHeight + Self.cardPadding * 2)
    }
}

nonisolated private struct AXWindowEntry: Sendable {
    let id: CGWindowID
    let title: String
    let minimized: Bool
    let standard: Bool
}

@MainActor
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    let state = SwitcherState()
    private let tap = SwitcherEventTap { command in
        DispatchQueue.main.async { MainActor.assumeIsolated { WindowSwitcher.shared.handle(command) } }
    }
    private var panel: OverlayPanel?
    private var isOpen = false
    private var generation = 0
    private var showWork: DispatchWorkItem?
    private var axTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var retryTimer: Timer?
    private var mouseAtOpen: CGPoint = .zero
    private var mouseMoved = false
    private var userMoved = false
    private var reverseAtOpen = false
    private var appOrder: [pid_t] = []

    func start() {
        applyEnabled()
        observeSettings()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = DockSettings.shared.windowSwitcherEnabled
        } onChange: {
            DispatchQueue.main.async {
                WindowSwitcher.shared.applyEnabled()
                WindowSwitcher.shared.observeSettings()
            }
        }
    }

    private func applyEnabled() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard DockSettings.shared.windowSwitcherEnabled else {
            tap.stop()
            close()
            return
        }
        guard !tap.start() else { return }
        // アクセシビリティ権限がまだない場合は、許可されるまで間隔をあけて作り直す
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = WindowSwitcher.shared
                if s.tap.start() { s.retryTimer?.invalidate(); s.retryTimer = nil }
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func handle(_ command: SwitcherCommand) {
        if case .open(let reverse) = command {
            if isOpen { step(reverse ? -1 : 1) } else { open(reverse: reverse) }
            return
        }
        guard isOpen else { return }
        switch command {
        case .open: break
        case .step(let d): step(d)
        case .row(let d): row(d)
        case .commit: commit(state.selectedID)
        case .cancel: close()
        case .search: state.searching = true
        case .type(let text):
            state.query += text
            queryChanged()
        case .backspace:
            if !state.query.isEmpty { state.query.removeLast() }
            queryChanged()
        }
    }

    // MARK: - Open / Close

    private func open(reverse: Bool) {
        generation += 1
        let gen = generation
        isOpen = true
        userMoved = false
        mouseMoved = false
        reverseAtOpen = reverse
        mouseAtOpen = NSEvent.mouseLocation
        state.query = ""
        state.searching = false
        state.thumbnails = [:]

        let screen = NSScreen.screens.first { NSMouseInRect(mouseAtOpen, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let available = frame.width - 120 - 32
        state.cardWidth = available < 900 ? 180 : 220
        state.maxColumns = max(1, Int((available + SwitcherState.spacing) / (state.cardSize.width + SwitcherState.spacing)))
        state.maxGridHeight = frame.height * 0.72 - 60

        let windows = onScreenWindows()
        appOrder = []
        for w in windows where !appOrder.contains(w.pid) { appOrder.append(w.pid) }
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map(\.processIdentifier)
        for pid in others where !appOrder.contains(pid) { appOrder.append(pid) }
        for pid in Set(windows.map(\.pid)) { loadMeta(pid) }
        state.windows = windows
        selectDefault()

        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.isOpen else { return }
            self.showPanel(frame: frame)
        }
        showWork = work
        // 素早い Option+Tab（Cmd+Tab と同じ）ではパネルを出さずに切り替える
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)

        let pids = appOrder
        axTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.scanAX(pids) }.value
            guard let self, gen == self.generation, !Task.isCancelled else { return }
            self.merge(result)
        }
        loadThumbnails(windows, gen: gen, scale: screen?.backingScaleFactor ?? 2)
    }

    private func showPanel(frame: CGRect) {
        let p = ensurePanel()
        p.appearance = DockSettings.shared.appearanceMode.nsAppearance
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.14)) { state.visible = true }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { WindowSwitcher.shared.close() }
        }
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        tap.deactivate()
        showWork?.cancel()
        axTask?.cancel()
        thumbTask?.cancel()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel?.orderOut(nil)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            state.visible = false
            state.windows = []
            state.thumbnails = [:]
            state.icons = [:]
            state.appNames = [:]
            state.selectedID = nil
            state.query = ""
            state.searching = false
        }
    }

    func commit(_ id: CGWindowID?) {
        guard isOpen else { return }
        let target = state.windows.first { $0.id == id }
        close()
        guard let target else { return }
        if let app = NSRunningApplication(processIdentifier: target.pid), app.isHidden { app.unhide() }
        WindowService.shared.focus(target)
    }

    // MARK: - Selection

    private func selectDefault() {
        let items = state.items
        guard !items.isEmpty else { state.selectedID = nil; return }
        // 前面のアプリにウィンドウがない（デスクトップを選んでいる等）ときは先頭から選ぶ
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let first = items[0].pid == front && items.count > 1 ? 1 : 0
        state.selectedID = reverseAtOpen ? items[items.count - 1].id : items[first].id
    }

    private func step(_ delta: Int) {
        let items = state.items
        guard !items.isEmpty else { return }
        userMoved = true
        let i = items.firstIndex { $0.id == state.selectedID } ?? 0
        state.selectedID = items[(i + delta % items.count + items.count) % items.count].id
    }

    private func row(_ delta: Int) {
        let items = state.items
        guard !items.isEmpty, let i = items.firstIndex(where: { $0.id == state.selectedID }) else { return step(delta) }
        let j = i + delta * state.columns
        guard items.indices.contains(j) else { return }
        userMoved = true
        state.selectedID = items[j].id
    }

    private func queryChanged() {
        let items = state.items
        if !items.contains(where: { $0.id == state.selectedID }) { state.selectedID = items.first?.id }
    }

    func hover(_ id: CGWindowID) {
        guard isOpen, state.selectedID != id else { return }
        // 開いた瞬間にカーソルの下にあったカードは選ばない（動かしてから反応させる）
        if !mouseMoved {
            let p = NSEvent.mouseLocation
            guard hypot(p.x - mouseAtOpen.x, p.y - mouseAtOpen.y) > 4 else { return }
            mouseMoved = true
        }
        userMoved = true
        state.selectedID = id
    }

    // MARK: - Window list

    // 画面上のウィンドウは前面から順に返るので、そのまま最近使った順として扱う
    private func onScreenWindows() -> [WindowInfo] {
        let own = getpid()
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var regular: [pid_t: Bool] = [:]
        var list: [WindowInfo] = []
        for d in raw {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 60, frame.height > 40,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let isRegular = regular[pid] ?? (NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular)
            regular[pid] = isRegular
            guard isRegular else { continue }
            list.append(WindowInfo(
                id: id, pid: pid, title: d[kCGWindowName as String] as? String ?? "", frame: frame,
                isMinimized: false, isOnScreen: true, thumbnail: nil
            ))
        }
        // タブ付きウィンドウの「タブの中身」側を除く（WindowService と同じ考え方）
        return list.filter { inner in
            !list.contains { outer in
                outer.id != inner.id && outer.pid == inner.pid && outer.title == inner.title
                    && outer.frame != inner.frame && outer.frame.contains(inner.frame)
            }
        }
    }

    private func loadMeta(_ pid: pid_t) {
        guard state.appNames[pid] == nil, let app = NSRunningApplication(processIdentifier: pid) else { return }
        state.appNames[pid] = app.localizedName ?? ""
        if let icon = app.icon { state.icons[pid] = icon }
    }

    nonisolated private static func scanAX(_ pids: [pid_t]) -> [pid_t: [AXWindowEntry]] {
        func value<T>(_ e: AXUIElement, _ name: String) -> T? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
            return v as? T
        }
        let lock = NSLock()
        var result: [pid_t: [AXWindowEntry]] = [:]
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            let app = AXUIElementCreateApplication(pid)
            // 応答しないアプリで待たされないよう短めにする
            AXUIElementSetMessagingTimeout(app, 0.3)
            guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute) else { return }
            let entries = windows.compactMap { w -> AXWindowEntry? in
                AXUIElementSetMessagingTimeout(w, 0.3)
                var id: CGWindowID = 0
                guard switcherAXGetWindow(w, &id) == .success, id != 0 else { return nil }
                let subrole: String? = value(w, kAXSubroleAttribute)
                return AXWindowEntry(
                    id: id, title: value(w, kAXTitleAttribute) ?? "",
                    minimized: value(w, kAXMinimizedAttribute) ?? false,
                    standard: subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
                )
            }
            lock.withLock { result[pid] = entries }
        }
        return result
    }

    // AX の結果で、補助的な浮遊ウィンドウを除き、タイトルを補い、最小化・非表示のウィンドウを末尾に足す
    private func merge(_ ax: [pid_t: [AXWindowEntry]]) {
        var list = state.windows.compactMap { w -> WindowInfo? in
            guard let entries = ax[w.pid], !entries.isEmpty else { return w }
            guard let e = entries.first(where: { $0.id == w.id }) else { return nil }
            var w = w
            if w.title.isEmpty { w.title = e.title }
            return w
        }
        var present = Set(list.map(\.id))
        for minimizedPass in [true, false] {
            for pid in appOrder {
                let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
                for e in ax[pid] ?? [] where e.standard && !present.contains(e.id) {
                    guard minimizedPass ? (e.minimized && !hidden) : hidden else { continue }
                    list.append(WindowInfo(
                        id: e.id, pid: pid, title: e.title, frame: .zero,
                        isMinimized: e.minimized, isOnScreen: false, thumbnail: nil
                    ))
                    present.insert(e.id)
                    loadMeta(pid)
                }
            }
        }
        guard list != state.windows else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            state.windows = list
            if !userMoved || !state.items.contains(where: { $0.id == state.selectedID }) { selectDefault() }
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails(_ windows: [WindowInfo], gen: Int, scale: CGFloat) {
        guard Permissions.screenRecording, !windows.isEmpty else { return }
        let ids = Set(windows.map(\.id))
        let maxSide = state.cardWidth * scale
        thumbTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  !Task.isCancelled
            else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for window in targets {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    let ratio = min(1, maxSide / max(window.frame.width, window.frame.height))
                    config.width = max(1, Int(window.frame.width * ratio))
                    config.height = max(1, Int(window.frame.height * ratio))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let id = window.windowID
                    group.addTask {
                        (id, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
                    }
                }
                for await (id, image) in group {
                    guard let self, gen == self.generation, let image else { continue }
                    withAnimation(.easeOut(duration: 0.15)) { self.state.thumbnails[id] = image }
                }
            }
        }
    }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let p = OverlayPanel(level: .popUpMenu)
        p.collectionBehavior.insert(.fullScreenAuxiliary)
        p.contentView = PassthroughHostingView(rootView: AnyView(WindowSwitcherRootView(state: state)))
        panel = p
        return p
    }
}
