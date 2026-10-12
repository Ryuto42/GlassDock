import AppKit
import ApplicationServices
import CoreAudio

@MainActor
enum AppActions {
    // MARK: - App

    static func relaunch(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        app.terminate()
        Task {
            for _ in 0..<100 where !app.isTerminated {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // 保存確認などで終了しなかった場合は、未保存のデータを守るため強制終了せずに取りやめる
            guard app.isTerminated else { return }
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func closeAll(_ app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows: [AXUIElement] = root.attribute(kAXWindowsAttribute) ?? []
        for w in windows {
            if let button: AXUIElement = w.attribute(kAXCloseButtonAttribute) { button.perform(kAXPressAction) }
        }
    }

    static func newWindow(_ app: NSRunningApplication) {
        let keywords = ["新規ウインドウ", "新規ウィンドウ", "新しいウィンドウ", "新しいウインドウ", "New Window",
                        "新規ブラウザウインドウ", "新規 Finder ウインドウ", "新規Finderウインドウ", "New Finder Window"]
        let command = menuCommands(pid: app.processIdentifier).first { c in
            keywords.contains { c.title.hasPrefix($0) }
        }
        app.unhide()
        app.activate()
        // 前面に出る前のアプリのメニューは押せないことがあるため、少し待ってから押す
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if let command, command.element.perform(kAXPressAction) { return }
            postCommandKey(0x2D, to: app.processIdentifier)
        }
    }

    // メニューが見つからないときの代わりに ⌘N などをアプリへ直接送る
    private static func postCommandKey(_ key: CGKeyCode, to pid: pid_t) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    // MARK: - System Dock menu（ブラウザの「新規シークレットウインドウ」などアプリ独自の項目）

    private static var dockMenuCache: [String: (titles: [String], at: Date)] = [:]

    private static let standardDockMenuTitles: Set<String> = [
        "オプション", "Options", "すべてのウインドウを表示", "すべてのウィンドウを表示", "Show All Windows",
        "隠す", "Hide", "表示", "Show", "終了", "Quit", "強制終了", "Force Quit",
        "非表示", "ほかを非表示", "ほかを隠す", "すべてを表示", "Hide Others", "Show All",
        "Finderに表示", "Finder に表示", "Show in Finder", "Dockから削除", "Dock から削除", "Remove from Dock",
        "開く", "Open", "Dockに追加", "Dock に追加", "Keep in Dock", "ログイン時に開く", "Open at Login",
    ]

    private static func systemDockItem(for url: URL) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let target = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        for list in root.children where list.role == kAXListRole {
            for item in list.children {
                guard let u: URL = item.attribute(kAXURLAttribute) else { continue }
                if u.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target { return item }
            }
        }
        return nil
    }

    private static func openSystemDockMenu(_ item: AXUIElement) async -> AXUIElement? {
        guard item.perform("AXShowMenu") else { return nil }
        for _ in 0..<15 {
            if let menu = item.children.first(where: { $0.role == kAXMenuRole }) { return menu }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    static func dockMenuTitles(for url: URL, excluding windowTitles: Set<String>) async -> [String] {
        let key = url.path
        if let cached = dockMenuCache[key], Date().timeIntervalSince(cached.at) < 60 {
            return cached.titles.filter { !windowTitles.contains($0) }
        }
        guard AXIsProcessTrusted(), let item = systemDockItem(for: url), let menu = await openSystemDockMenu(item) else { return [] }
        var titles: [String] = []
        for entry in menu.children where entry.role == kAXMenuItemRole {
            let title: String = entry.attribute(kAXTitleAttribute) ?? ""
            guard !title.isEmpty, !standardDockMenuTitles.contains(title),
                  entry.children.isEmpty,
                  (entry.attribute(kAXEnabledAttribute) as Bool?) ?? true
            else { continue }
            titles.append(title)
        }
        menu.perform(kAXCancelAction)
        dockMenuCache[key] = (titles, Date())
        return titles.filter { !windowTitles.contains($0) }
    }

    static func pressDockMenuItem(for url: URL, title: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard let item = systemDockItem(for: url), let menu = await openSystemDockMenu(item) else { return }
            if let entry = menu.children.first(where: { ($0.attribute(kAXTitleAttribute) as String?) == title }) {
                entry.perform(kAXPressAction)
            } else {
                menu.perform(kAXCancelAction)
            }
        }
    }

    // MARK: - Menu bar search

    struct MenuCommand: Identifiable {
        let id = UUID()
        let title: String
        let path: String
        let shortcut: String
        let element: AXUIElement
    }

    static func menuCommands(pid: pid_t) -> [MenuCommand] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = app.attribute(kAXMenuBarAttribute) else { return [] }
        var result: [MenuCommand] = []
        for top in bar.children.dropFirst() {
            let title: String = top.attribute(kAXTitleAttribute) ?? ""
            for menu in top.children { collect(menu, path: [title], depth: 0, into: &result) }
        }
        return result
    }

    private static func collect(_ menu: AXUIElement, path: [String], depth: Int, into result: inout [MenuCommand]) {
        guard depth < 3, result.count < 600 else { return }
        for item in menu.children {
            let title: String = item.attribute(kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { continue }
            let subs = item.children
            if let sub = subs.first, sub.role == kAXMenuRole {
                collect(sub, path: path + [title], depth: depth + 1, into: &result)
            } else if (item.attribute(kAXEnabledAttribute) as Bool?) ?? true {
                var shortcut = ""
                if let key: String = item.attribute(kAXMenuItemCmdCharAttribute), !key.isEmpty {
                    let mods: Int = item.attribute(kAXMenuItemCmdModifiersAttribute) ?? 0
                    shortcut = (mods & 4 != 0 ? "⌃" : "") + (mods & 2 != 0 ? "⌥" : "") + (mods & 1 != 0 ? "⇧" : "") + (mods & 8 == 0 ? "⌘" : "") + key
                }
                result.append(MenuCommand(title: title, path: path.joined(separator: " › "), shortcut: shortcut, element: item))
            }
        }
    }

    // MARK: - App search

    private static var installed: [URL]?

    static func searchApps(_ query: String) -> [URL] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if installed == nil {
            let fm = FileManager.default
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            installed = dirs.flatMap { dir in
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            }
        }
        func name(_ u: URL) -> String { FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "").lowercased() }
        return (installed ?? [])
            .filter { name($0).contains(q) }
            .sorted { (name($0).hasPrefix(q) ? 0 : 1, name($0)) < (name($1).hasPrefix(q) ? 0 : 1, name($1)) }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Power

    static func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }

    static func toggleDarkMode() {
        Task { _ = await AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    // MARK: - Trash（~/.Trash は保護されているので Finder に任せる）

    static func trashCount() async -> Int {
        Int(await AppleScript.run("tell application \"Finder\" to count items of trash") ?? "") ?? 0
    }

    static func emptyTrash() async {
        _ = await AppleScript.run("tell application \"Finder\" to empty trash")
    }
}

// MARK: - Audio output devices

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
}

enum AudioDevices {
    static func outputs() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
            return AudioDevice(id: id, name: n as String)
        }
    }

    static var defaultOutput: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var dev = id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
    }
}
