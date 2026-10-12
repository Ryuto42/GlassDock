import AppKit
import ApplicationServices

// Dock を常に表示しているとき、画面いっぱいや左右・上下に寄せたウィンドウが Dock に重ならないようにする。
// タイトルバーのダブルクリックはこちらで受け取り、最初から Dock を避けた大きさへ広げる。
// メニューやショートカットで広げられたときは、広がりきったあとに縮める
@MainActor
final class WindowFitter {
    static let shared = WindowFitter()

    private var pending: [AXUIElement] = []
    // 縮めたウィンドウと、そのとき合わせた Dock 側の端。Dock の大きさが変わったら付いていく
    private var fitted: [(window: AXUIElement, edge: CGFloat)] = []
    // 広げる前の大きさ。もう一度ダブルクリックしたら戻す
    private var restoreFrames: [(window: AXUIElement, frame: CGRect)] = []
    // 最後に落ち着いていたときの位置と大きさ。広がり始めた時点ではもう変わっているため、前もって覚えておく
    private var stableFrames: [(window: AXUIElement, frame: CGRect)] = []
    private var moved: [AXUIElement] = []
    private var movedWork: DispatchWorkItem?
    private var work: DispatchWorkItem?
    private let animator = WindowAnimator()
    private lazy var tap = TitleBarTap { window, action in
        nonisolated(unsafe) let w = window
        DispatchQueue.main.async {
            if action == .toggle { WindowFitter.shared.toggleFill(w) } else { WindowFitter.shared.tile(w, action) }
        }
    }
    private let tolerance: CGFloat = 16

    // Dock を常に表示している画面だけ、ダブルクリックを見張る
    func updateReservations() {
        guard let primary = NSScreen.screens.first else { return }
        let screens = NSScreen.screens
            .filter { DockPanelController.shared.reservedInset(on: $0) != nil }
            .map { CGRect(x: $0.frame.minX, y: primary.frame.maxY - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        tap.setScreens(screens)
    }

    // 画面いっぱいなど、アプリやシステムが大きさを変えたときだけ合わせる。
    // 移動しただけのときや、マウスで端をつかんで大きさを変えたときは、ユーザーが決めた位置なので触らない
    func windowResized(_ window: AXUIElement) {
        if NSEvent.pressedMouseButtons != 0 {
            pending.removeAll { CFEqual($0, window) }
            return
        }
        windowChanged(window)
    }

    func windowMoved(_ window: AXUIElement) {
        if !moved.contains(where: { CFEqual($0, window) }) { moved.append(window) }
        movedWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let windows = moved
            moved = []
            for w in windows where !animator.isAnimating(w) && !pending.contains(where: { CFEqual($0, w) }) {
                noteFrame(w)
            }
        }
        movedWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func noteFrame(_ window: AXUIElement) {
        guard let frame = frame(of: window) else { return }
        setStable(window, frame)
    }

    func noteFrameIfUnknown(_ window: AXUIElement) {
        guard !stableFrames.contains(where: { CFEqual($0.window, window) }), !animator.isAnimating(window),
              !pending.contains(where: { CFEqual($0, window) }) else { return }
        noteFrame(window)
    }

    private func setStable(_ window: AXUIElement, _ frame: CGRect) {
        stableFrames.removeAll { CFEqual($0.window, window) }
        stableFrames.append((window, frame))
        if stableFrames.count > 200 { stableFrames.removeFirst() }
    }

    private func setRestore(_ window: AXUIElement, _ frame: CGRect) {
        restoreFrames.removeAll { CFEqual($0.window, window) }
        // Dock に重なる大きさに戻すとすぐまた縮めることになるため、覚えない（戻すときは中央に置く）
        guard !overlapsDock(frame) else {
            tap.setRestorable(Set(restoreFrames.map { CFHash($0.window) }))
            return
        }
        restoreFrames.append((window, frame))
        if restoreFrames.count > 50 { restoreFrames.removeFirst() }
        tap.setRestorable(Set(restoreFrames.map { CFHash($0.window) }))
    }

    private func takeRestore(_ window: AXUIElement) -> CGRect? {
        defer {
            restoreFrames.removeAll { CFEqual($0.window, window) }
            tap.setRestorable(Set(restoreFrames.map { CFHash($0.window) }))
        }
        return restoreFrames.first { CFEqual($0.window, window) }?.frame
    }

    private func overlapsDock(_ frame: CGRect) -> Bool {
        guard let screen = screen(containing: frame),
              let (position, inset) = DockPanelController.shared.reservedInset(on: screen) else { return false }
        let sf = screen.frame
        return switch position {
        case .bottom: frame.minY < sf.minY + inset - 1
        case .left: frame.minX < sf.minX + inset - 1
        case .right: frame.maxX > sf.maxX - inset + 1
        }
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    // 元の大きさが分からないときは、画面の中央に 7 割ほどの大きさで置く
    private static func fallbackFrame(in area: CGRect) -> CGRect {
        area.insetBy(dx: area.width * 0.15, dy: area.height * 0.15).integral
    }

    func windowChanged(_ window: AXUIElement) {
        guard !animator.isAnimating(window) else { return }
        if !pending.contains(where: { CFEqual($0, window) }) { pending.append(window) }
        // アプリ自身の広がる動きが終わってから縮める。途中で触ると押し戻されて行き来する
        schedule(after: 0.1)
    }

    private func schedule(after delay: TimeInterval) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flush() {
        // ドラッグ中は動かさず、離してから合わせる
        if NSEvent.pressedMouseButtons != 0 {
            schedule(after: 0.3)
            return
        }
        let windows = pending
        pending = []
        windows.forEach(fit)
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    // Dock を避けた「画面いっぱい」の範囲
    private func fillTarget(on screen: NSScreen, position: DockPosition, inset: CGFloat) -> (frame: CGRect, edge: CGFloat) {
        let sf = screen.frame
        var t = screen.visibleFrame
        switch position {
        case .bottom:
            let e = max(t.minY, sf.minY + inset)
            t.size.height = t.maxY - e
            t.origin.y = e
            return (t, t.minY)
        case .left:
            let e = max(t.minX, sf.minX + inset)
            t.size.width = t.maxX - e
            t.origin.x = e
            return (t, t.minX)
        case .right:
            let e = min(t.maxX, sf.maxX - inset)
            t.size.width = e - t.minX
            return (t, t.maxX)
        }
    }

    // 地球儀キー＋Control のショートカット（埋める・左右・下半分・元に戻す）
    func tile(_ window: AXUIElement, _ action: TileAction) {
        guard let frame = frame(of: window), let screen = screen(containing: frame),
              let (position, inset) = DockPanelController.shared.reservedInset(on: screen) else { return }
        if action == .restore {
            guard let saved = takeRestore(window) else { return }
            fitted.removeAll { CFEqual($0.window, window) }
            setStable(window, saved)
            animate(window, from: frame, to: saved, duration: 0.3)
            return
        }
        let area = fillTarget(on: screen, position: position, inset: inset).frame
        let target: CGRect = switch action {
        case .left: CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(), height: area.height)
        case .right: CGRect(x: area.minX + (area.width / 2).rounded(), y: area.minY, width: area.width - (area.width / 2).rounded(), height: area.height)
        case .bottom: CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height / 2).rounded())
        default: area
        }
        guard !Self.near(frame, target) else { return }
        // 並べ替えを続けても、最初の大きさを覚えたままにする
        if !fitted.contains(where: { CFEqual($0.window, window) }) || !restoreFrames.contains(where: { CFEqual($0.window, window) }) {
            setRestore(window, frame)
        }
        let edge: CGFloat = switch position {
        case .bottom: target.minY
        case .left: target.minX
        case .right: target.maxX
        }
        remember(window, edge: edge)
        setStable(window, target)
        animate(window, from: frame, to: target, duration: 0.3)
    }

    func toggleFill(_ window: AXUIElement) {
        guard let frame = frame(of: window), let screen = screen(containing: frame),
              let (position, inset) = DockPanelController.shared.reservedInset(on: screen) else { return }
        let (target, edge) = fillTarget(on: screen, position: position, inset: inset)
        if Self.near(frame, target) {
            let saved = takeRestore(window) ?? Self.fallbackFrame(in: target)
            fitted.removeAll { CFEqual($0.window, window) }
            setStable(window, saved)
            animate(window, from: frame, to: saved, duration: 0.3)
            return
        }
        setRestore(window, frame)
        remember(window, edge: edge)
        setStable(window, target)
        animate(window, from: frame, to: target, duration: 0.3)
    }

    // Dock の大きさや表示方法が変わったとき、縮めたウィンドウを新しい端に合わせ直す
    func refit() {
        let previous = fitted
        fitted = []
        for (window, oldEdge) in previous {
            guard let frame = frame(of: window), let screen = screen(containing: frame) else { continue }
            let reserved = DockPanelController.shared.reservedInset(on: screen)
            let position = reserved?.0 ?? DockSettings.settings(forDisplay: DockPanelController.screenID(screen)).position
            let sf = screen.frame, vf = screen.visibleFrame
            var target = frame
            let edge: CGFloat
            switch position {
            case .bottom:
                guard abs(frame.minY - oldEdge) <= 2 else { continue }
                edge = reserved.map { sf.minY + $0.1 } ?? vf.minY
                target.origin.y = edge
                target.size.height = frame.maxY - edge
            case .left:
                guard abs(frame.minX - oldEdge) <= 2 else { continue }
                edge = reserved.map { sf.minX + $0.1 } ?? vf.minX
                target.origin.x = edge
                target.size.width = frame.maxX - edge
            case .right:
                guard abs(frame.maxX - oldEdge) <= 2 else { continue }
                edge = reserved.map { sf.maxX - $0.1 } ?? vf.maxX
                target.size.width = edge - frame.minX
            }
            if target != frame { animate(window, from: frame, to: target, duration: 0.22) }
            if reserved != nil { fitted.append((window, edge)) }
        }
    }

    private func remember(_ window: AXUIElement, edge: CGFloat) {
        fitted.removeAll { CFEqual($0.window, window) }
        fitted.append((window, edge))
        if fitted.count > 100 { fitted.removeFirst(fitted.count - 100) }
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = window.attribute(kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &pos),
              let s: AXValue = window.attribute(kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        // AX は左上原点なので、AppKit の座標に直す
        return CGRect(x: pos.x, y: primary.frame.maxY - pos.y - size.height, width: size.width, height: size.height)
    }

    private func animate(_ window: AXUIElement, from: CGRect, to: CGRect, duration: Double) {
        guard let primary = NSScreen.screens.first else { return }
        animator.animate(window, from: from, to: to, flipY: primary.frame.maxY, duration: duration) {
            nonisolated(unsafe) let w = window
            // アプリが最後に大きさを戻してしまった場合に備えて、もう一度確かめる
            DispatchQueue.main.async { WindowFitter.shared.windowChanged(w) }
        }
    }

    private func fit(_ window: AXUIElement) {
        guard (window.attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              (window.attribute("AXFullScreen") as Bool?) != true,
              (window.attribute(kAXMinimizedAttribute) as Bool?) != true,
              let frame = frame(of: window), let screen = screen(containing: frame),
              let (position, inset) = DockPanelController.shared.reservedInset(on: screen) else { return }

        let previous = stableFrames.first { CFEqual($0.window, window) }?.frame
        let sf = screen.frame, vf = screen.visibleFrame
        var target = frame
        let edge: CGFloat
        defer { if !animator.isAnimating(window) { setStable(window, frame) } }
        switch position {
        case .bottom:
            edge = sf.minY + inset
            guard frame.minY < edge - 1, frame.minY <= vf.minY + tolerance, frame.maxY >= edge + 120 else { return }
            target.origin.y = edge
            target.size.height = frame.maxY - edge
        case .left:
            edge = sf.minX + inset
            guard frame.minX < edge - 1, frame.minX <= sf.minX + tolerance, frame.maxX >= edge + 120 else { return }
            target.origin.x = edge
            target.size.width = frame.maxX - edge
        case .right:
            edge = sf.maxX - inset
            guard frame.maxX > edge + 1, frame.maxX >= sf.maxX - tolerance, frame.minX <= edge - 120 else { return }
            target.size.width = edge - frame.minX
        }
        // Dock を避けて広げた状態から、アプリが自分でもう一度広げた（ダブルクリックで戻そうとした）ときは元の大きさに戻す。
        // 縮めたあとはアプリが「広げていない」と判断するため、戻すつもりの操作でまた広がってしまう
        let fill = fillTarget(on: screen, position: position, inset: inset)
        if let previous, Self.near(previous, fill.frame) {
            let saved = takeRestore(window) ?? Self.fallbackFrame(in: fill.frame)
            fitted.removeAll { CFEqual($0.window, window) }
            setStable(window, saved)
            animate(window, from: frame, to: saved, duration: 0.3)
            return
        }
        // 広がる前の大きさを覚えておく
        if let previous, previous.height < frame.height - 40 || previous.width < frame.width - 40 {
            setRestore(window, previous)
        }
        animate(window, from: frame, to: target, duration: 0.2)
        remember(window, edge: edge)
        setStable(window, target)
    }
}

// AX でウィンドウの位置と大きさを少しずつ変える。アプリの応答待ちで Dock が止まらないよう、専用のキューで動かす
nonisolated final class WindowAnimator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GlassDock.WindowAnimator", qos: .userInteractive)
    private let lock = NSLock()
    private var generations: [CFHashCode: Int] = [:]
    private var running: [CFHashCode: Int] = [:]

    func isAnimating(_ window: AXUIElement) -> Bool {
        lock.withLock { running[CFHash(window), default: 0] > 0 }
    }

    func animate(_ window: AXUIElement, from: CGRect, to: CGRect, flipY: CGFloat, duration: Double, done: @escaping @Sendable () -> Void) {
        let key = CFHash(window)
        let gen: Int = lock.withLock {
            generations[key, default: 0] += 1
            running[key, default: 0] += 1
            return generations[key]!
        }
        nonisolated(unsafe) let w = window
        queue.async { [self] in
            defer {
                lock.withLock { running[key, default: 1] -= 1 }
                done()
            }
            let start = CACurrentMediaTime()
            while true {
                guard lock.withLock({ generations[key] == gen }) else { return }
                let p = min((CACurrentMediaTime() - start) / duration, 1)
                let e = 1 - pow(1 - p, 3)
                let r = p >= 1 ? to : CGRect(
                    x: (from.minX + (to.minX - from.minX) * e).rounded(),
                    y: (from.minY + (to.minY - from.minY) * e).rounded(),
                    width: (from.width + (to.width - from.width) * e).rounded(),
                    height: (from.height + (to.height - from.height) * e).rounded())
                Self.set(r, on: w, flipY: flipY)
                if p >= 1 { break }
                Thread.sleep(forTimeInterval: 1.0 / 120)
            }
            // 大きさの変更を遅れて反映するアプリ（Chromium 系など）は、途中の大きさに戻ることがあるので合わせ直す
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.12)
                guard lock.withLock({ generations[key] == gen }) else { return }
                if let now = Self.frame(of: w, flipY: flipY), abs(now.minX - to.minX) <= 1, abs(now.minY - to.minY) <= 1,
                   abs(now.width - to.width) <= 1, abs(now.height - to.height) <= 1 { return }
                Self.set(to, on: w, flipY: flipY)
            }
        }
    }

    private static func frame(of window: AXUIElement, flipY: CGFloat) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = axAttr(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &pos),
              let s: AXValue = axAttr(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(x: pos.x, y: flipY - pos.y - size.height, width: size.width, height: size.height)
    }

    private static func set(_ rect: CGRect, on window: AXUIElement, flipY: CGFloat) {
        var pos = CGPoint(x: rect.minX, y: flipY - rect.maxY)
        var size = rect.size
        if let v = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }
}

nonisolated enum TileAction: Sendable {
    case toggle, fill, left, right, bottom, restore
}

// タイトルバーのダブルクリックと、地球儀キー＋Control のショートカットを、アプリや macOS が広げる前に受け取る
nonisolated final class TitleBarTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var screens: [CGRect] = []
    private var restorable: Set<CFHashCode> = []
    private var swallowMouseUp = false
    private var swallowedKeyUps = Set<Int64>()
    // 矢印キーは押すたびに fn の印が付くため、地球儀キーが本当に押されているかは別に追う
    private var globeDown = false
    private let systemWide = AXUIElementCreateSystemWide()
    private let send: @Sendable (AXUIElement, TileAction) -> Void

    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXTextFieldRole, kAXTextAreaRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole, "AXLink", kAXMenuBarItemRole, "AXSearchField",
    ]

    init(send: @escaping @Sendable (AXUIElement, TileAction) -> Void) {
        self.send = send
        // 応答しないアプリで入力全体が止まらないよう、短く打ち切る
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
    }

    func setScreens(_ screens: [CGRect]) {
        lock.withLock { self.screens = screens }
        if screens.isEmpty { stop() } else { start() }
    }

    func setRestorable(_ windows: Set<CFHashCode>) {
        lock.withLock { restorable = windows }
    }

    private func start() {
        guard lock.withLock({ port == nil }) else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: titleBarTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        lock.withLock { self.port = port }
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        nonisolated(unsafe) let tapPort = port
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tapPort, enable: true)
            CFRunLoopRun()
        }
        thread.name = "GlassDock.TitleBarTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func stop() {
        let port: CFMachPort? = lock.withLock {
            defer { self.port = nil; swallowMouseUp = false; swallowedKeyUps = [] }
            return self.port
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }

    // true を返したイベントは捨てる
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .flagsChanged:
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                let down = event.flags.contains(.maskSecondaryFn)
                lock.withLock { globeDown = down }
            }
            return false
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return lock.withLock { swallowedKeyUps.remove(code) != nil }
        case .keyDown:
            return keyDown(event)
        case .leftMouseUp:
            return lock.withLock {
                defer { swallowMouseUp = false }
                return swallowMouseUp
            }
        case .leftMouseDown:
            return mouseDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskControl), lock.withLock({ globeDown }),
              flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let action: TileAction
        switch code {
        case 3: action = .fill        // F
        case 123: action = .left      // ←
        case 124: action = .right     // →
        case 125: action = .bottom    // ↓
        case 15: action = .restore    // R
        default: return false
        }
        guard let window = focusedWindow(), let pos = position(of: window),
              lock.withLock({ screens.contains { $0.contains(CGPoint(x: pos.x + 1, y: pos.y + 1)) } }) else { return false }
        // 元に戻すのは、こちらで広げたウィンドウだけ。それ以外は macOS に任せる
        if action == .restore, !lock.withLock({ restorable.contains(CFHash(window)) }) { return false }
        lock.withLock { _ = swallowedKeyUps.insert(code) }
        send(window, action)
        return true
    }

    private func mouseDown(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.mouseEventClickState) == 2,
              event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else { return false }
        let p = event.location
        guard lock.withLock({ screens.contains { $0.contains(p) } }) else { return false }
        // 「タイトルバーをダブルクリックして」が「しまう」「何もしない」のときはアプリに任せる
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        guard action != "Minimize", action != "None" else { return false }
        guard let window = titleBarWindow(at: p) else { return false }
        lock.withLock { swallowMouseUp = true }
        send(window, .toggle)
        return true
    }

    private func focusedWindow() -> AXUIElement? {
        guard let app: AXUIElement = axAttr(systemWide, kAXFocusedApplicationAttribute),
              let window: AXUIElement = axAttr(app, kAXFocusedWindowAttribute),
              (axAttr(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              (axAttr(window, "AXFullScreen") as Bool?) != true else { return nil }
        return window
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var pos = CGPoint.zero
        guard let v: AXValue = axAttr(element, kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &pos) else { return nil }
        return pos
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var size = CGSize.zero
        guard let pos = position(of: element), let v: AXValue = axAttr(element, kAXSizeAttribute),
              AXValueGetValue(v, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // タイトルバーの何もない場所を押したときだけ、そのウィンドウを返す。
    // 独自のタイトルバーを持つアプリでも分かるよう、左上の閉じるボタンの高さからタイトルバーの帯を割り出す
    // （閉じる・最小化・拡大ボタンは、どのアプリでもタイトルバーの縦の中央に置かれる）
    private func titleBarWindow(at p: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let element = hit else { return nil }
        let role: String? = axAttr(element, kAXRoleAttribute)
        let window: AXUIElement
        if role == kAXWindowRole {
            window = element
        } else if let w: AXUIElement = axAttr(element, kAXWindowAttribute) {
            window = w
        } else {
            return nil
        }
        guard (axAttr(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              (axAttr(window, "AXFullScreen") as Bool?) != true,
              let top = position(of: window) else { return nil }
        let depth = p.y - top.y
        guard depth >= 0 else { return nil }

        // ツールバー（Finder など）は全体をタイトルバーとして扱う
        let toolbar = role == kAXToolbarRole ? element : (axAttr(window, kAXChildrenAttribute) as [AXUIElement]?)?
            .first { (axAttr($0, kAXRoleAttribute) as String?) == kAXToolbarRole }
        let inToolbar = toolbar.flatMap(frame(of:))?.contains(p) ?? false

        var band: CGFloat = 28
        if let close: AXUIElement = axAttr(window, kAXCloseButtonAttribute), let f = frame(of: close) {
            band = min(max((f.midY - top.y) * 2, 24), 64)
        }
        guard inToolbar || depth <= band else { return nil }

        // ボタンや入力欄の上は除く。ただしタブ（タブの並びの中のボタン）はタイトルバーと同じに扱う
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let c = current, !CFEqual(c, window) else { break }
            let r: String? = axAttr(c, kAXRoleAttribute)
            let parent: AXUIElement? = axAttr(c, kAXParentAttribute)
            if let r, Self.controlRoles.contains(r) {
                let parentRole: String? = parent.flatMap { axAttr($0, kAXRoleAttribute) }
                if parentRole != kAXTabGroupRole { return nil }
            }
            current = parent
        }
        return window
    }
}

private nonisolated func titleBarTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<TitleBarTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

private nonisolated func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

