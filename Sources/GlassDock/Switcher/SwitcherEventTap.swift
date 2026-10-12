import AppKit
import CoreGraphics

nonisolated enum SwitcherCommand: Sendable {
    case open(reverse: Bool)
    case step(Int)
    case row(Int)
    case commit
    case cancel
    case search
    case type(String)
    case backspace
}

// Option+Tab を前面のアプリに渡さず奪うためのイベントタップ。専用スレッドで動かし、判定だけして即座に返す
nonisolated final class SwitcherEventTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var active = false
    private var searching = false
    // 奪った keyDown に対応する keyUp も前面のアプリに渡さない
    private var swallowedUps = Set<Int64>()
    private let send: @Sendable (SwitcherCommand) -> Void

    init(send: @escaping @Sendable (SwitcherCommand) -> Void) {
        self.send = send
    }

    var isRunning: Bool { lock.withLock { port != nil } }

    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: switcherTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        lock.withLock { self.port = port }
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        nonisolated(unsafe) let tapPort = port
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tapPort, enable: true)
            // ポートを無効化するとソースが外れ、ここから抜ける
            CFRunLoopRun()
        }
        thread.name = "GlassDock.WindowSwitcherTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        let port: CFMachPort? = lock.withLock {
            defer { self.port = nil; active = false; searching = false }
            return self.port
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }

    func deactivate() {
        lock.withLock { active = false; searching = false }
    }

    // true を返したイベントは捨てる
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .flagsChanged:
            let released = !event.flags.contains(.maskAlternate)
            let commit: Bool = lock.withLock {
                guard active, !searching, released else { return false }
                active = false
                return true
            }
            if commit { send(.commit) }
            return false
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return lock.withLock { swallowedUps.remove(code) != nil }
        case .keyDown:
            return keyDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let shift = flags.contains(.maskShift)
        lock.lock()
        defer { lock.unlock() }

        if !active {
            guard code == Key.tab, flags.contains(.maskAlternate),
                  !flags.contains(.maskCommand), !flags.contains(.maskControl)
            else { return false }
            active = true
            swallowedUps.insert(code)
            send(.open(reverse: shift))
            return true
        }

        swallowedUps.insert(code)
        switch code {
        case Key.tab: send(.step(shift ? -1 : 1))
        case Key.left: send(.step(-1))
        case Key.right: send(.step(1))
        case Key.up: send(.row(-1))
        case Key.down: send(.row(1))
        case Key.escape:
            active = false; searching = false
            send(.cancel)
        case Key.returnKey, Key.enter:
            active = false; searching = false
            send(.commit)
        case Key.delete where searching: send(.backspace)
        case Key.slash where !searching:
            searching = true
            send(.search)
        default:
            if searching, let text = typedText(event) { send(.type(text)) }
        }
        return true
    }

    private func typedText(_ event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return s
    }

    private enum Key {
        static let tab: Int64 = 48, escape: Int64 = 53, returnKey: Int64 = 36, enter: Int64 = 76
        static let delete: Int64 = 51, slash: Int64 = 44
        static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    }
}

nonisolated private func switcherTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<SwitcherEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
