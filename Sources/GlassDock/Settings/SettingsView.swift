import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let router = SettingsRouter()

    func show(tab: SettingsTab = .general) {
        router.tab = tab
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(router: router)
                .environment(DockSettings.shared)
                .environment(DockModel.shared))
            // 中身から大きさを毎回計算し直さない（開いたままでも配置の再計算が続かないように）
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "GlassDock"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbar = NSToolbar(identifier: "settings")
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 860, height: 640))
            w.minSize = NSSize(width: 760, height: 520)
            w.center()
            window = w
            // 閉じている間も画面の更新や Timer が動き続けないよう、閉じたら中身ごと手放す（開いていたタブは router が覚えている）
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { SettingsWindowController.shared.windowWillClose() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func windowWillClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        DispatchQueue.main.async { self.window = nil }
    }
}

@Observable
final class SettingsRouter {
    var tab: SettingsTab = .general
    // 外観・アイコン・配置で編集するディスプレイ（nil なら共通の設定）
    var displayID: String?

    var targetSettings: DockSettings {
        displayID.map(DockSettings.settings(forDisplay:)) ?? .shared
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, displays, appearance, icons, widgets, preview, items, presets, permissions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: loc("一般")
        case .displays: loc("ディスプレイ")
        case .appearance: loc("外観")
        case .icons: loc("アイコン")
        case .widgets: loc("ウィジェット")
        case .preview: loc("プレビュー")
        case .items: loc("アイテム")
        case .presets: loc("プリセット")
        case .permissions: loc("権限")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .displays: "display.2"
        case .appearance: "paintpalette.fill"
        case .icons: "app.badge.fill"
        case .widgets: "square.grid.3x2.fill"
        case .preview: "rectangle.on.rectangle"
        case .items: "dock.rectangle"
        case .presets: "square.stack.3d.up.fill"
        case .permissions: "lock.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .displays: .cyan
        case .appearance: .pink
        case .icons: .blue
        case .widgets: .orange
        case .preview: .purple
        case .items: .teal
        case .presets: .indigo
        case .permissions: .green
        }
    }
}

struct SettingsView: View {
    @Bindable var router: SettingsRouter

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding<SettingsTab?>(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.color.gradient))
                }
                .tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ZStack {
                SettingsBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(router.tab.title)
                            .font(.system(size: 28, weight: .bold))
                            .padding(.top, 8)
                        page
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .animation(.smooth(duration: 0.25), value: router.tab)
        }
        .environment(router)
    }

    @ViewBuilder private var page: some View {
        switch router.tab {
        case .general: GeneralPage()
        case .displays: DisplaysPage()
        case .appearance: AppearancePage().environment(router.targetSettings)
        case .icons: IconsPage().environment(router.targetSettings)
        case .widgets: WidgetsPage()
        case .preview: PreviewPage()
        case .items: ItemsPage()
        case .presets: PresetsPage()
        case .permissions: PermissionsPage()
        }
    }
}

// ガラスの屈折が分かるよう、色のある背景を敷く
struct SettingsBackdrop: View {
    @Environment(DockSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = settings.tintStrength > 0.05 ? settings.tint : Color.accentColor
        let dark = scheme == .dark
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: [
                accent.opacity(dark ? 0.55 : 0.35), .purple.opacity(dark ? 0.45 : 0.25), .blue.opacity(dark ? 0.5 : 0.3),
                .indigo.opacity(dark ? 0.4 : 0.2), accent.opacity(dark ? 0.25 : 0.15), .pink.opacity(dark ? 0.4 : 0.25),
                .blue.opacity(dark ? 0.35 : 0.2), .teal.opacity(dark ? 0.35 : 0.2), .purple.opacity(dark ? 0.45 : 0.25),
            ]
        )
        .background(dark ? Color.black : Color.white)
        .ignoresSafeArea()
    }
}

// MARK: - Building blocks

struct GlassCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(loc(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            if let footer {
                Text(loc(footer))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGlass(cornerRadius: 22))
    }
}

struct Row<Control: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            }
            Text(loc(title))
            Spacer(minLength: 16)
            control
        }
        .frame(minHeight: 34)
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title) { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden() }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.0f"
    var scale = 1.0
    var step: Double?

    var body: some View {
        Row(title: title) {
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .frame(width: 220)
            // 訳や桁で幅が足りなくても「…」で切れないよう、最低幅だけ決めて必要なら広げる
            Text(String(format: loc(format), locale: .current, value * scale))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 56, alignment: .trailing)
        }
    }
}

struct OptionRow<T: LabeledOption>: View {
    let title: String
    @Binding var selection: T

    var body: some View {
        Row(title: title) {
            Picker(title, selection: $selection) {
                ForEach(Array(T.allCases)) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// 「Finder に表示」やフォルダを開くときに使うアプリ
private struct FileViewerRow: View {
    @Environment(DockSettings.self) private var settings
    @State private var candidates: [URL] = []
    private static let other = "\u{1}other"

    var body: some View {
        Row(title: "フォルダを開くアプリ") {
            Picker("フォルダを開くアプリ", selection: Binding(get: { settings.fileViewer }, set: select)) {
                Text(loc("自動（%@）", FileViewer.displayName(FileViewer.systemDefault))).tag("")
                Divider()
                ForEach(candidates, id: \.self) { url in
                    if let id = Bundle(url: url)?.bundleIdentifier {
                        Label {
                            Text(FileViewer.displayName(url))
                        } icon: {
                            Image(nsImage: Self.icon(url))
                        }
                        .tag(id)
                    }
                }
                Divider()
                Text("その他のアプリ…").tag(Self.other)
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear { candidates = FileViewer.candidates() }
    }

    private func select(_ id: String) {
        guard id == Self.other else {
            settings.fileViewer = id
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = loc("選択")
        guard panel.runModal() == .OK, let url = panel.url, let picked = Bundle(url: url)?.bundleIdentifier else { return }
        settings.fileViewer = picked
        candidates = FileViewer.candidates()
    }

    private static func icon(_ url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

struct RowDivider: View {
    var body: some View { Divider().opacity(0.5) }
}

// MARK: - Pages

private struct PlacementCard: View {
    @Environment(DockSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        GlassCard(title: "配置") {
            OptionRow(title: "位置", selection: $s.position)
            RowDivider()
            OptionRow(title: "スタイル", selection: $s.layoutStyle)
            RowDivider()
            SwitchRow(title: "自動的に隠す", isOn: $s.autoHide)
            if s.autoHide {
                RowDivider()
                SwitchRow(title: "MissionView を開いている間は表示", isOn: $s.stayOpenInMissionView)
            }
        }
    }
}

// 外観・アイコン・配置をどのディスプレイ向けに編集するかを選ぶ
struct DisplayScopeCard: View {
    @Environment(SettingsRouter.self) private var router
    @Environment(DockSettings.self) private var settings

    private var displays: [(id: String, name: String)] {
        var list = NSScreen.screens.map { screen -> (String, String) in
            let id = DockPanelController.screenID(screen)
            return (id, DockSettings.displayName(id))
        }
        // 外しているディスプレイでも、専用の設定があれば選べるようにする
        for id in DockSettings.shared.customDisplays where !list.contains(where: { $0.0 == id }) {
            list.append((id, loc("%@（未接続）", DockSettings.displayName(id))))
        }
        return list.map { (id: $0.0, name: $0.1) }
    }

    // メニューの幅は一番長い項目で決まるため、長い名前は縮めて行からはみ出さないようにする
    private static func short(_ name: String) -> String {
        name.count > 32 ? String(name.prefix(31)) + "…" : name
    }

    var body: some View {
        @Bindable var r = router
        let custom = DockSettings.shared.customDisplays
        GlassCard(title: "対象のディスプレイ",
                  footer: router.displayID == nil
                    ? "専用の設定にしていないすべてのディスプレイに適用されます。"
                    : custom.contains(router.displayID!) ? "このディスプレイだけの設定を編集しています。" : "このディスプレイは共通の設定を使っています。") {
            Row(title: "設定するディスプレイ") {
                Picker("", selection: $r.displayID) {
                    Text("すべて（共通）").tag(String?.none)
                    ForEach(displays, id: \.id) { d in
                        Text(custom.contains(d.id) ? loc("%@（専用）", Self.short(d.name)) : Self.short(d.name)).tag(Optional(d.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let id = router.displayID {
                RowDivider()
                SwitchRow(title: "このディスプレイ専用の設定を使う", isOn: Binding(
                    get: { custom.contains(id) },
                    set: { on in withAnimation(.smooth) { DockSettings.setCustom(on, display: id) } }
                ))
            }
        }
    }
}

// 起動時点の表示言語。変更後に別タブへ移っても「再起動して反映」を出し続けるためアプリ全体で持つ
private let launchLanguage = AppLanguage.current

private struct GeneralPage: View {
    @Environment(DockSettings.self) private var settings
    @Environment(SettingsRouter.self) private var router
    @Environment(DockModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage.current

    var body: some View {
        @Bindable var s = settings
        GlassCard(title: "言語", footer: language != launchLanguage ? "表示言語を切り替えるには GlassDock の再起動が必要です。" : nil) {
            Row(title: "表示言語") {
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: language) { _, l in l.apply() }
            }
            if language != launchLanguage {
                RowDivider()
                Row(title: "再起動して反映") { Button("GlassDock を再起動") { AppDelegate.relaunch() }.buttonStyle(.glass) }
            }
        }
        GlassCard(title: "Dock の表示") {
            SwitchRow(title: "左端にコントロールセンターを表示", isOn: $s.showControlCenter)
                .onChange(of: s.showControlCenter) { model.rebuild() }
        }
        DisplayScopeCard()
        PlacementCard().environment(router.targetSettings)
        GlassCard(title: "動作") {
            OptionRow(title: "前面のアプリをクリックしたとき", selection: $s.activeClickAction)
            RowDivider()
            SwitchRow(title: "起動中のアプリを表示", isOn: $s.showRunningApps)
                .onChange(of: s.showRunningApps) { model.rebuild() }
            RowDivider()
            SwitchRow(title: "通知バッジを表示", isOn: $s.showBadges)
                .onChange(of: s.showBadges) { model.updateBadgeTimer() }
            RowDivider()
            SwitchRow(title: "起動中にアイコンを弾ませる", isOn: $s.launchBounce)
            RowDivider()
            SwitchRow(title: "Option+Tab でウィンドウを切り替え", isOn: $s.windowSwitcherEnabled)
            RowDivider()
            FileViewerRow()
            RowDivider()
            SliderRow(title: "アニメーション速度", value: $s.animationSpeed, range: 0.5...2.0, format: "%.1f×", step: 0.1)
        }
        GlassCard(title: "macOS", footer: "標準 Dock の「自動的に隠す」を有効にして表示を遅らせます。オフにするか GlassDock を終了すると元の設定に戻ります。") {
            SwitchRow(title: "macOS の Dock を隠す", isOn: $s.hideSystemDock)
                .onChange(of: s.hideSystemDock) { _, v in SystemDock.setHidden(v) }
            RowDivider()
            SwitchRow(title: "ログイン時に起動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    do {
                        if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            RowDivider()
            Row(title: "サイズと見た目を macOS の Dock に合わせる") {
                Button("合わせる") { withAnimation(.smooth) { settings.matchSystemDock() } }
                    .buttonStyle(.glass)
            }
        }
        UpdateCard()
    }
}

private struct UpdateCard: View {
    @State private var updates = UpdateController.shared

    var body: some View {
        GlassCard(title: "アップデート", footer: UpdateController.isConfigured
                  ? "新しいバージョンは GitHub のリリースから取得し、署名を検証してから適用します。"
                  : "このビルドにはアップデート用の署名鍵が含まれていないため、自動アップデートは無効です。") {
            Row(title: "バージョン") { Text(UpdateController.version).foregroundStyle(.secondary).monospacedDigit() }
            if UpdateController.isConfigured {
                RowDivider()
                SwitchRow(title: "アップデートを自動的に確認", isOn: $updates.automaticallyChecks)
                RowDivider()
                Row(title: "今すぐ確認") {
                    Button("アップデートを確認…") { updates.checkForUpdates() }.buttonStyle(.glass)
                }
            }
        }
    }
}

struct DockPreviewMini: View {
    @Environment(DockSettings.self) private var settings
    @Environment(DockModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let items = Array(model.items.filter { if case .app = $0.kind { return true } else { return false } }.prefix(7))
        let size: CGFloat = min(CGFloat(settings.iconSize), 46)
        let pad = max(4, size * 0.25 * CGFloat(settings.paddingScale))
        let thickness = size + pad * 2
        HStack(spacing: CGFloat(settings.spacing)) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                miniIcon(item, size: size, pad: pad)
                if i == 3 && settings.dividerStyle == .line {
                    Capsule().fill(.primary.opacity(0.22)).frame(width: 1, height: size * 0.7)
                }
            }
        }
        .padding(pad)
        .background {
            DockSurface(cornerRadius: settings.layoutStyle == .taskbar ? 6 : thickness * CGFloat(settings.cornerRatio))
        }
        .environment(\.colorScheme, scheme)
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background {
            ZStack {
                LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.yellow.opacity(0.7)).frame(width: 120).offset(x: -160, y: -30).blur(radius: 20)
                Circle().fill(.cyan.opacity(0.6)).frame(width: 160).offset(x: 170, y: 40).blur(radius: 24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("プレビュー")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(AppGlass(cornerRadius: 11))
                .padding(12)
        }
    }

    private var scheme: ColorScheme {
        switch settings.appearanceMode {
        case .light: .light
        case .dark: .dark
        case .system: systemScheme
        }
    }

    private func miniIcon(_ item: DockItem, size: CGFloat, pad: CGFloat) -> some View {
        let image = Image(nsImage: model.icon(for: item)).resizable()
        return Group {
            switch settings.iconStyle {
            case .original: image
            case .monochrome: image.saturation(0).contrast(1.1)
            case .tinted: image.saturation(0).brightness(0.15).colorMultiply(settings.iconTint)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            if item.isRunning, [.dot, .bar, .glow].contains(settings.indicator) {
                Capsule().fill(settings.indicatorColor.opacity(0.8))
                    .frame(width: settings.indicator == .dot ? 4 : size * 0.4, height: settings.indicator == .glow ? 3 : 4)
                    .shadow(color: settings.indicator == .glow ? settings.indicatorColor : .clear, radius: 5)
                    .offset(y: pad / 2 + 2)
            }
        }
    }
}

private struct AppearancePage: View {
    @Environment(DockSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        DisplayScopeCard()
        DockPreviewMini()
        GlassCard(title: "プリセット") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(DockPreset.all) { PresetChip(preset: $0) }
                }
                .padding(.vertical, 8)
            }
        }
        GlassCard(title: "素材") {
            OptionRow(title: "背景", selection: $s.material)
            RowDivider()
            OptionRow(title: "外観モード", selection: $s.appearanceMode)
            RowDivider()
            Row(title: "色") { ColorPicker("", selection: $s.tint, supportsOpacity: false).labelsHidden() }
            RowDivider()
            SliderRow(title: "色の濃さ", value: $s.tintStrength, range: 0...1, format: "%.0f%%", scale: 100)
            RowDivider()
            SliderRow(title: "ダークモード時の透明度", value: $s.darkTransparency, range: 0...0.6, format: "%.0f%%", scale: 100)
        }
        GlassCard(title: "形") {
            SliderRow(title: "角の丸み", value: $s.cornerRatio, range: 0...0.5, format: "%.0f%%", scale: 200)
            RowDivider()
            SliderRow(title: "内側の余白", value: $s.paddingScale, range: 0.4...2, format: "%.1f×")
            RowDivider()
            SliderRow(title: "枠線の太さ", value: $s.borderWidth, range: 0...3, format: "%.1f pt")
            if s.borderWidth > 0 {
                RowDivider()
                SliderRow(title: "枠線の濃さ", value: $s.borderOpacity, range: 0...1, format: "%.0f%%", scale: 100)
            }
            RowDivider()
            SliderRow(title: "影", value: $s.shadowStrength, range: 0...1, format: "%.0f%%", scale: 100)
            RowDivider()
            OptionRow(title: "区切り", selection: $s.dividerStyle)
        }
    }
}

private struct PresetChip: View {
    let preset: DockPreset
    @Environment(DockSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        let radius = preset.layoutStyle == .taskbar ? 2 : 22 * preset.cornerRatio
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = preset.tintStrength > 0 ? Color(hex: preset.tintHex).opacity(preset.tintStrength) : nil
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 4) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill([Color.blue, .green, .orange, .red][i].gradient)
                            .saturation(preset.iconStyle == .monochrome ? 0 : 1)
                            .frame(width: 12, height: 12)
                    }
                }
                .frame(width: preset.layoutStyle == .taskbar ? 104 : 80, height: 22)
                .background {
                    if preset.material == .solid {
                        shape.fill(Color(hex: preset.tintHex).opacity(0.3 + preset.tintStrength * 0.7))
                    } else {
                        Color.clear.glassEffect((preset.material == .clearGlass ? Glass.clear : .regular).tint(tint), in: shape)
                    }
                }
                .padding(.bottom, preset.layoutStyle == .taskbar ? 0 : 6)
            }
            .frame(width: 104, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(hovering ? 1.05 : 1)
            Text(preset.name).font(.system(size: 11, weight: .medium))
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        .onTapGesture { withAnimation(.smooth) { settings.apply(preset) } }
    }
}

private struct IconsPage: View {
    @Environment(DockSettings.self) private var settings
    @Environment(DockModel.self) private var model

    var body: some View {
        @Bindable var s = settings
        DisplayScopeCard()
        DockPreviewMini()
        GlassCard(title: "サイズ") {
            SliderRow(title: "アイコン", value: $s.iconSize, range: 20...110, format: "%.0f pt")
            RowDivider()
            SliderRow(title: "間隔", value: $s.spacing, range: 0...24, format: "%.0f pt")
        }
        GlassCard(title: "拡大") {
            OptionRow(title: "スタイル", selection: $s.magnificationStyle)
            if s.magnification {
                RowDivider()
                SliderRow(title: "拡大サイズ", value: $s.magnifiedSize, range: s.iconSize...180, format: "%.0f pt")
                RowDivider()
                SliderRow(title: "範囲", value: $s.magnificationRange, range: 1.5...5, format: "%.1f")
            }
            RowDivider()
            OptionRow(title: "ホバー効果", selection: $s.hoverEffect)
        }
        GlassCard(title: "スタイル") {
            OptionRow(title: "アイコン", selection: $s.iconStyle)
            if s.iconStyle == .tinted {
                RowDivider()
                Row(title: "アイコンの色") { ColorPicker("", selection: $s.iconTint, supportsOpacity: false).labelsHidden() }
            }
            RowDivider()
            SwitchRow(title: "起動していないアプリを薄く", isOn: $s.dimInactive)
            RowDivider()
            SwitchRow(title: "最小化中・非表示中のアプリを薄く", isOn: $s.dimMinimized)
            RowDivider()
            SwitchRow(title: "アイコンに影", isOn: $s.iconShadow)
            RowDivider()
            SwitchRow(title: "名前を常に表示", isOn: $s.alwaysShowLabels)
        }
        GlassCard(title: "インジケータとバッジ") {
            OptionRow(title: "起動中の表示", selection: $s.indicator)
            RowDivider()
            SwitchRow(title: "ウィンドウの数だけ丸を表示（最大3つ）", isOn: $s.indicatorShowsWindowCount)
            RowDivider()
            Row(title: "インジケータの色") {
                if !s.indicatorHex.isEmpty {
                    Button("自動に戻す") { s.indicatorHex = "" }.buttonStyle(.borderless)
                }
                ColorPicker("", selection: $s.indicatorColor, supportsOpacity: false).labelsHidden()
            }
            RowDivider()
            Row(title: "バッジの色") { ColorPicker("", selection: $s.badgeColor, supportsOpacity: false).labelsHidden() }
        }
    }
}

private struct PreviewPage: View {
    @Environment(DockSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        GlassCard(title: "ウィンドウプレビュー", footer: "サムネイルをクリックするとそのウィンドウを前面に出します。ホバーで最小化・閉じるボタンが出ます。") {
            SwitchRow(title: "ホバーでウィンドウをプレビュー", isOn: $s.previewEnabled)
            RowDivider()
            SwitchRow(title: "ライブ更新（表示中のみ 1 秒ごと）", isOn: $s.livePreview)
            RowDivider()
            SliderRow(title: "サムネイルの大きさ", value: $s.previewSize, range: 140...360, format: "%.0f pt")
            RowDivider()
            SliderRow(title: "表示までの時間", value: $s.previewDelay, range: 0...0.8, format: "%.2f 秒")
        }
    }
}

private struct WidgetsPage: View {
    @Environment(DockSettings.self) private var settings
    @Environment(DockModel.self) private var model
    @State private var newZone = "Asia/Tokyo"

    var body: some View {
        @Bindable var s = settings
        GlassCard(title: "Dock に並んでいるウィジェット", footer: "チップをドラッグして並べ替えられます。Dock 上でもドラッグで移動、上へドラッグで削除できます。") {
            placed(leading: true)
            RowDivider()
            placed(leading: false)
        }
        ForEach(WidgetCategory.allCases) { category in
            GlassCard(title: category.label) {
                let kinds = WidgetKind.allCases.filter { $0.category == category }
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    if i > 0 { RowDivider() }
                    WidgetRow(kind: kind)
                }
            }
        }
        GlassCard(title: "天気", footer: "天気データは Open-Meteo から取得します（緯度・経度を送信します）。") {
            SwitchRow(title: "現在地を使う", isOn: $s.useCurrentLocation)
            RowDivider()
            Row(title: s.useCurrentLocation ? "取得できないときの都市" : "都市") {
                TextField("例: 東京", text: $s.weatherCity)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { WidgetHub.shared.weather.refresh() }
            }
            RowDivider()
            OptionRow(title: "単位", selection: $s.temperatureUnit)
                .onChange(of: s.temperatureUnit) { WidgetHub.shared.weather.refresh() }
            RowDivider()
            Row(title: "今すぐ更新") { Button("更新") { WidgetHub.shared.weather.refresh() }.buttonStyle(.glass) }
        }
        GlassCard(title: "時計") {
            SwitchRow(title: "24時間表示", isOn: $s.clock24h)
            RowDivider()
            SwitchRow(title: "秒を表示", isOn: $s.clockSeconds)
            ForEach(s.worldClocks, id: \.self) { id in
                RowDivider()
                Row(title: TimeZone(identifier: id).map(WorldClock.city) ?? id, symbol: "globe") {
                    Text(id).foregroundStyle(.secondary).font(.system(size: 11))
                    Button { s.worldClocks.removeAll { $0 == id } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            RowDivider()
            Row(title: "世界時計を追加") {
                Picker("", selection: $newZone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
                Button("追加") { if !s.worldClocks.contains(newZone) { s.worldClocks.append(newZone) } }.buttonStyle(.glass)
            }
        }
        GlassCard(title: "ポモドーロ") {
            SliderRow(title: "集中", value: $s.focusMinutes, range: 5...90, format: "%.0f 分", step: 5)
            RowDivider()
            SliderRow(title: "休憩", value: $s.breakMinutes, range: 1...30, format: "%.0f 分", step: 1)
        }
    }

    private func placed(leading: Bool) -> some View {
        let list = leading ? model.leadingWidgets : model.trailingWidgets
        return VStack(alignment: .leading, spacing: 6) {
            Text(leading ? loc("左端") : loc("右端")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if list.isEmpty {
                Text("なし").font(.system(size: 12)).foregroundStyle(.tertiary).frame(minHeight: 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(list) { kind in
                            HStack(spacing: 6) {
                                Image(systemName: kind.symbol)
                                Text(loc(kind.title))
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    .onTapGesture { withAnimation(.smooth) { model.remove(.widget(kind)) } }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(AppGlass(cornerRadius: 14))
                            .draggable(kind.rawValue)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, let src = WidgetKind(rawValue: id),
                                      let from = list.firstIndex(of: src), let to = list.firstIndex(of: kind) else { return false }
                                withAnimation(.smooth) { model.moveWidgets(leading: leading, from: IndexSet(integer: from), to: to > from ? to + 1 : to) }
                                return true
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct WidgetRow: View {
    let kind: WidgetKind
    @Environment(DockModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            WidgetTile(kind: kind, size: 44)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(kind.title)).font(.system(size: 13, weight: .medium))
                Text(loc(kind.summary)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.hasWidget(kind) {
                Picker("", selection: Binding(
                    get: { model.leadingWidgets.contains(kind) },
                    set: { model.setWidget(kind, leading: $0) }
                )) {
                    Text("左端").tag(true)
                    Text("右端").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Button("削除") { withAnimation(.smooth) { model.remove(.widget(kind)) } }
                    .buttonStyle(.glass)
            } else {
                Button("追加", systemImage: "plus") { withAnimation(.smooth) { model.addWidget(kind) } }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ItemsPage: View {
    @Environment(DockModel.self) private var model
    @Environment(DockSettings.self) private var settings

    var body: some View {
        GlassCard(title: "アプリ", footer: "ドラッグで並べ替えられます。アイコンは PNG や ICNS などの画像に差し替えられます。") {
            row(.app(url: DockModel.finderURL, pinned: true), removable: false)
            ForEach(model.pinnedApps, id: \.self) { url in
                RowDivider()
                row(.app(url: url, pinned: true))
                    .draggable(url.path)
                    .dropDestination(for: String.self) { paths, _ in
                        return reorder(paths.first, onto: url.path, in: model.pinnedApps.map(\.path)) { model.movePinnedApps(from: $0, to: $1) }
                    }
            }
        }
        GlassCard(title: "フォルダとゴミ箱", footer: "スイッチをオフにすると、固定したまま Dock から隠せます。") {
            ForEach(Array(model.pinnedFolders.enumerated()), id: \.element) { i, url in
                if i > 0 { RowDivider() }
                row(.folder(url: url), visible: Binding(
                    get: { !settings.hiddenFolders.contains(url.path) },
                    set: { show in
                        if show { settings.hiddenFolders.removeAll { $0 == url.path } } else { settings.hiddenFolders.append(url.path) }
                        withAnimation(.smooth) { model.rebuild() }
                    }
                ))
                .draggable(url.path)
                .dropDestination(for: String.self) { paths, _ in
                    return reorder(paths.first, onto: url.path, in: model.pinnedFolders.map(\.path)) { model.movePinnedFolders(from: $0, to: $1) }
                }
            }
            if !model.pinnedFolders.isEmpty { RowDivider() }
            row(.trash, removable: false, iconChange: false, visible: Binding(
                get: { settings.showTrash },
                set: { settings.showTrash = $0; withAnimation(.smooth) { model.rebuild() } }
            ))
        }
        GlassCard(title: "ウィジェット", footer: "Dock 上でもドラッグで並べ替え、上へドラッグで削除できます。") {
            let placed = model.leadingWidgets.map { ($0, true) } + model.trailingWidgets.map { ($0, false) }
            if placed.isEmpty {
                Text("ウィジェットは置かれていません").font(.system(size: 12)).foregroundStyle(.secondary).frame(minHeight: 40)
            }
            ForEach(Array(placed.enumerated()), id: \.element.0) { i, entry in
                if i > 0 { RowDivider() }
                HStack(spacing: 12) {
                    WidgetTile(kind: entry.0, size: 34)
                        .frame(width: 72, alignment: .leading)
                    Text(loc(entry.0.title))
                    Spacer()
                    Picker("", selection: Binding(get: { entry.1 }, set: { model.setWidget(entry.0, leading: $0) })) {
                        Text("左端").tag(true)
                        Text("右端").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button { withAnimation(.smooth) { model.remove(.widget(entry.0)) } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            RowDivider()
            HStack {
                Menu("ウィジェットを追加") {
                    ForEach(WidgetCategory.allCases) { category in
                        Section(loc(category.label)) {
                            ForEach(WidgetKind.allCases.filter { $0.category == category && !model.hasWidget($0) }) { kind in
                                Button(loc(kind.title), systemImage: kind.symbol) { withAnimation(.smooth) { model.addWidget(kind) } }
                            }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Button("ウィジェットの設定…") { SettingsWindowController.shared.show(tab: .widgets) }
                    .buttonStyle(.borderless)
            }
            .frame(minHeight: 40)
        }
        HStack {
            Button("追加…", systemImage: "plus") { add() }.buttonStyle(.glassProminent)
            Spacer()
            Button("macOS の Dock から読み込む") { model.importFromSystemDock() }.buttonStyle(.glass)
        }
    }

    private func reorder(_ source: String?, onto target: String, in list: [String], move: (IndexSet, Int) -> Void) -> Bool {
        guard let source, let from = list.firstIndex(of: source), let to = list.firstIndex(of: target) else { return false }
        withAnimation(.smooth) { move(IndexSet(integer: from), to > from ? to + 1 : to) }
        return true
    }

    private func row(_ item: DockItem, removable: Bool = true, iconChange: Bool = true, visible: Binding<Bool>? = nil) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon(for: item)).resizable().frame(width: 28, height: 28)
                .opacity(visible?.wrappedValue == false ? 0.4 : 1)
            Text(item.name)
                .foregroundStyle(visible?.wrappedValue == false ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.name)
            Spacer()
            if iconChange {
                Button("アイコン変更") { model.chooseCustomIcon(for: item) }.buttonStyle(.borderless).fixedSize()
                if model.customIcons[model.iconKey(for: item)] != nil {
                    Button("元に戻す") { model.setCustomIcon(nil, for: item) }.buttonStyle(.borderless).fixedSize()
                }
            }
            if let visible {
                Toggle("表示", isOn: visible).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("Dock に表示")
            }
            if removable {
                Button { withAnimation(.smooth) { model.remove(item) } } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 40)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK { model.addToDock(panel.urls) }
    }
}

private struct PermissionsPage: View {
    @State private var ax = Permissions.accessibility
    @State private var sr = Permissions.screenRecording
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GlassCard(title: "必須", footer: "画面収録は許可後に GlassDock の再起動が必要な場合があります。") {
            permission("アクセシビリティ", "ウィンドウの切り替え・最小化・閉じる、バッジの取得に使います。", ax) {
                Permissions.requestAccessibility()
            }
            RowDivider()
            permission("画面収録", "ウィンドウのサムネイルとタイトルの取得に使います。", sr) {
                Permissions.requestScreenRecording()
            }
            if !sr {
                RowDivider()
                Row(title: "許可したあとに") { Button("GlassDock を再起動") { AppDelegate.relaunch() }.buttonStyle(.glass) }
            }
        }
        GlassCard(title: "ウィジェット用（そのウィジェットを追加したときだけ確認されます）") {
            Row(title: "カレンダー・リマインダー", symbol: "calendar") { Text("予定・リマインダー").foregroundStyle(.secondary) }
            RowDivider()
            Row(title: "位置情報", symbol: "location") { Text("天気").foregroundStyle(.secondary) }
            RowDivider()
            Row(title: "オートメーション", symbol: "music.note") { Text("再生中の曲").foregroundStyle(.secondary) }
        }
        .onReceive(timer) { _ in
            ax = Permissions.accessibility
            sr = Permissions.screenRecording
        }
    }

    private func permission(_ title: String, _ detail: String, _ granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(title)).font(.headline)
                Text(loc(detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("許可する", action: request).buttonStyle(.glassProminent) }
        }
        .padding(.vertical, 8)
    }
}
