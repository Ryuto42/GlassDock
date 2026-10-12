import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = DockSettings.shared
        if settings.hideSystemDock { SystemDock.setHidden(true) }
        // 前回クラッシュなどで元に戻せなかった場合は、ここで標準 Dock を戻す
        if !settings.hideSystemDock, SystemDock.hasSavedState { SystemDock.setHidden(false) }

        _ = DockModel.shared
        DockPanelController.shared.start()
        setupStatusItem()
        UpdateController.shared.start()
        WindowSwitcher.shared.start()

        // kill などで終了されたときも標準 Dock の設定を戻す
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        if !Permissions.allGranted {
            SettingsWindowController.shared.show(tab: .permissions)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SystemDock.hasSavedState { SystemDock.setHidden(false) }
        DockPanelController.shared.unpublishReservedAreas()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "GlassDock")
        let menu = NSMenu()
        menu.addItem(withTitle: loc("設定…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: loc("ウィジェットを追加…"), action: #selector(openWidgets), keyEquivalent: "").target = self
        menu.addItem(withTitle: loc("Dock を表示/隠す"), action: #selector(toggleAutoHide), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if UpdateController.isConfigured {
            menu.addItem(withTitle: loc("アップデートを確認…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: loc("GlassDock について"), action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: loc("GlassDock を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openWidgets() { SettingsWindowController.shared.show(tab: .widgets) }

    @objc private func toggleAutoHide() { DockSettings.shared.autoHide.toggle() }

    @objc private func checkForUpdates() { UpdateController.shared.checkForUpdates() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: loc("Liquid Glass のカスタム Dock") + "\nhttps://github.com/Ryuto42/GlassDock\nGPL-3.0",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // パスはシェル文字列に埋め込まず、引数（$0）として渡す
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
