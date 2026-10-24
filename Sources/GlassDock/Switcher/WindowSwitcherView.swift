import SwiftUI

struct WindowSwitcherRootView: View {
    let state: SwitcherState

    var body: some View {
        ZStack {
            if state.visible {
                SwitcherPanelView(state: state)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(DockSettings.shared)
    }
}

private struct SwitcherPanelView: View {
    let state: SwitcherState

    var body: some View {
        let items = state.items
        let columns = state.columns
        let width = items.isEmpty
            ? state.cardSize.width * 1.5
            : CGFloat(columns) * state.cardSize.width + CGFloat(columns - 1) * SwitcherState.spacing
        VStack(spacing: 12) {
            searchPill(maxWidth: width)
            if items.isEmpty {
                Text(state.query.isEmpty ? loc("ウィンドウがありません") : loc("一致するウィンドウがありません"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: 80)
            } else {
                grid(items, columns: columns, width: width)
            }
        }
        .padding(16)
        .background(AppGlass(cornerRadius: 28))
        .fixedSize()
    }

    // 長く入力してもパネルが横に広がらないよう、カードの列の幅で打ち切り、入力した末尾を見せる
    private func searchPill(maxWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
            if state.query.isEmpty {
                Text(state.searching ? loc("検索…") : loc("/ で検索"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(state.query)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minWidth: 160, maxWidth: max(160, maxWidth))
        .background(Capsule().fill(.primary.opacity(state.searching ? 0.12 : 0.07)))
        .overlay {
            if state.searching { Capsule().strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.7), lineWidth: 1) }
        }
    }

    private func grid(_ items: [WindowInfo], columns: Int, width: CGFloat) -> some View {
        let card = state.cardSize
        let spacing = SwitcherState.spacing
        let rows = (items.count + columns - 1) / columns
        let contentHeight = CGFloat(rows) * card.height + CGFloat(rows - 1) * spacing
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(card.width), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(items) { window in
                        SwitcherCard(window: window, state: state, selected: window.id == state.selectedID)
                            .id(window.id)
                    }
                }
            }
            .scrollDisabled(contentHeight <= state.maxGridHeight)
            .scrollIndicators(.never)
            .frame(width: width, height: min(contentHeight, state.maxGridHeight))
            .onChange(of: state.selectedID) { _, id in
                guard let id, contentHeight > state.maxGridHeight else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct SwitcherCard: View {
    let window: WindowInfo
    let state: SwitcherState
    let selected: Bool

    var body: some View {
        let size = state.cardSize
        let icon = state.icons[window.pid]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(state.appNames[window.pid] ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !window.title.isEmpty {
                    Text(window.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: state.cardWidth, height: SwitcherState.headerHeight, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.06))
                if let image = state.thumbnails[window.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                        .padding(5)
                        .transition(.opacity)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: state.thumbHeight * 0.45, height: state.thumbHeight * 0.45)
                        .opacity(window.isOnScreen ? 0.85 : 0.6)
                }
                if !window.isOnScreen {
                    Label(window.isMinimized ? loc("最小化中") : loc("非表示"), systemImage: window.isMinimized ? "minus" : "eye.slash")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppGlass(cornerRadius: 9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(7)
                }
            }
            .frame(width: state.cardWidth, height: state.thumbHeight)
        }
        .padding(SwitcherState.cardPadding)
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.primary.opacity(selected ? 0.1 : 0))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onContinuousHover { phase in
            if case .active = phase { WindowSwitcher.shared.hover(window.id) }
        }
        .onTapGesture { WindowSwitcher.shared.commit(window.id) }
    }
}
