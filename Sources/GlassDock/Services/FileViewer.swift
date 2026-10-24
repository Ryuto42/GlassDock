import AppKit

// フォルダを開く・ファイルを表示するアプリ。設定で選んだもの、未設定なら macOS の既定（NSFileViewer かフォルダの既定のアプリ）
@MainActor
enum FileViewer {
    static let finderID = "com.apple.finder"

    private static let knownIDs = [
        "com.binarynights.ForkLift", "com.binarynights.ForkLift-3", "com.cocoatech.PathFinder",
        "com.jinghaoshe.qspace", "com.jinghaoshe.qspace.pro", "com.eltima.cmd1", "com.eltima.cmd1.pro",
        "org.yanex.marta", "info.filesmanager.Files", "io.fman.fman", "com.mac-ftp.Transmit",
    ]

    static var appURL: URL {
        let chosen = DockSettings.shared.fileViewer
        if !chosen.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) { return url }
        return systemDefault
    }

    static var isFinder: Bool { Bundle(url: appURL)?.bundleIdentifier == finderID }

    static var name: String { displayName(appURL) }

    static func open(_ folder: URL) {
        if isFinder {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: activating)
        }
    }

    // ファイルを渡すと、多くのファイル管理アプリはそのフォルダを開いて選択する。
    // フォルダや .app を渡すと中を開いてしまうので、その場合は親フォルダを開く
    static func reveal(_ url: URL) {
        if isFinder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let target = isDirectory ? url.deletingLastPathComponent() : url
            NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: activating)
        }
    }

    // フォルダならファイル管理アプリで開き、それ以外は既定のアプリで開く（.app などのパッケージは除く）
    static func openItem(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { open(url) } else { NSWorkspace.shared.open(url) }
    }

    static var systemDefault: URL {
        let workspace = NSWorkspace.shared
        if let id = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "NSFileViewer"),
           let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        return workspace.urlForApplication(toOpen: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) ?? DockModel.finderURL
    }

    // 設定の候補：Finder、既知のファイル管理アプリ、ボリュームも開けると宣言しているアプリ、macOS の既定、選択中のアプリ
    static func candidates() -> [URL] {
        let workspace = NSWorkspace.shared
        var urls = [DockModel.finderURL]
        urls += knownIDs.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let folder = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        urls += workspace.urlsForApplications(toOpen: folder).filter { isInstalled($0) && opensVolumes($0) }
        urls.append(systemDefault)
        let chosen = DockSettings.shared.fileViewer
        if !chosen.isEmpty, let url = workspace.urlForApplication(withBundleIdentifier: chosen) { urls.append(url) }
        var seen = Set<String>()
        return urls.filter { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return seen.insert(id).inserted
        }
    }

    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static var activating: NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return config
    }

    private static func isInstalled(_ app: URL) -> Bool {
        ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { app.path.hasPrefix($0) }
    }

    private static func opensVolumes(_ app: URL) -> Bool {
        let types = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.volume") == true }
    }
}
