import CoreAudio
import QuickLookThumbnailing
import SwiftUI

// MARK: - Shared parts

struct PanelHeader: View {
    let icon: NSImage?
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(loc(title)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(loc(subtitle)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(loc(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .onTapGesture { text = "" }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

struct ActionTile: View {
    let symbol: String
    let title: String
    var destructive = false
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(height: 18)
            Text(loc(title))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(destructive ? AnyShapeStyle(.red) : active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(hovering ? 0.14 : 0.07)))
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
        .onTapGesture(perform: action)
    }
}

struct MenuRow: View {
    let symbol: String?
    let title: String
    var detail: String?
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(hovering ? .white : destructive ? .red : .secondary)
            }
            Text(loc(title)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(hovering ? .white : destructive ? .red : .primary)
            Spacer(minLength: 6)
            if let detail {
                Text(loc(detail)).font(.system(size: 11)).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.85) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - Context menu

@Observable
final class MenuSearch {
    var query = ""
    @ObservationIgnored private var cache: (pid: pid_t, commands: [AppActions.MenuCommand])?

    func commands(pid: pid_t) -> [AppActions.MenuCommand] {
        if cache?.pid != pid { cache = (pid, AppActions.menuCommands(pid: pid)) }
        return cache?.commands ?? []
    }

    func reset() {
        query = ""
        cache = nil
    }
}

struct ContextMenuPanel: View {
    let item: DockItem
    let state: PreviewState
    @Environment(DockModel.self) private var model
    @State private var confirmForceQuit = false
    private let controller = PreviewController.shared

    var body: some View {
        let search = controller.menuSearch
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(icon: icon, title: item.name, subtitle: subtitle)
            if !state.dockMenu.isEmpty, case .app(let url) = item.kind {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.dockMenu, id: \.self) { title in
                        MenuRow(symbol: Self.symbol(for: title), title: title) {
                            run { AppActions.pressDockMenuItem(for: url, title: title) }
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let app = item.runningApp {
                SearchField(prompt: "ウィンドウやメニューを検索", text: Binding(get: { search.query }, set: { search.query = $0 }))
                if search.query.isEmpty {
                    windowList(app)
                    actionGrid(app)
                } else {
                    searchResults(app, query: search.query)
                }
            } else {
                staticActions
            }
            Divider().opacity(0.5)
            secondaryRows
        }
        .frame(width: 290)
    }

    private var icon: NSImage? {
        item.widgetKind == nil ? model.icon(for: item) : nil
    }

    private var subtitle: String? {
        switch item.kind {
        case .app:
            if item.runningApp != nil {
                return state.windows.isEmpty ? "実行中" : loc("実行中・ウィンドウ %d", state.windows.count)
            }
            return item.isPinned ? "Dock に固定" : nil
        case .folder: return "フォルダ"
        case .trash: return "ゴミ箱"
        case .widget: return "ウィジェット"
        default: return nil
        }
    }

    @ViewBuilder private func windowList(_ app: NSRunningApplication) -> some View {
        if !state.windows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("ウィンドウ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(state.windows.prefix(6)) { w in
                    MenuRow(symbol: w.isMinimized ? "minus.square" : "macwindow",
                            title: w.title.isEmpty ? loc("名称未設定") : w.title,
                            detail: w.isMinimized ? loc("最小化中") : nil) {
                        controller.focus(w)
                    }
                }
            }
        }
    }

    private func actionGrid(_ app: NSRunningApplication) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ActionTile(symbol: "plus.rectangle.on.rectangle", title: "新規ウインドウ") { run { AppActions.newWindow(app) } }
            ActionTile(symbol: "minus.rectangle", title: "すべて最小化") { run { WindowService.shared.minimizeAll(pid: app.processIdentifier) } }
            ActionTile(symbol: "xmark.rectangle", title: "すべて閉じる") { run { AppActions.closeAll(app) } }
            ActionTile(symbol: app.isHidden ? "eye" : "eye.slash", title: app.isHidden ? "表示" : "隠す") {
                run { if app.isHidden { app.unhide() } else { app.hide() } }
            }
            ActionTile(symbol: "arrow.clockwise", title: "再起動") { run { AppActions.relaunch(app) } }
            ActionTile(symbol: "power", title: "終了", destructive: true) { run { app.terminate() } }
        }
    }

    @ViewBuilder private func searchResults(_ app: NSRunningApplication, query: String) -> some View {
        let q = query.lowercased()
        let windows = state.windows.filter { $0.title.lowercased().contains(q) }.prefix(4)
        let commands = controller.menuSearch.commands(pid: app.processIdentifier)
            .filter { $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .prefix(8)
        VStack(alignment: .leading, spacing: 0) {
            if !windows.isEmpty {
                Text("ウィンドウ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(Array(windows)) { w in
                    MenuRow(symbol: "macwindow", title: w.title) { controller.focus(w) }
                }
            }
            if !commands.isEmpty {
                Text("メニュー").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4)
                ForEach(Array(commands)) { c in
                    MenuRow(symbol: "filemenu.and.selection", title: c.title, detail: c.shortcut.isEmpty ? c.path : c.shortcut) {
                        run {
                            app.activate()
                            c.element.perform(kAXPressAction)
                        }
                    }
                    .help(c.path)
                }
            }
            if windows.isEmpty && commands.isEmpty {
                Text("見つかりません").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    @ViewBuilder private var staticActions: some View {
        switch item.kind {
        case .app:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ActionTile(symbol: "arrow.up.forward.app", title: "開く") { run { model.activate(item) } }
                ActionTile(symbol: "folder", title: "Finder に表示") { run { reveal() } }
            }
        case .folder(let url):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ActionTile(symbol: "folder", title: "開く") { run { NSWorkspace.shared.open(url) } }
                ActionTile(symbol: "magnifyingglass", title: "Finder に表示") { run { reveal() } }
            }
        case .trash:
            TrashActions()
        case .widget(let kind):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ActionTile(symbol: model.leadingWidgets.contains(kind) ? "arrow.right.to.line" : "arrow.left.to.line",
                           title: model.leadingWidgets.contains(kind) ? "右端へ移動" : "左端へ移動") {
                    run { model.setWidget(kind, leading: !model.leadingWidgets.contains(kind)) }
                }
                ActionTile(symbol: "square.grid.3x2", title: "ウィジェット") { run { SettingsWindowController.shared.show(tab: .widgets) } }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var secondaryRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .app(let url) = item.kind {
                if item.runningApp != nil {
                    MenuRow(symbol: "magnifyingglass", title: "Finder に表示") { run { reveal() } }
                }
                if url != DockModel.finderURL {
                    if item.isPinned {
                        MenuRow(symbol: "pin.slash", title: "Dock から削除") { run { model.remove(item) } }
                    } else {
                        MenuRow(symbol: "pin", title: "Dock に固定") { run { model.pin(url) } }
                    }
                }
            }
            if case .folder = item.kind {
                MenuRow(symbol: "pin.slash", title: "Dock から削除") { run { model.remove(item) } }
            }
            if case .widget = item.kind {
                MenuRow(symbol: "trash", title: "Dock から削除", destructive: true) { run { model.remove(item) } }
            }
            if item.widgetKind == nil, item.kind != .trash, item.kind != .control {
                MenuRow(symbol: "photo", title: "アイコンを変更…") { run { model.chooseCustomIcon(for: item) } }
                if model.customIcons[model.iconKey(for: item)] != nil {
                    MenuRow(symbol: "arrow.uturn.backward", title: "アイコンを元に戻す") { run { model.setCustomIcon(nil, for: item) } }
                }
            }
            if let app = item.runningApp, item.url != DockModel.finderURL {
                // 未保存のデータが消えるため、もう一度押したときだけ実行する
                MenuRow(symbol: "exclamationmark.octagon", title: confirmForceQuit ? "もう一度押すと強制終了（未保存の内容は失われます）" : "強制終了",
                        destructive: true) {
                    if confirmForceQuit { run { app.forceTerminate() } } else { withAnimation(.spring(duration: 0.2)) { confirmForceQuit = true } }
                }
            }
            MenuRow(symbol: "gearshape", title: "Dock 設定…") { run { SettingsWindowController.shared.show() } }
        }
    }

    private func reveal() {
        if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    static func symbol(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("シークレット") || t.contains("プライベート") || t.contains("incognito") || t.contains("private") { return "eyeglasses" }
        if t.contains("ウインドウ") || t.contains("ウィンドウ") || t.contains("window") { return "macwindow.badge.plus" }
        if t.contains("タブ") || t.contains("tab") { return "plus.square.on.square" }
        if t.contains("新規") || t.contains("new") { return "plus" }
        if t.contains("再生") || t.contains("play") { return "play.fill" }
        if t.contains("次") || t.contains("next") { return "forward.fill" }
        if t.contains("前") || t.contains("previous") { return "backward.fill" }
        return "app.badge"
    }

    private func run(_ action: @escaping () -> Void) {
        controller.hide(animated: true)
        action()
    }
}

// MARK: - Trash

struct TrashActions: View {
    @State private var count: Int?
    @State private var confirming = false
    @State private var emptying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(count.map { $0 == 0 ? loc("ゴミ箱は空です") : loc("%d 項目", $0) } ?? loc("確認中…"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ActionTile(symbol: "trash", title: "開く") {
                    PreviewController.shared.hide(animated: true)
                    if let url = DockItem.trash.url { NSWorkspace.shared.open(url) }
                }
                ActionTile(symbol: confirming ? "exclamationmark.triangle.fill" : "trash.slash",
                           title: emptying ? "処理中…" : confirming ? "本当に空にする" : "空にする",
                           destructive: true) {
                    guard (count ?? 0) > 0, !emptying else { return }
                    if confirming {
                        emptying = true
                        Task {
                            await AppActions.emptyTrash()
                            count = await AppActions.trashCount()
                            emptying = false
                            confirming = false
                            DockModel.shared.invalidateIcons()
                        }
                    } else {
                        withAnimation(.spring(duration: 0.25)) { confirming = true }
                    }
                }
                .opacity((count ?? 0) > 0 ? 1 : 0.4)
            }
            if confirming {
                Text("ゴミ箱の項目は完全に削除され、取り消せません。")
                    .font(.system(size: 10)).foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .task { count = await AppActions.trashCount() }
    }
}

struct TrashPanel: View {
    @Environment(DockModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(icon: model.icon(for: .trash), title: "ゴミ箱")
            TrashActions()
        }
        .frame(width: 240)
    }
}

// MARK: - Folder stack

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [String: NSImage] = [:]

    func image(for url: URL) -> NSImage? { images[url.path] }

    func load(_ url: URL, size: CGFloat) async -> NSImage {
        if let img = images[url.path] { return img }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        let img: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            img = rep.nsImage
        } else {
            img = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
        }
        images[url.path] = img
        if images.count > 200 { images.removeAll() }
        return img
    }
}

struct FolderEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let date: Date

    static func load(_ folder: URL, limit: Int = 12) -> (entries: [FolderEntry], total: Int) {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let entries = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FolderEntry(url: u, name: FileManager.default.displayName(atPath: u.path),
                               date: v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
        return (Array(entries.prefix(limit)), urls.count)
    }
}

struct FolderStackPanel: View {
    let folder: URL
    let state: PreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PanelHeader(icon: NSWorkspace.shared.icon(forFile: folder.path),
                            title: FileManager.default.displayName(atPath: folder.path),
                            subtitle: loc("%d 項目・新しい順", state.folderTotal))
                Text("Finder で開く")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.primary.opacity(0.08)))
                    .onTapGesture {
                        PreviewController.shared.hide(animated: true)
                        NSWorkspace.shared.open(folder)
                    }
            }
            if state.folderEntries.isEmpty {
                Text("ファイルはありません").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                // 遅延生成だと開くアニメーション中にセルが順に現れてずれるため、通常の Grid で一度に作る
                let rows = stride(from: 0, to: state.folderEntries.count, by: 4).map {
                    Array(state.folderEntries[$0..<min($0 + 4, state.folderEntries.count)])
                }
                Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r]) { FileTile(entry: $0) }
                        }
                    }
                }
            }
        }
        .frame(width: 4 * 82 + 3 * 6)
    }
}

private struct FileTile: View {
    let entry: FolderEntry
    @State private var image: NSImage?
    @State private var hovering = false

    init(entry: FolderEntry) {
        self.entry = entry
        _image = State(initialValue: ThumbnailCache.shared.image(for: entry.url))
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
            Text(entry.date, format: .relative(presentation: .named))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(5)
        .frame(width: 82)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            PreviewController.shared.hide(animated: true)
            NSWorkspace.shared.open(entry.url)
        }
        .draggable(entry.url)
        .help(entry.name)
        .task(id: entry.url) {
            guard image == nil else { return }
            let loaded = await ThumbnailCache.shared.load(entry.url, size: 104)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { image = loaded }
        }
    }
}

// MARK: - Music app hover

struct MusicPanel: View {
    let item: DockItem
    @Environment(DockModel.self) private var model
    @State private var scrub: Double?

    var body: some View {
        let media = WidgetHub.shared.media
        let appName = NowPlayingService.playerName(for: item.bundleID)
        let active = appName != nil && media.player == appName
        let position = scrub ?? media.position
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    if active, let art = media.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                .scaleEffect(active && media.isPlaying ? 1 : 0.95)
                .animation(.spring(duration: 0.4, bounce: 0.35), value: media.isPlaying)

                VStack(alignment: .leading, spacing: 3) {
                    Text(active && !media.title.isEmpty ? media.title : loc("再生していません"))
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    if active {
                        Text(media.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Text(media.album).font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 3) {
                ProgressTrack(value: active && media.duration > 0 ? position / media.duration : 0) { fraction, done in
                    guard active, media.duration > 0 else { return }
                    scrub = fraction * media.duration
                    if done, let s = scrub {
                        media.seek(to: s)
                        scrub = nil
                    }
                }
                HStack {
                    Text(active ? Self.time(position) : "0:00")
                    Spacer()
                    Text(active ? Self.time(media.duration) : "0:00")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                Image(nsImage: model.icon(for: item))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .onTapGesture { open() }
                Spacer()
                HStack(spacing: 15) {
                    PlayerButton(symbol: "backward.fill", size: 14) { media.send(.previous, app: appName) }
                    PlayerButton(symbol: "gobackward.10", size: 16) { media.seek(to: max(position - 10, 0)) }
                    PlayerButton(symbol: active && media.isPlaying ? "pause.fill" : "play.fill", size: 21) {
                        media.send(.playPause, app: appName)
                    }
                    .frame(width: 22)
                    PlayerButton(symbol: "goforward.10", size: 16) { media.seek(to: min(position + 10, media.duration)) }
                    PlayerButton(symbol: "forward.fill", size: 14) { media.send(.next, app: appName) }
                }
                Spacer()
                PlayerButton(symbol: "quote.bubble", size: 13) { open() }
            }
        }
        .frame(width: 260)
        // ボタン以外の空いている場所をクリックしたらアプリを開く
        .contentShape(Rectangle())
        .onTapGesture { open() }
    }

    private func open() {
        PreviewController.shared.hide(animated: true)
        if let url = item.url { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(hovering ? .primary : .secondary)
            .scaleEffect(pressed ? 0.85 : hovering ? 1.08 : 1)
            .contentTransition(.symbolEffect(.replace))
            .contentShape(Rectangle().inset(by: -6))
            .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
            .onTapGesture {
                withAnimation(.spring(duration: 0.12)) { pressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(duration: 0.25, bounce: 0.5)) { pressed = false }
                }
                action()
            }
    }
}

struct ProgressTrack: View {
    let value: Double
    let onScrub: (Double, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule().fill(.primary.opacity(0.9))
                    .frame(width: max(geo.size.width * min(max(value, 0), 1), hovering ? 8 : 6))
            }
            .frame(height: hovering ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(min(max($0.location.x / geo.size.width, 0), 1), false) }
                    .onEnded { onScrub(min(max($0.location.x / geo.size.width, 0), 1), true) }
            )
            .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
        }
        .frame(height: 10)
    }
}

// MARK: - Control center

struct ControlCenterPanel: View {
    @Environment(DockSettings.self) private var settings
    @Environment(DockModel.self) private var model
    @State private var query = ""
    @State private var devices: [AudioDevice] = []
    @State private var output: AudioObjectID = 0
    @State private var page = 0
    @State private var presets = SettingsPresets.shared
    @State private var naming = false
    @State private var newName = ""
    @State private var hint: String?
    @FocusState private var nameFocused: Bool
    @State private var windowCounts: [pid_t: Int] = [:]
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    private let perPage = 13

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            leftColumn.frame(width: 272)
            rightColumn.frame(width: 252)
        }
        .onAppear {
            devices = AudioDevices.outputs()
            output = AudioDevices.defaultOutput
            WidgetHub.shared.volume.refresh()
            windowCounts = Dictionary(uniqueKeysWithValues: running.map { app in
                (app.processIdentifier, WindowService.shared.axWindows(pid: app.processIdentifier).count)
            })
        }
    }

    // MARK: Left

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchField(prompt: "検索", text: $query) {
                if let first = AppActions.searchApps(query).first { launch(first) }
            }
            if query.isEmpty {
                section("固定")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                    ForEach(pinned, id: \.self) { url in
                        AppGridIcon(url: url, removable: url != DockModel.finderURL) { launch(url) } onRemove: {
                            withAnimation(.smooth) { togglePin(url) }
                        }
                    }
                    AddAppTile { addApps() }
                }
            } else {
                section("検索結果")
                let results = AppActions.searchApps(query)
                VStack(spacing: 0) {
                    ForEach(results, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)).resizable().frame(width: 22, height: 22)
                            MenuRow(symbol: nil, title: displayName(url)) { launch(url) }
                            PinButton(pinned: isPinned(url)) { withAnimation(.smooth) { togglePin(url) } }
                        }
                    }
                    if results.isEmpty {
                        Text("見つかりません").font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                    }
                }
            }

            HStack {
                section("プリセット")
                Spacer()
                Menu {
                    Section("外観だけを適用") {
                        ForEach(DockPreset.all) { preset in
                            Button(loc(preset.name)) { withAnimation(.smooth) { settings.apply(preset) } }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("外観テーマ")
            }
            presetCard

            section("システム")
            systemCard

            @Bindable var s = settings
            let magnifying = s.magnificationStyle != .none
            HStack(spacing: 6) {
                SmallToggle(symbol: "gearshape", active: false, hint: loc("設定を開く"), hovered: $hint) {
                    close { SettingsWindowController.shared.show() }
                }
                SmallToggle(symbol: dark ? "moon.fill" : "sun.max.fill", active: dark,
                            hint: loc("ダークモード：%@", dark ? loc("オン") : loc("オフ")), hovered: $hint) {
                    dark.toggle()
                    AppActions.toggleDarkMode()
                }
                SmallToggle(symbol: "dock.arrow.down.rectangle", active: s.autoHide,
                            hint: loc("自動的に隠す：%@", s.autoHide ? loc("オン") : loc("オフ")), hovered: $hint) { s.autoHide.toggle() }
                SmallToggle(symbol: "plus.magnifyingglass", active: magnifying,
                            hint: loc("拡大：%@", magnifying ? loc("オン") : loc("オフ")), hovered: $hint) {
                    s.magnificationStyle = magnifying ? .none : .standard
                }
                SmallToggle(symbol: "moon.zzz", active: false, hint: loc("スリープ"), hovered: $hint) { close { AppActions.sleep() } }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(alignment: .top) {
                if let hint {
                    Text(loc(hint))
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(y: -32)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)).combined(with: .offset(y: 4)))
                }
            }
            .animation(.spring(duration: 0.28, bounce: 0.25), value: hint)
        }
    }

    // MARK: Presets

    private var presetCard: some View {
        let current = presets.currentID()
        let rows = VStack(spacing: 0) {
            ForEach(presets.presets) { p in
                PresetRow(name: p.name, current: p.id == current) { close { presets.apply(p.id) } }
            }
        }
        return VStack(spacing: 0) {
            if presets.presets.isEmpty {
                Text("現在の設定を保存すると、ここから切り替えられます")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            } else if presets.presets.count > 4 {
                ScrollView { rows }.frame(height: 4 * 30).scrollIndicators(.never).padding(4)
            } else {
                rows.padding(4)
            }
            Divider().opacity(0.4).padding(.horizontal, 12)
            if naming {
                HStack(spacing: 8) {
                    TextField("名前", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($nameFocused)
                        .onSubmit(saveNew)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                        .onTapGesture(perform: saveNew)
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .onTapGesture { withAnimation(.smooth(duration: 0.25)) { naming = false } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 12)).frame(width: 18)
                    Text("現在の設定を保存…").font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    newName = presets.defaultName()
                    withAnimation(.smooth(duration: 0.25)) { naming = true }
                    DispatchQueue.main.async { nameFocused = true }
                }
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private func saveNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        withAnimation(.smooth(duration: 0.3)) {
            presets.saveCurrent(name: name.isEmpty ? presets.defaultName() : name)
            naming = false
        }
    }

    private var systemCard: some View {
        let volume = WidgetHub.shared.volume
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: volume.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                    .onTapGesture { volume.toggleMute() }
                Slider(value: Binding(get: { Double(volume.volume) }, set: { volume.set(Float($0)) }), in: 0...1)
                    .controlSize(.small)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().opacity(0.4).padding(.horizontal, 12)
            Menu {
                ForEach(devices) { d in
                    Button {
                        output = d.id
                        AudioDevices.setDefaultOutput(d.id)
                        volume.setActive(false)
                        volume.setActive(true)
                    } label: {
                        if d.id == output { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).frame(width: 18)
                    Text(devices.first { $0.id == output }?.name ?? loc("出力")).font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
    }

    // MARK: Right

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private var rightColumn: some View {
        let apps = running
        let pages = max(1, Int(ceil(Double(apps.count) / Double(perPage))))
        let current = min(page, pages - 1)
        let slice = Array(apps.dropFirst(current * perPage).prefix(perPage))
        return VStack(alignment: .leading, spacing: 8) {
            section(loc("起動中 - %d", apps.count))
            VStack(spacing: 2) {
                ForEach(slice, id: \.processIdentifier) { app in
                    RunningRow(app: app, windows: windowCounts[app.processIdentifier] ?? 0,
                               frontmost: app.isActive,
                               pinned: app.bundleURL.map(isPinned),
                               onPin: { if let url = app.bundleURL { withAnimation(.smooth) { togglePin(url) } } }) {
                        close { app.unhide(); app.activate() }
                    } more: {
                        if let item = model.items.first(where: { $0.runningApp?.processIdentifier == app.processIdentifier }) {
                            PreviewController.shared.showMenu(for: item)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if pages > 1 {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(current > 0 ? .primary : .tertiary)
                        .onTapGesture { withAnimation(.smooth) { page = max(current - 1, 0) } }
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(.primary.opacity(i == current ? 0.8 : 0.25)).frame(width: i == current ? 14 : 5, height: 5)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(current < pages - 1 ? .primary : .tertiary)
                        .onTapGesture { withAnimation(.smooth) { page = min(current + 1, pages - 1) } }
                    Spacer()
                }
            }
        }
        .frame(minHeight: 470, alignment: .top)
    }

    // MARK: Helpers

    private var pinned: [URL] {
        Array(([DockModel.finderURL] + model.pinnedApps).prefix(15))
    }

    private func isPinned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == DockModel.finderURL.path || model.pinnedApps.contains { $0.standardizedFileURL.path == path }
    }

    private func togglePin(_ url: URL) {
        guard url.standardizedFileURL.path != DockModel.finderURL.path else { return }
        if isPinned(url) {
            model.remove(.app(url: url, pinned: true))
        } else {
            model.pin(url)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = loc("Dock に固定するアプリを選んでください")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { model.addToDock(panel.urls) }
    }

    private func section(_ title: String) -> some View {
        Text(loc(title)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }

    private func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func launch(_ url: URL) {
        close { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    private func close(_ action: @escaping () -> Void) {
        PreviewController.shared.hide(animated: true)
        action()
    }
}

private struct PinButton: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: pinned ? "pin.fill" : "pin")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .rotationEffect(.degrees(45))
            .frame(width: 20, height: 20)
            .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(pinned ? loc("Dock から削除") : loc("Dock に固定"))
    }
}

private struct AddAppTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(hovering ? 0.4 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Text("追加").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("アプリを Dock に固定")
    }
}

private struct SmallToggle: View {
    let symbol: String
    let active: Bool
    let hint: String
    @Binding var hovered: String?
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @State private var taps = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? .white : .primary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: taps)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.14 : 0.07))
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient).opacity(active ? 1 : 0)
                }
            }
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.smooth(duration: 0.3), value: active)
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(.spring(duration: 0.2)) { hovering = h }
                if h { hovered = hint } else if hovered == hint { hovered = nil }
            }
            .onChange(of: hint) { _, new in if hovering { hovered = new } }
            .onTapGesture {
                taps += 1
                withAnimation(.spring(duration: 0.12)) { pressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.5)) { pressed = false }
                }
                action()
            }
    }
}

private struct PresetRow: View {
    let name: String
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                .opacity(current ? 1 : 0)
                .frame(width: 16)
            Text(loc(name)).font(.system(size: 12.5, weight: current ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(hovering ? .white : .primary)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.85) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

private struct AppGridIcon: View {
    let url: URL
    var removable = false
    let action: () -> Void
    var onRemove: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path))
                .resizable()
                .frame(width: 38, height: 38)
                .scaleEffect(hovering ? 1.1 : 1)
                .overlay(alignment: .topLeading) {
                    if hovering && removable {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                            .offset(x: -5, y: -5)
                            .onTapGesture(perform: onRemove)
                            .help("Dock から削除")
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
        .onTapGesture(perform: action)
    }
}

private struct RunningRow: View {
    let app: NSRunningApplication
    let windows: Int
    let frontmost: Bool
    let pinned: Bool?
    let onPin: () -> Void
    let open: () -> Void
    let more: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 20, height: 20)
            Text(app.localizedName ?? "").font(.system(size: 12.5, weight: frontmost ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if app.isHidden {
                Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let pinned, hovering || pinned {
                PinButton(pinned: pinned, action: onPin)
            }
            Text("\(windows)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, minHeight: 16)
                .background(Capsule().fill(.primary.opacity(0.1)))
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .onTapGesture(perform: more)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(frontmost ? Color.accentColor.opacity(0.25) : .primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}

struct ControlTile: View {
    let size: CGFloat

    var body: some View {
        let inset = size * 0.08
        let h = size - inset * 2
        ZStack {
            Image(systemName: "switch.2")
                .font(.system(size: h * 0.42, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: h, height: h)
        .background(AppGlass(cornerRadius: h * 0.24))
        .padding(inset)
    }
}
