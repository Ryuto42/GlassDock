import AppKit
import ApplicationServices

// ウィンドウ数と、すべて最小化されているかを、ポーリングせずに AX の通知で追跡する
@MainActor
final class MinimizeTracker {
    static let shared = MinimizeTracker()

    private var observers: [pid_t: AXObserver] = [:]
    private let notifications = [
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowResizedNotification,
        kAXWindowMovedNotification,
    ]

    func sync(_ apps: [NSRunningApplication]) {
        guard AXIsProcessTrusted() else { return }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in observers.keys where !pids.contains(pid) {
            if let obs = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
            DockModel.shared.setMinimized(pid, false)
            DockModel.shared.setWindowCount(pid, 0)
        }
        for pid in pids where observers[pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(pid, { _, element, notification, refcon in
                let owner = pid_t(Int(bitPattern: refcon))
                MainActor.assumeIsolated {
                    let name = notification as String
                    if name == kAXWindowResizedNotification {
                        WindowFitter.shared.windowResized(element)
                        return
                    }
                    if name == kAXWindowMovedNotification {
                        WindowFitter.shared.windowMoved(element)
                        return
                    }
                    if name == kAXWindowCreatedNotification { WindowFitter.shared.windowChanged(element) }
                    if name == kAXFocusedWindowChangedNotification { WindowFitter.shared.noteFrame(element) }
                    // 破棄されたウィンドウからは pid が取れないため、登録時の pid を使う
                    if (notification as String) == kAXUIElementDestroyedNotification {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MinimizeTracker.shared.refresh(owner) }
                    } else {
                        var pid: pid_t = 0
                        AXUIElementGetPid(element, &pid)
                        MinimizeTracker.shared.refresh(pid == 0 ? owner : pid)
                    }
                }
            }, &obs) == .success, let obs else { continue }
            let app = AXUIElementCreateApplication(pid)
            let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
            for n in notifications { AXObserverAddNotification(obs, app, n as CFString, refcon) }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
            refresh(pid)
        }
    }

    func refresh(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = (app.attribute(kAXWindowsAttribute) ?? []).filter {
            ($0.attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
        }
        // 閉じたときにも気づけるよう、各ウィンドウの破棄通知を登録する（登録済みならエラーが返るだけ）
        if let obs = observers[pid] {
            let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
            for w in windows { AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, refcon) }
        }
        windows.forEach(WindowFitter.shared.noteFrameIfUnknown)
        let minimized = windows.filter { ($0.attribute(kAXMinimizedAttribute) as Bool?) ?? false }
        DockModel.shared.setMinimized(pid, !minimized.isEmpty && minimized.count == windows.count)
        // タブはそれぞれ別のウィンドウとして返ってくるため、位置と大きさが同じものは1枚として数える
        let frames = Set(windows.map(Self.frameKey))
        DockModel.shared.setWindowCount(pid, frames.count)
    }

    private static func frameKey(_ w: AXUIElement) -> String {
        var pos = CGPoint.zero, size = CGSize.zero
        if let p: AXValue = w.attribute(kAXPositionAttribute) { AXValueGetValue(p, .cgPoint, &pos) }
        if let s: AXValue = w.attribute(kAXSizeAttribute) { AXValueGetValue(s, .cgSize, &size) }
        return "\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))"
    }
}
