import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit

// 非公開 API。見つからない環境でも起動できるよう、リンク時ではなく実行時に探す
nonisolated let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var frame: CGRect
    var isMinimized: Bool
    var isOnScreen: Bool
    var thumbnail: CGImage?

    static func == (a: WindowInfo, b: WindowInfo) -> Bool {
        a.id == b.id && a.title == b.title && a.isMinimized == b.isMinimized && a.thumbnail === b.thumbnail
    }
}

// 別のスレッドで AX から読んだウィンドウの情報
nonisolated struct AXWindowSnapshot: @unchecked Sendable {
    let element: AXUIElement
    let title: String?
    let subrole: String?
    let minimized: Bool
}

@MainActor
final class WindowService {
    static let shared = WindowService()

    private var thumbnailCache: [CGWindowID: CGImage] = [:]
    private var scWindows: [CGWindowID: SCWindow] = [:]

    func axWindows(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let axGetWindow else { return [:] }
        let windows: [AXUIElement] = app.attribute(kAXWindowsAttribute) ?? []
        var result: [CGWindowID: AXUIElement] = [:]
        for w in windows {
            var id: CGWindowID = 0
            if axGetWindow(w, &id) == .success, id != 0 { result[id] = w }
        }
        return result
    }

    // Chromium 系など AX の応答が遅いアプリでもホバーが止まらないよう、メインスレッドの外で読む
    nonisolated static func axSnapshot(pid: pid_t) -> [CGWindowID: AXWindowSnapshot] {
        guard let axGetWindow else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = app.attribute(kAXWindowsAttribute) ?? []
        var result: [CGWindowID: AXWindowSnapshot] = [:]
        for w in windows {
            var id: CGWindowID = 0
            guard axGetWindow(w, &id) == .success, id != 0 else { continue }
            result[id] = AXWindowSnapshot(element: w, title: w.attribute(kAXTitleAttribute), subrole: w.attribute(kAXSubroleAttribute),
                                          minimized: w.attribute(kAXMinimizedAttribute) ?? false)
        }
        return result
    }

    // ScreenCaptureKit の一覧を基準にし、AX で最小化状態とタイトルを補う
    func windows(pid: pid_t) async -> [WindowInfo] {
        let axTask = Task.detached(priority: .userInitiated) { Self.axSnapshot(pid: pid) }
        var list: [WindowInfo] = []
        let content = Permissions.screenRecording
            ? try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) : nil
        let ax = await axTask.value

        if let content {
            let appHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            for w in content.windows where w.owningApplication?.processID == pid {
                guard w.windowLayer == 0, w.frame.width > 60, w.frame.height > 40 else { continue }
                let axw = ax[w.windowID]
                let minimized = axw?.minimized ?? false
                let title = w.title.flatMap { $0.isEmpty ? nil : $0 } ?? axw?.title ?? ""
                // 画面外の隠しウィンドウ（Zoom の補助ウィンドウなど）は、最小化中か非表示アプリのものだけ残す
                guard w.isOnScreen || (axw != nil && (minimized || appHidden)) else { continue }
                scWindows[w.windowID] = w
                list.append(WindowInfo(
                    id: w.windowID, pid: pid, title: title, frame: w.frame,
                    isMinimized: minimized, isOnScreen: w.isOnScreen,
                    thumbnail: thumbnailCache[w.windowID]
                ))
            }
            // タブ付きウィンドウは「ウィンドウ全体」と「タブの中身」の2枚が返るため、
            // 同じタイトルで別のウィンドウの内側に収まっているものは除く
            list = list.filter { inner in
                !list.contains { outer in
                    outer.id != inner.id && outer.isOnScreen && inner.isOnScreen && outer.title == inner.title
                        && outer.frame != inner.frame && outer.frame.contains(inner.frame)
                }
            }
        } else {
            for (id, w) in ax {
                guard w.subrole == nil || w.subrole == kAXStandardWindowSubrole || w.subrole == kAXDialogSubrole else { continue }
                list.append(WindowInfo(
                    id: id, pid: pid, title: w.title ?? "",
                    frame: .zero, isMinimized: w.minimized,
                    isOnScreen: true, thumbnail: nil
                ))
            }
        }
        return list
    }

    func captureThumbnails(for windows: [WindowInfo], maxSide: CGFloat) async -> [CGWindowID: CGImage] {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targets = windows.filter { $0.isOnScreen && !$0.isMinimized }.compactMap { info -> (CGWindowID, SCWindow)? in
            scWindows[info.id].map { (info.id, $0) }
        }
        let images = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for (id, window) in targets {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let ratio = min(1, maxSide * scale / max(window.frame.width, window.frame.height))
                config.width = max(1, Int(window.frame.width * ratio))
                config.height = max(1, Int(window.frame.height * ratio))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.capturesShadowsOnly = false
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (id, image)
                }
            }
            var result: [CGWindowID: CGImage] = [:]
            for await (id, image) in group { if let image { result[id] = image } }
            return result
        }
        thumbnailCache.merge(images) { $1 }
        return images
    }

    func focus(_ window: WindowInfo) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if let axw = axWindows(pid: window.pid)[window.id] {
            if window.isMinimized { axw.set(kAXMinimizedAttribute, kCFBooleanFalse) }
            axw.set(kAXMainAttribute, kCFBooleanTrue)
            axw.perform(kAXRaiseAction)
        }
        app?.activate()
    }

    func close(_ window: WindowInfo) {
        guard let axw = axWindows(pid: window.pid)[window.id],
              let button: AXUIElement = axw.attribute(kAXCloseButtonAttribute)
        else { return }
        button.perform(kAXPressAction)
        thumbnailCache[window.id] = nil
    }

    func minimize(_ window: WindowInfo) {
        axWindows(pid: window.pid)[window.id]?.set(kAXMinimizedAttribute, kCFBooleanTrue)
    }

    private func standardWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = app.attribute(kAXWindowsAttribute) ?? []
        return windows.filter { w in
            let subrole: String? = w.attribute(kAXSubroleAttribute)
            return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    @discardableResult
    func minimizeAll(pid: pid_t) -> Bool {
        let targets = standardWindows(pid: pid).filter { !($0.attribute(kAXMinimizedAttribute) as Bool? ?? false) }
        for w in targets { w.set(kAXMinimizedAttribute, kCFBooleanTrue) }
        return !targets.isEmpty
    }

    @discardableResult
    func restoreAll(pid: pid_t) -> Bool {
        let targets = standardWindows(pid: pid).filter { $0.attribute(kAXMinimizedAttribute) as Bool? ?? false }
        for w in targets { w.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        if !targets.isEmpty { NSRunningApplication(processIdentifier: pid)?.activate() }
        return !targets.isEmpty
    }

    func purge(pid: pid_t) {
        let ids = scWindows.filter { $0.value.owningApplication?.processID == pid }.map(\.key)
        for id in ids {
            scWindows[id] = nil
            thumbnailCache[id] = nil
        }
    }
}
