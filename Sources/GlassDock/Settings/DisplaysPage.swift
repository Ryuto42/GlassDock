import SwiftUI

// 接続中のディスプレイと、以前つないだディスプレイの一覧。表示・専用の設定・名前・削除をここで編集する
struct DisplaysPage: View {
    @Environment(DockSettings.self) private var settings
    @State private var screens = NSScreen.screens
    // 名前は UserDefaults に直接書くため、変えたら描き直す
    @State private var revision = 0

    private struct Entry: Identifiable {
        let id: String
        let screen: NSScreen?
        let isMain: Bool
    }

    private var entries: [Entry] {
        let connected = screens.enumerated().map { i, screen in
            Entry(id: DockPanelController.screenID(screen), screen: screen, isMain: i == 0)
        }
        let ids = Set(connected.map(\.id))
        let others = DockSettings.knownDisplays.filter { !ids.contains($0) }
            .sorted { DockSettings.displayName($0).localizedStandardCompare(DockSettings.displayName($1)) == .orderedAscending }
            .map { Entry(id: $0, screen: nil, isMain: false) }
        return connected + others
    }

    var body: some View {
        @Bindable var s = settings
        let _ = revision
        GlassCard(title: "Dock の表示", footer: "オフにすると、メインのディスプレイにだけ Dock を表示します。") {
            SwitchRow(title: "外部ディスプレイにも表示", isOn: $s.showOnAllDisplays)
        }
        GlassCard(title: "ディスプレイ",
                  footer: "未接続のディスプレイは、専用の設定や名前を覚えているものです。削除すると一覧から消え、次につないだときは共通の設定で表示します。") {
            let list = entries
            ForEach(Array(list.enumerated()), id: \.element.id) { i, entry in
                if i > 0 { RowDivider() }
                DisplayRow(id: entry.id, screen: entry.screen, isMain: entry.isMain) { revision += 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

private struct DisplayRow: View {
    let id: String
    let screen: NSScreen?
    let isMain: Bool
    let changed: () -> Void
    @Environment(DockSettings.self) private var settings
    @Environment(SettingsRouter.self) private var router
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var confirmReset = false

    private var connected: Bool { screen != nil }
    private var custom: Bool { settings.customDisplays.contains(id) }
    private var shown: Bool { !settings.hiddenDisplays.contains(id) }
    // 「外部ディスプレイにも表示」がオフなら、メイン以外には出ない
    private var effectivelyShown: Bool { shown && (isMain || settings.showOnAllDisplays) }

    private var isBuiltIn: Bool {
        UInt32(id).map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 18))
                .foregroundStyle(connected ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(DockSettings.displayName(id)).font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(DockSettings.displayName(id))
                HStack(spacing: 5) {
                    tag(connected ? "接続中" : "未接続", color: connected ? .green : .gray)
                    if isMain { tag("メイン", color: .blue) }
                    tag(custom ? "専用の設定" : "共通の設定", color: custom ? .purple : .gray)
                    if connected, !effectivelyShown { tag("Dock なし", color: .orange) }
                    if let screen {
                        // 幅が足りないときは解像度から縮める
                        Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { shown }, set: { on in
                withAnimation(.smooth) {
                    if on { settings.hiddenDisplays.removeAll { $0 == id } } else { settings.hiddenDisplays.append(id) }
                }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("このディスプレイに Dock を表示")
            menu
        }
        .frame(minHeight: 48)
        .alert("名前を変更", isPresented: $renaming) {
            TextField(DockSettings.systemDisplayName(id) ?? loc("名前"), text: $draft)
            Button("変更") {
                DockSettings.rename(display: id, to: draft)
                changed()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("空にすると macOS の名前に戻ります。")
        }
        .alert(loc("「%@」を削除しますか？", DockSettings.displayName(id)), isPresented: $confirmDelete) {
            Button("削除", role: .destructive) {
                if router.displayID == id { router.displayID = nil }
                withAnimation(.smooth) { DockSettings.forget(display: id) }
                changed()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(connected
                 ? loc("専用の設定と名前を消し、共通の設定で表示します。")
                 : loc("専用の設定と名前を消し、一覧から外します。"))
        }
        .alert("共通の設定に戻しますか？", isPresented: $confirmReset) {
            Button("戻す", role: .destructive) {
                if router.displayID == id { router.displayID = nil }
                withAnimation(.smooth) { DockSettings.setCustom(false, display: id) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このディスプレイだけの設定を消します。")
        }
    }

    private var menu: some View {
        Menu {
            Toggle("このディスプレイ専用の設定を使う", isOn: Binding(get: { custom }, set: { on in
                withAnimation(.smooth) { DockSettings.setCustom(on, display: id) }
            }))
            Button("配置を編集…") { edit(.general) }
            Button("外観を編集…") { edit(.appearance) }
            Button("アイコンを編集…") { edit(.icons) }
            Divider()
            Button("名前を変更…") {
                draft = DockSettings.displayName(id)
                renaming = true
            }
            if custom {
                Button("共通の設定に戻す…") { confirmReset = true }
            }
            Divider()
            Button(connected ? loc("設定と名前を削除…") : loc("削除…"), role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // 専用の設定がなければ作ってから、そのディスプレイを対象にして各ページを開く
    private func edit(_ tab: SettingsTab) {
        if !custom { DockSettings.setCustom(true, display: id) }
        router.displayID = id
        router.tab = tab
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(loc(text))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color == .gray ? Color.secondary : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }
}
