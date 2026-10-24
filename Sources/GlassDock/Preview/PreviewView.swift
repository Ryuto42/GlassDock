import SwiftUI

struct PreviewRootView: View {
    let state: PreviewState
    @Environment(DockSettings.self) private var settings

    var body: some View {
        GeometryReader { geo in
            if let item = state.item {
                let size = state.contentSize
                let center = panelCenter(in: geo.size, size: size)
                let radius = min(22, max(size.height, 1) / 2)
                ZStack(alignment: .topLeading) {
                    // 実際の大きさを先に測るための非表示コピー
                    PreviewContent(item: item, state: state, maxSize: geo.size)
                        .fixedSize()
                        .hidden()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
                            if state.phase == .open {
                                withAnimation(settings.spring(0.34, damping: 0.82)) { state.contentSize = new }
                            } else {
                                state.contentSize = new
                            }
                        }

                    // しずく（アイコンの縁）からパネルの形へ、同じガラスの大きさと角丸をばねで変える
                    if state.phase != .hidden {
                        let open = state.phase == .open
                        let seed = seedSize
                        let frameSize = open ? size : seed
                        let c = open ? center : seedCenter(seed)
                        AppGlass(cornerRadius: open ? radius : min(seed.width, seed.height) / 2)
                            .frame(width: max(frameSize.width, 1), height: max(frameSize.height, 1))
                            .position(c)
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    }

                    if state.phase != .hidden {
                        // 中身はしずくの段階から透明で置いておき、ガラスと同じばねで同じ位置から一緒に拡大させる
                        let open = state.phase == .open
                        let seed = seedSize
                        let seedScale = max(min(seed.width / max(size.width, 1), seed.height / max(size.height, 1)) * 1.6, 0.08)
                        ZStack {
                            // アイコン間を移動したときは中身をクロスフェードさせ、ガラスの形だけを滑らかに変える
                            PreviewContent(item: item, state: state, maxSize: geo.size)
                                .fixedSize()
                                .id(state.contentKey)
                                .transition(.opacity.animation(.easeInOut(duration: 0.16)))
                        }
                            .contentShape(Rectangle())
                            .pointerStyle(.default)
                            .onHover { PreviewController.shared.previewHover($0) }
                            .allowsHitTesting(open)
                            .scaleEffect(open ? 1 : seedScale)
                            // 透明度だけは別の動きにし、縮みながらゆっくり消える（ばねだと一瞬で消えるため）
                            .animation(open ? .easeOut(duration: 0.2 / settings.animationSpeed) : .easeIn(duration: 0.18 / settings.animationSpeed)) {
                                $0.opacity(open ? 1 : 0)
                            }
                            .position(open ? center : seedCenter(seed))
                            .onGeometryChange(for: CGRect.self) { _ in
                                CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                            } action: { state.contentFrame = $0 }
                            .transition(.opacity.animation(.easeOut(duration: 0.12)))
                    }
                }
            }
        }
    }

    private var seedSize: CGSize {
        let long = state.seedLength, short: CGFloat = 14
        return settings.position.isVertical ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    // しずくはアイコンの縁に少し重ねて置き、そこから伸びて見えるようにする
    private func seedCenter(_ s: CGSize) -> CGPoint {
        let a = state.anchor
        let sink: CGFloat = 10
        return switch settings.position {
        case .bottom: CGPoint(x: a.x, y: a.y - s.height / 2 + sink)
        case .left: CGPoint(x: a.x + s.width / 2 - sink, y: a.y)
        case .right: CGPoint(x: a.x - s.width / 2 + sink, y: a.y)
        }
    }

    private func panelCenter(in bounds: CGSize, size: CGSize) -> CGPoint {
        let a = state.anchor
        let w = size.width, h = size.height
        let m: CGFloat = 8
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        switch settings.position {
        case .bottom:
            return CGPoint(x: clamp(a.x, w / 2 + m, bounds.width - w / 2 - m), y: a.y - h / 2)
        case .left:
            return CGPoint(x: a.x + w / 2, y: clamp(a.y, h / 2 + m + 30, bounds.height - h / 2 - m))
        case .right:
            return CGPoint(x: a.x - w / 2, y: clamp(a.y, h / 2 + m + 30, bounds.height - h / 2 - m))
        }
    }
}

struct PreviewContent: View {
    let item: DockItem
    let state: PreviewState
    let maxSize: CGSize
    @Environment(DockSettings.self) private var settings

    var body: some View {
        if state.mode == .menu {
            ContextMenuPanel(item: item, state: state)
                .padding(12)
        } else if state.mode == .control || item.kind == .control && state.mode != .hover {
            ControlCenterPanel()
                .padding(14)
        } else if let kind = item.widgetKind {
            WidgetDetail(kind: kind)
                .padding(12)
        } else if case .folder(let url) = item.kind {
            FolderStackPanel(folder: url, state: state)
                .padding(12)
        } else if item.kind == .trash {
            TrashPanel()
                .padding(12)
        } else if item.isRunning, NowPlayingService.playerName(for: item.bundleID) != nil {
            MusicPanel(item: item)
                .padding(13)
        } else if showCards {
            let layout = gridLayout
            VStack(alignment: .leading, spacing: 8) {
                header(maxWidth: layout.width - 8)
                grid(layout)
            }
            .padding(12)
        } else {
            VStack(spacing: 1) {
                Text(loc(item.name))
                    .font(.system(size: 13, weight: .medium))
                if DockModel.shared.isBackground(item) {
                    Text("バックグラウンドで実行中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var showCards: Bool { DockSettings.shared.previewEnabled && item.isRunning && !state.windows.isEmpty }

    // 長いアプリ名でパネルがカードより横に広がらないよう、カードの列の幅に収める
    private func header(maxWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(loc(item.name)).font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(state.windows.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(.primary.opacity(0.08)))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: max(maxWidth, 40), alignment: .leading)
        .padding(.horizontal, 4)
    }

    private struct GridLayout {
        let cardWidth: CGFloat
        let columns: Int
        let width: CGFloat
    }

    // WindowCard の幅は width + 余白 16
    private var gridLayout: GridLayout {
        let cardW = CGFloat(DockSettings.shared.previewSize)
        let horizontal = !settings.position.isVertical
        let available = horizontal ? maxSize.width - 60 : maxSize.width * 0.5
        let columns = max(1, min(state.windows.count, Int(available / (cardW + 22))))
        let width = CGFloat(columns) * (cardW + 16) + CGFloat(columns - 1) * 10
        return GridLayout(cardWidth: cardW, columns: columns, width: width)
    }

    @ViewBuilder private func grid(_ layout: GridLayout) -> some View {
        let columns = layout.columns
        let rows = stride(from: 0, to: state.windows.count, by: columns).map {
            Array(state.windows[$0..<min($0 + columns, state.windows.count)])
        }
        let icon = DockModel.shared.icon(for: item)
        let content = Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { window in
                        WindowCard(window: window, icon: icon, width: layout.cardWidth)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
        }
        // ウィンドウが多く画面の高さに収まらないときはスクロールさせる（メニューバーと見出しの分を除く）
        let rowHeight = layout.cardWidth * 0.62 + 32
        let contentHeight = CGFloat(rows.count) * (rowHeight + 10) - 10
        let available = max(rowHeight, maxSize.height - 130)
        if contentHeight > available {
            ScrollView {
                content.padding(4)
            }
            .frame(maxHeight: available)
        } else {
            content
        }
    }
}

struct WindowCard: View {
    let window: WindowInfo
    let icon: NSImage
    let width: CGFloat
    @Environment(DockSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        let thumbH = width * 0.62
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.06))
                if let image = window.thumbnail {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .padding(6)
                        .saturation(window.isMinimized ? 0.6 : 1)
                        .transition(.opacity)
                } else {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: thumbH * 0.45, height: thumbH * 0.45)
                        .opacity(0.85)
                }
                if window.isMinimized {
                    Label("最小化中", systemImage: "minus")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppGlass(cornerRadius: 9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
            }
            .frame(width: width, height: thumbH)
            .overlay(alignment: .topTrailing) {
                if hovering { controls.transition(.scale(scale: 0.6).combined(with: .opacity)) }
            }

            Text(window.title.isEmpty ? loc("名称未設定") : window.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.1 : 0))
        }
        .scaleEffect(hovering ? 1.025 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { h in withAnimation(settings.spring(0.22, damping: 0.8)) { hovering = h } }
        .onTapGesture { PreviewController.shared.focus(window) }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if !window.isMinimized {
                CircleButton(symbol: "minus") { PreviewController.shared.minimize(window) }
            }
            CircleButton(symbol: "xmark") { PreviewController.shared.close(window) }
        }
        .padding(6)
    }
}

struct CircleButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 20, height: 20)
            .foregroundStyle(hovering ? .primary : .secondary)
            .background(AppGlass(cornerRadius: 10))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}
