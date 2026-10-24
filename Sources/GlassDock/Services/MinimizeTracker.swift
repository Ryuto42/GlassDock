import AppKit
import ApplicationServices

// ウィンドウ数と、すべて最小化されているかを、ポーリングせずに AX の通知で追跡する
@MainActor
final class MinimizeTracker {
    static let shared = MinimizeTracker()

    private var observers: [pid_t: AXObserver] = [:]
    // Chromium 系など AX の応答が遅いアプリでメインスレッドを止めないよう、数え直しは別のキューで行う
    private let queue = DispatchQueue(label: "GlassDock.MinimizeTracker", qos: .utility)
    private var inFlight: Set<pid_t> = []
    private var dirty: Set<pid_t> = []
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
                    // 破棄されたウィンドウからは pid が取れないため、登録時の pid を使う
                    if name == kAXUIElementDestroyedNotification {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MinimizeTracker.shared.refresh(owner) }
                    } else {
                        var pid: pid_t = 0
                        AXUIElementGetPid(element, &pid)
                        let target = pid == 0 ? owner : pid
                        MinimizeTracker.shared.refresh(target)
                        // 最小化・元に戻すの直後は、ウィンドウの状態がまだ切り替わっていないことがあるので、少し後にもう一度確かめる
                        if name == kAXWindowMiniaturizedNotification || name == kAXWindowDeminiaturizedNotification {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MinimizeTracker.shared.refresh(target) }
                        }
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

    // 通知が続けて届いても、同じアプリの数え直しは1つずつ行い、途中で届いた分は終わってからもう一度だけ行う
    func refresh(_ pid: pid_t) {
        guard !inFlight.contains(pid) else {
            dirty.insert(pid)
            return
        }
        inFlight.insert(pid)
        nonisolated(unsafe) let observer = observers[pid]
        queue.async {
            let result = Self.scan(pid: pid, observer: observer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MinimizeTracker.shared.apply(pid, result) }
            }
        }
    }

    private func apply(_ pid: pid_t, _ result: Scan) {
        inFlight.remove(pid)
        // 数えている間にアプリが終了していたら反映しない
        guard observers[pid] != nil else { return }
        for (window, frame) in result.windows { WindowFitter.shared.noteFrameIfUnknown(window, frame: frame) }
        DockModel.shared.setMinimized(pid, result.allMinimized)
        DockModel.shared.setWindowCount(pid, result.count)
        if dirty.remove(pid) != nil { refresh(pid) }
    }

    nonisolated struct Scan: @unchecked Sendable {
        var windows: [(AXUIElement, CGRect)] = []
        var allMinimized = false
        var count = 0
    }

    nonisolated private static func scan(pid: pid_t, observer: AXObserver?) -> Scan {
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = (app.attribute(kAXWindowsAttribute) ?? []).filter {
            ($0.attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
        }
        // 閉じたときにも気づけるよう、各ウィンドウの破棄通知を登録する（登録済みならエラーが返るだけ）
        if let observer {
            let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
            for w in windows { AXObserverAddNotification(observer, w, kAXUIElementDestroyedNotification as CFString, refcon) }
        }
        var result = Scan()
        var minimized = 0
        var keys = Set<String>()
        for w in windows {
            var pos = CGPoint.zero, size = CGSize.zero
            if let p: AXValue = w.attribute(kAXPositionAttribute) { AXValueGetValue(p, .cgPoint, &pos) }
            if let s: AXValue = w.attribute(kAXSizeAttribute) { AXValueGetValue(s, .cgSize, &size) }
            if (w.attribute(kAXMinimizedAttribute) as Bool?) ?? false { minimized += 1 }
            result.windows.append((w, CGRect(origin: pos, size: size)))
            // タブはそれぞれ別のウィンドウとして返ってくるため、位置と大きさが同じものは1枚として数える
            keys.insert("\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))")
        }
        result.allMinimized = minimized > 0 && minimized == windows.count
        result.count = keys.count
        return result
    }
}
