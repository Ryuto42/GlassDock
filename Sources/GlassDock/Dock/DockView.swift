import SwiftUI
import UniformTypeIdentifiers

// Dock の寸法。ディスプレイごとに設定が違うことがあるため、設定を受け取って計算する
@MainActor
struct DockMetrics {
    let s: DockSettings

    init(_ settings: DockSettings) { s = settings }

    var edgeMargin: CGFloat { s.layoutStyle == .taskbar ? 0 : 5 }
    var dividerLength: CGFloat { s.dividerStyle == .none ? 2 : 13 }

    var padding: CGFloat {
        let base = CGFloat(s.iconSize) * 0.25 * CGFloat(s.paddingScale)
        return min(max(base, 3), 22)
    }

    var labelHeight: CGFloat { s.alwaysShowLabels && !s.position.isVertical ? 13 : 0 }

    var barThickness: CGFloat { CGFloat(s.iconSize) + padding * 2 + labelHeight }

    var lift: CGFloat { s.magnificationStyle == .lift ? CGFloat(s.iconSize) * 0.32 : 0 }

    var thickness: CGFloat {
        CGFloat(s.maxIconSize - s.iconSize) + barThickness + edgeMargin + lift + 4
    }

    func cornerRadius(for thickness: CGFloat) -> CGFloat {
        s.layoutStyle == .taskbar ? 0 : thickness * CGFloat(s.cornerRatio)
    }
}

// ディスプレイごとの Dock が、それぞれ自分の表示状態を持つ
@Observable
final class DockVisibility {
    @ObservationIgnored var settings: DockSettings = .shared
    var revealed = true {
        didSet { if oldValue != revealed { DockPanelController.shared.updateWidgetVisibility() } }
    }
    @ObservationIgnored var hovering = false
    @ObservationIgnored var isMouseInside: () -> Bool = { false }
    @ObservationIgnored var isMouseAtEdge: () -> Bool = { false }
    // 隠したときにカーソルが画面の端に残っていたら、そこから動かすまで端に触れても出さない
    @ObservationIgnored private var suppressedAt: CGPoint?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    func reveal() {
        hideWork?.cancel()
        if !revealed { withAnimation(settings.spring(0.3, damping: 0.85)) { revealed = true } }
    }

    func scheduleHide(after delay: TimeInterval = 0.5) {
        // 自動的に隠すを切ったときは、待っている非表示を取り消して表示状態に戻す（次に入れたときに急に消えないように）
        guard settings.autoHide else {
            reveal()
            return
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.settings.autoHide, !self.hovering, !PreviewController.shared.isVisible else { return }
            // 端から出しただけでバーの上に来ていない、またはカーソルが止まったままの場合もここで判定する
            if self.isMouseInside() {
                self.scheduleHide()
                return
            }
            self.suppressedAt = self.isMouseAtEdge() ? NSEvent.mouseLocation : nil
            withAnimation(self.settings.spring(0.35, damping: 0.9)) { self.revealed = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func revealTemporarily(for seconds: TimeInterval) {
        reveal()
        scheduleHide(after: seconds)
    }

    // 画面の端に触れて出したとき。バーに入らなければそのまま隠す
    func revealFromEdge(alongBar: Bool) {
        if let at = suppressedAt {
            let p = NSEvent.mouseLocation
            guard alongBar || hypot(p.x - at.x, p.y - at.y) > 8 else { return }
            suppressedAt = nil
        }
        reveal()
        scheduleHide(after: 1.0)
    }
}

// 透明部分ではマウスイベントが下のウィンドウへ抜けるため、SwiftUI のホバー終了が届かないことがある。
// ホバー中だけシステム全体のマウス移動を見て、Dock の範囲から出たら終了扱いにする
@MainActor
final class DockHoverWatcher {
    weak var window: NSWindow?
    var barRect: CGRect = .zero
    private var monitors: [Any] = []
    private var timer: Timer?
    private var onExit: (() -> Void)?
    private var onMove: ((CGPoint) -> Void)?

    // 透明部分のイベントは自分のウィンドウに届くこともあるため、ローカルとグローバルの両方を見る。
    // 画面の最下端などでは SwiftUI のホバーがしばらく届かないことがあるので、ここで見た位置も onMove で渡す
    func begin(onMove: @escaping (CGPoint) -> Void, onExit: @escaping () -> Void) {
        self.onMove = onMove
        self.onExit = onExit
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.check() }
            return event
        }) { monitors.append(l) }
        // 画面最下端などイベントが別のプロセスに渡る場所でも確実に気づけるよう、ホバー中だけ位置を確認する
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        onExit = nil
        onMove = nil
    }

    func edgeContainsMouse(_ position: DockPosition) -> Bool {
        guard let win = window else { return false }
        let p = NSEvent.mouseLocation
        let f = win.frame
        switch position {
        case .bottom: return p.y <= f.minY + 4 && p.x >= f.minX && p.x <= f.maxX
        case .left: return p.x <= f.minX + 4 && p.y >= f.minY && p.y <= f.maxY
        case .right: return p.x >= f.maxX - 4 && p.y >= f.minY && p.y <= f.maxY
        }
    }

    func containsMouse() -> Bool {
        guard let win = window, win.isVisible else { return false }
        return barContainsMouse(in: win)
    }

    private func barContainsMouse(in win: NSWindow) -> Bool {
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - win.frame.minX, y: win.frame.maxY - p.y)
        return barRect.insetBy(dx: -2, dy: -2).contains(local)
    }

    private func check() {
        guard onExit != nil, let win = window else { return }
        if barContainsMouse(in: win) {
            let p = NSEvent.mouseLocation
            onMove?(CGPoint(x: p.x - win.frame.minX, y: win.frame.maxY - p.y))
            return
        }
        let exit = onExit
        // モニタのコールバック中に自身を外さないよう、次のループで終了させる
        DispatchQueue.main.async { [weak self] in
            self?.end()
            exit?()
        }
        onExit = nil
    }
}

extension DockPosition {
    var alignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var edge: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    // アイコンの当たり判定を Dock の外側の端（画面の端）まで広げるための余白
    func crossInsets(inner: CGFloat, outer: CGFloat) -> EdgeInsets {
        switch self {
        case .bottom: EdgeInsets(top: inner, leading: 0, bottom: outer, trailing: 0)
        case .left: EdgeInsets(top: 0, leading: outer, bottom: 0, trailing: inner)
        case .right: EdgeInsets(top: 0, leading: inner, bottom: 0, trailing: outer)
        }
    }

    var alongEdges: Edge.Set { isVertical ? .vertical : .horizontal }

    // 画面の内側へ向かう方向の単位ベクトル
    nonisolated func inward(_ d: CGFloat) -> CGSize {
        switch self {
        case .bottom: CGSize(width: 0, height: -d)
        case .left: CGSize(width: d, height: 0)
        case .right: CGSize(width: -d, height: 0)
        }
    }
}

struct DockRootView: View {
    @Environment(DockSettings.self) private var settings
    private var metrics: DockMetrics { DockMetrics(settings) }
    @Environment(DockModel.self) private var model
    @Environment(DockContext.self) private var context
    private var visibility: DockVisibility { context.visibility }
    // ほぼ透明な部分はマウスイベントが下のアプリへ抜ける。8 ビットに丸めても 0 にならず、目には見えない濃さにする
    static let hitAlpha = 0.008

    var body: some View {
        GeometryReader { geo in
            let pos = settings.position
            let hidden = settings.autoHide && !visibility.revealed
            ZStack(alignment: pos.alignment) {
                DockBar(windowLength: pos.isVertical ? geo.size.height : geo.size.width)
                    .offset(hidden ? pos.inward(-(metrics.barThickness + 24)) : .zero)
                    .opacity(hidden ? 0 : 1)
                if hidden {
                    Color.black.opacity(Self.hitAlpha)
                        .frame(width: pos.isVertical ? 4 : nil, height: pos.isVertical ? nil : 4)
                        .onContinuousHover(coordinateSpace: .named("dockWindow")) { phase in
                            switch phase {
                            case .active(let p):
                                let bar = context.watcher.barRect
                                let along = pos.isVertical ? (p.y >= bar.minY && p.y <= bar.maxY) : (p.x >= bar.minX && p.x <= bar.maxX)
                                visibility.revealFromEdge(alongBar: along)
                            case .ended:
                                break
                            }
                        }
                        .pointerStyle(.default)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: pos.alignment)
        }
        .coordinateSpace(.named("dockWindow"))
    }
}

struct DockBar: View {
    let windowLength: CGFloat
    @Environment(DockSettings.self) private var settings
    private var metrics: DockMetrics { DockMetrics(settings) }
    @Environment(DockModel.self) private var model
    @Environment(DockContext.self) private var context
    @State private var mouse: CGFloat?
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let pos = settings.position
        let base = CGFloat(settings.iconSize)
        let pad = metrics.padding
        let layout = pos.isVertical
            ? AnyLayout(VStackLayout(alignment: pos == .left ? .leading : .trailing, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 0))
        let margin = metrics.edgeMargin
        let scales = magnification()
        let barThickness = metrics.barThickness
        let crossLength = (scales.map { base + (CGFloat(settings.maxIconSize) - base) * $0 }.max() ?? base) + metrics.lift
        let crossThickness = crossLength + pad * 2 + metrics.labelHeight + margin
        let taskbar = settings.layoutStyle == .taskbar

        layout {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if item.kind == .divider {
                    DockDivider(style: settings.dividerStyle, vertical: !pos.isVertical, length: base * 0.72)
                        .frame(width: pos.isVertical ? base : metrics.dividerLength,
                               height: pos.isVertical ? metrics.dividerLength : base)
                        .padding(pos.edge, metrics.labelHeight)
                        .padding(pos.crossInsets(inner: pad, outer: pad + margin))
                        .padding(pos.alongEdges, CGFloat(settings.spacing) / 2)
                        .transition(.opacity)
                } else {
                    DockIconView(item: item, scale: scales[index])
                        .equatable()
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .padding(pos.alongEdges, max(pad - CGFloat(settings.spacing) / 2, 0))
        .frame(
            width: pos.isVertical ? crossThickness : nil,
            height: pos.isVertical ? nil : crossThickness,
            alignment: pos.alignment
        )
        .frame(maxWidth: taskbar && !pos.isVertical ? .infinity : nil,
               maxHeight: taskbar && pos.isVertical ? .infinity : nil,
               alignment: pos.alignment)
        .background(alignment: pos.alignment) {
            DockSurface(cornerRadius: metrics.cornerRadius(for: barThickness), highlighted: dropTargeted)
                .frame(width: pos.isVertical ? barThickness : nil, height: pos.isVertical ? nil : barThickness)
                .padding(pos.edge, margin)
        }
        // 画面の端まで含めてホバー判定にする（拡大で上に出た部分はホバー中だけ）
        .background(alignment: pos.alignment) {
            Color.black.opacity(DockRootView.hitAlpha)
                .frame(width: pos.isVertical ? barThickness + margin : nil,
                       height: pos.isVertical ? nil : barThickness + margin)
        }
        .background(Color.black.opacity(hovering ? 0.001 : 0))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { context.watcher.barRect = $0 }
        // 下にあるウィンドウの縁（サイズ変更の判定）にカーソルの形を取られないよう、矢印に固定する
        .pointerStyle(.default)
        .onContinuousHover(coordinateSpace: .named("dockWindow")) { phase in
            switch phase {
            case .active(let p):
                if !hovering {
                    hovering = true
                    context.watcher.begin(onMove: { track($0, fromWatcher: true) }) { endHover() }
                }
                context.visibility.hovering = true
                context.visibility.reveal()
                track(p, fromWatcher: false)
            case .ended:
                context.watcher.end()
                endHover()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addToDock(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Dock 設定…") { SettingsWindowController.shared.show() }
            Button("ウィジェットを追加…") { SettingsWindowController.shared.show(tab: .widgets) }
            Toggle("自動的に隠す", isOn: Binding(get: { settings.autoHide }, set: { settings.autoHide = $0 }))
            Divider()
            Button("GlassDock を終了") { NSApp.terminate(nil) }
        }
        .animation(settings.spring(), value: model.items.map(\.id))
    }

    private func track(_ p: CGPoint, fromWatcher: Bool) {
        guard model.draggingID == nil else { return }
        let pos = settings.position
        if fromWatcher { hoverIcon(at: p) }
        guard settings.magnificationStyle != .none else { return }
        let v = pos.isVertical ? p.y : p.x
        if mouse == nil {
            withAnimation(settings.spring(0.22, damping: 0.85)) { mouse = v }
        } else if abs((mouse ?? v) - v) >= 0.5 {
            withAnimation(.interactiveSpring(response: 0.12 / max(settings.animationSpeed, 0.1), dampingFraction: 0.9)) { mouse = v }
        }
    }

    // アイコンの onHover が届かないあいだも、カーソルの下のアイコンに切り替える
    private func hoverIcon(at p: CGPoint) {
        let vertical = settings.position.isVertical
        let frames = PreviewController.shared.iconFrames
        guard let item = model.items.first(where: { item in
            guard item.kind != .divider, let f = frames[context.key(item.id)] else { return false }
            return vertical ? (p.y >= f.minY && p.y < f.maxY) : (p.x >= f.minX && p.x < f.maxX)
        }), model.hoveredID != item.id || model.hoveredContextID != context.id else { return }
        model.clearFreshDownloads(item)
        model.hoveredID = item.id
        if model.hoveredContextID != context.id { model.hoveredContextID = context.id }
        PreviewController.shared.hoverBegan(item, in: context)
    }

    private func endHover() {
        guard hovering else { return }
        hovering = false
        context.visibility.hovering = false
        withAnimation(settings.spring(0.3, damping: 0.8)) { mouse = nil }
        if model.hoveredContextID == context.id, let id = model.hoveredID, let item = model.items.first(where: { $0.id == id }) {
            model.hoveredID = nil
            PreviewController.shared.hoverEnded(item)
        }
        context.visibility.scheduleHide()
    }

    // 拡大前のレイアウト上の中心位置からの距離で、各アイテムの拡大率（0〜1）を決める
    private func magnification() -> [CGFloat] {
        let items = model.items
        guard let mouse, settings.magnificationStyle != .none else { return Array(repeating: 0, count: items.count) }
        let base = CGFloat(settings.iconSize)
        let spacing = CGFloat(settings.spacing)
        let lengths = items.map { $0.kind == .divider ? metrics.dividerLength : base * $0.widthFactor }
        let endPad = max(metrics.padding - spacing / 2, 0)
        let total = lengths.reduce(0, +) + spacing * CGFloat(items.count) + endPad * 2
        var cursor = (windowLength - total) / 2 + endPad + spacing / 2
        let wave = settings.magnificationStyle == .wave
        let radius = base * CGFloat(settings.magnificationRange) * (wave ? 1.5 : 1)
        return lengths.enumerated().map { i, len in
            let center = cursor + len / 2
            cursor += len + spacing
            guard items[i].kind != .divider else { return 0 }
            let d = max(0, abs(mouse - center) - (len - base) / 2)
            guard d < radius else { return 0 }
            if wave {
                let x = d / radius * 2.2
                return exp(-x * x)
            }
            let f = cos(d / radius * .pi / 2)
            return f * f
        }
    }
}

struct DockDivider: View {
    let style: DividerStyle
    let vertical: Bool
    let length: CGFloat

    var body: some View {
        if style == .line {
            Capsule()
                .fill(.primary.opacity(0.22))
                .frame(width: vertical ? 1 : length, height: vertical ? length : 1)
        } else {
            Color.clear
        }
    }
}

// 入力（項目と拡大率）が変わらないアイコンは、Dock 全体が更新されても作り直さない
struct DockIconView: View, Equatable {
    let item: DockItem
    let scale: CGFloat

    nonisolated static func == (a: DockIconView, b: DockIconView) -> Bool {
        a.item == b.item && a.scale == b.scale
    }

    @Environment(DockSettings.self) private var settings
    private var metrics: DockMetrics { DockMetrics(settings) }
    @Environment(DockModel.self) private var model
    @Environment(DockContext.self) private var context
    @State private var drag: CGSize = .zero
    @State private var dragShift: CGFloat = 0
    @State private var pressed = false
    @State private var dropTargeted = false

    private var isDragging: Bool { model.draggingID == item.id }
    private var isHovered: Bool { model.hoveredID == item.id && model.hoveredContextID == context.id }

    private var size: CGFloat {
        let base = CGFloat(settings.iconSize)
        guard settings.magnification else { return base }
        return base + (CGFloat(settings.maxIconSize) - base) * scale
    }

    private var removing: Bool {
        guard isDragging else { return false }
        let away: CGFloat = switch settings.position {
        case .bottom: -drag.height
        case .left: drag.width
        case .right: -drag.width
        }
        return away > 80
    }

    var body: some View {
        let launching = model.launching.contains(item.id)
        let lift = settings.magnificationStyle == .lift ? metrics.lift * scale : 0
        iconContent
            .animation(.smooth(duration: 0.3), value: dimmed)
            .frame(width: size * item.widthFactor, height: size)
            .scaleEffect(pressed ? 0.88 : (dropTargeted ? 1.08 : 1))
            .brightness(pressed ? -0.15 : (isHovered && settings.hoverEffect == .shine ? 0.12 : 0))
            .modifier(IconShadows(glow: hoverGlow, glowRadius: isHovered ? size * 0.18 : 0,
                                  drop: settings.iconShadow, size: size))
            .overlay(alignment: .topTrailing) { badge }
            .overlay(alignment: .topTrailing) {
                let fresh = model.freshDownloadCount(for: item)
                if fresh > 0 { FreshDownloadBadge(count: fresh, size: size) }
            }
            .modifier(BounceModifier(active: launching, position: settings.position, size: size))
            .offset(settings.position.inward(lift))
            .background(alignment: settings.position.alignment) { cardBackground }
            .overlay(alignment: settings.position.alignment) { indicator }
            .overlay(alignment: .bottom) { label }
            .padding(settings.position.edge, metrics.labelHeight)
            .padding(settings.position.crossInsets(inner: metrics.padding, outer: metrics.padding + metrics.edgeMargin))
            .padding(settings.position.alongEdges, CGFloat(settings.spacing) / 2)
            .opacity(removing ? 0.45 : 1)
            .overlay {
                if removing {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white, .red)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .offset(isDragging ? draggedOffset : .zero)
            .zIndex(isDragging ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    model.clearFreshDownloads(item)
                    model.hoveredID = item.id
                    if model.hoveredContextID != context.id { model.hoveredContextID = context.id }
                    PreviewController.shared.hoverBegan(item, in: context)
                } else if isHovered {
                    model.hoveredID = nil
                    PreviewController.shared.hoverEnded(item)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                PreviewController.shared.iconFrames[context.key(item.id)] = $0
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(settings.spring(0.25, damping: 0.6)) { pressed = false }
                }
                if item.widgetKind == nil { PreviewController.shared.hide(animated: true) }
                model.activate(item)
            }
            .gesture(dragGesture)
            .dropDestination(for: URL.self) { urls, _ in
                model.open(urls, with: item)
            } isTargeted: { t in
                withAnimation(settings.spring(0.2)) { dropTargeted = t }
            }
    }

    @ViewBuilder private var iconContent: some View {
        if let kind = item.widgetKind {
            WidgetTile(kind: kind, size: size)
        } else if item.kind == .control {
            ControlTile(size: size)
        } else {
            let image = Group {
                if let cg = model.cgIcon(for: item) {
                    Image(decorative: cg, scale: 2).resizable().interpolation(.high)
                } else {
                    Image(nsImage: model.icon(for: item)).resizable().interpolation(.high)
                }
            }
            switch settings.iconStyle {
            case .original:
                image.opacity(dimmed ? 0.55 : 1)
            case .monochrome:
                image.saturation(0).contrast(1.1).opacity(dimmed ? 0.5 : 1)
            case .tinted:
                image.saturation(0).brightness(0.15).colorMultiply(settings.iconTint).opacity(dimmed ? 0.55 : 1)
            }
        }
    }

    private var dimmed: Bool {
        guard case .app = item.kind else { return false }
        if settings.dimInactive && !item.isRunning { return true }
        if model.isBackground(item) { return true }
        // 最小化中・非表示中のアプリは少し薄くする
        return settings.dimMinimized && (model.isMinimized(item) || model.isHidden(item))
    }

    private var hoverGlow: Color {
        guard isHovered, settings.hoverEffect == .glow else { return .clear }
        return settings.indicatorHex.isEmpty ? .white.opacity(0.55) : settings.indicatorColor.opacity(0.8)
    }

    private var draggedOffset: CGSize {
        settings.position.isVertical
            ? CGSize(width: drag.width, height: drag.height - dragShift)
            : CGSize(width: drag.width - dragShift, height: drag.height)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("dockWindow"))
            .onChanged { value in
                guard model.canReorder(item) else { return }
                if model.draggingID != item.id {
                    model.draggingID = item.id
                    dragShift = 0
                    PreviewController.shared.hide(animated: true)
                }
                drag = value.translation
                let along = settings.position.isVertical ? value.translation.height : value.translation.width
                let step = CGFloat(settings.iconSize * Double(item.widthFactor) + settings.spacing)
                let delta = along - dragShift
                if abs(delta) > step * 0.6 {
                    let dir = delta > 0 ? 1 : -1
                    withAnimation(settings.spring(0.25, damping: 0.85)) {
                        if model.move(item, by: dir) { dragShift += CGFloat(dir) * step }
                    }
                }
            }
            .onEnded { _ in
                guard model.draggingID == item.id else { return }
                let remove = removing
                withAnimation(settings.spring(0.3, damping: 0.8)) {
                    drag = .zero
                    dragShift = 0
                    model.draggingID = nil
                    if remove { model.remove(item) }
                }
            }
    }

    @ViewBuilder private var cardBackground: some View {
        if item.isRunning || item.isLingering, settings.indicator == .card {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(IconColor.average(model.icon(for: item), key: item.id).opacity(0.38))
                .frame(width: size + metrics.padding * 1.2, height: size + metrics.padding * 1.2)
                .offset(settings.position.inward(-metrics.padding * 0.6))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    @ViewBuilder private var indicator: some View {
        if item.isRunning || item.isLingering, item.widgetKind == nil {
            let vertical = settings.position.isVertical
            let color = settings.indicatorColor.opacity(model.isHidden(item) || model.isBackground(item) ? 0.4 : 0.8)
            let d = metrics.padding / 2 + 2
            switch settings.indicator {
            case .dot, .bar:
                // ウィンドウの数だけ丸（バー）を並べる。最大3つ。小さいアイコンでも隣の印と重ならないよう、アイコンの幅に収める
                let count = settings.indicatorShowsWindowCount ? min(max(model.windowCount(item), 1), 3) : 1
                let fit = (size - 3 * CGFloat(count - 1)) / CGFloat(count)
                let long: CGFloat = settings.indicator == .bar ? max(4, min(max(8, size * (count > 1 ? 0.16 : 0.3)), fit)) : 4
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
                layout {
                    ForEach(0..<count, id: \.self) { _ in
                        Capsule()
                            .fill(color)
                            .frame(width: vertical ? 4 : long, height: vertical ? long : 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3, bounce: 0.3), value: count)
                .offset(settings.position.inward(-d))
                .transition(.scale.combined(with: .opacity))
            case .glow:
                Capsule()
                    .fill(color)
                    .frame(width: vertical ? 3 : size * 0.5, height: vertical ? size * 0.5 : 3)
                    .shadow(color: color, radius: 4)
                    .shadow(color: color, radius: 8)
                    .offset(settings.position.inward(-d))
                    .transition(.opacity)
            case .card, .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var label: some View {
        if metrics.labelHeight > 0 {
            Text(loc(item.name))
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .frame(width: size * item.widthFactor + CGFloat(settings.spacing))
                .foregroundStyle(.primary.opacity(0.85))
                .offset(y: metrics.labelHeight + metrics.padding * 0.3)
        }
    }

    @ViewBuilder private var badge: some View {
        if let text = model.badge(for: item) {
            Text(text.count > 3 ? "•••" : text)
                .font(.system(size: max(10, size * 0.21), weight: .semibold, design: .rounded))
                .modifier(BadgeCapsule(size: size, wide: text.count > 1, fill: settings.badgeColor.gradient))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(x: 4, y: -3)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

@MainActor
enum IconColor {
    private static var cache: [String: Color] = [:]

    // アイコンを描き直したとき（外観の切り替え・アイコンの変更）に色も求め直す
    static func reset() { cache.removeAll() }

    static func average(_ image: NSImage, key: String) -> Color {
        if let c = cache[key] { return c }
        var rgba = [UInt8](repeating: 0, count: 4)
        let color: Color
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let a = max(Double(rgba[3]) / 255, 0.01)
            color = Color(red: min(Double(rgba[0]) / 255 / a, 1), green: min(Double(rgba[1]) / 255 / a, 1), blue: min(Double(rgba[2]) / 255 / a, 1))
        } else {
            color = .gray
        }
        cache[key] = color
        return color
    }
}

// ダウンロードが届いたときの印。跳ねさせず、波紋で静かに知らせる
struct FreshDownloadBadge: View {
    let count: Int
    let size: CGFloat
    @State private var ripple = 0

    var body: some View {
        let d = badgeDiameter(size)
        HStack(spacing: 1) {
            Image(systemName: "arrow.down")
                .font(.system(size: d * 0.5, weight: .bold))
            if count > 1 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: d * 0.55, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .modifier(BadgeCapsule(size: size, wide: count > 1, fill: Color.accentColor.gradient))
        .background {
            Capsule()
                .stroke(Color.accentColor, lineWidth: 2)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: ripple) { view, t in
                    view.scaleEffect(1 + t * 0.9).opacity(t == 0 ? 0 : Double(1 - t))
                } keyframes: { _ in
                    LinearKeyframe(0, duration: 0)
                    CubicKeyframe(1, duration: 0.9)
                    LinearKeyframe(0, duration: 0)
                    CubicKeyframe(1, duration: 0.9)
                }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .offset(x: 4, y: -3)
        .transition(.scale(scale: 0.2).combined(with: .opacity))
        .onAppear { ripple += 1 }
        .onChange(of: count) { ripple += 1 }
    }
}

private func badgeDiameter(_ size: CGFloat) -> CGFloat { max(16, size * 0.34) }

// バッジの丸。数字が増えてもアイコンの幅に押し込まれて折り返さないよう、中身の幅で横に伸ばす
struct BadgeCapsule<Fill: ShapeStyle>: ViewModifier {
    let size: CGFloat
    let wide: Bool
    let fill: Fill

    func body(content: Content) -> some View {
        let d = badgeDiameter(size)
        content
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, wide ? 5 : 0)
            .frame(minWidth: d, minHeight: d)
            .background(Capsule().fill(fill))
    }
}

// 使っていないときは影を付けない（半径 0 の影でも描画の手間がかかるため）
struct IconShadows: ViewModifier {
    let glow: Color
    let glowRadius: CGFloat
    let drop: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .modifier(OptionalShadow(active: glowRadius > 0 && glow != .clear, color: glow, radius: glowRadius, y: 0))
            .modifier(OptionalShadow(active: drop, color: .black.opacity(0.35), radius: size * 0.06, y: size * 0.04))
    }
}

struct OptionalShadow: ViewModifier {
    let active: Bool
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        if active { content.shadow(color: color, radius: radius, y: y) } else { content }
    }
}

// 起動が終わっても途中で止めず、いま跳ねている1回を下まで戻してから止める
struct BounceModifier: ViewModifier {
    let active: Bool
    let position: DockPosition
    let size: CGFloat
    @State private var lift: CGFloat = 0
    @State private var running = false
    // 遅れて実行するクロージャは古い値の構造体を持つため、今の状態は State から読む
    @State private var wanted = false

    func body(content: Content) -> some View {
        content
            .offset(position.inward(lift))
            .onChange(of: active, initial: true) { _, on in
                wanted = on
                if on, !running { bounce() }
            }
    }

    // アニメーションの完了通知は、Dock が隠れて描画されないときなどに届かないことがあるため、時間で進める
    private func bounce() {
        running = true
        withAnimation(.easeOut(duration: 0.28)) { lift = size * 0.45 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeIn(duration: 0.28)) { lift = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if wanted { bounce() } else { running = false }
            }
        }
    }
}

