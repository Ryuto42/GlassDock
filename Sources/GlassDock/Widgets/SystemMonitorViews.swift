import SwiftUI

// MARK: - Tiles

struct GPUTile: View {
    let service: GPUService
    let h: CGFloat

    var body: some View {
        ZStack {
            ProgressRing(progress: service.usage, color: .purple, width: h * 0.09).padding(h * 0.14)
            VStack(spacing: 0) {
                Text(service.available ? "\(Fmt.percent(service.usage))" : "—")
                    .font(.system(size: h * 0.2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("GPU").font(.system(size: h * 0.08, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, h * 0.24)
        }
    }
}

struct MemoryTile: View {
    let service: SystemStatsService
    let h: CGFloat

    var body: some View {
        let color: Color = service.pressureLevel >= 4 ? .red : service.pressureLevel >= 2 ? .orange : .cyan
        ZStack {
            ProgressRing(progress: service.memory, color: color, width: h * 0.09).padding(h * 0.14)
            VStack(spacing: 0) {
                Text(String(format: "%.0f", service.memoryUsedGB))
                    .font(.system(size: h * 0.2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("GB").font(.system(size: h * 0.08, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, h * 0.24)
        }
    }
}

struct ProcessesTile: View {
    let service: ProcessMonitor
    let h: CGFloat

    var body: some View {
        HStack(spacing: h * 0.1) {
            if let top = service.topCPU.first {
                Group {
                    if let icon = ProcessMonitor.icon(for: top.id) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "gearshape.2.fill").resizable().scaledToFit().padding(h * 0.08).foregroundStyle(.secondary)
                    }
                }
                .frame(width: h * 0.5, height: h * 0.5)
                VStack(alignment: .leading, spacing: h * 0.02) {
                    Text(top.name).font(.system(size: h * 0.14, weight: .semibold)).lineLimit(1)
                    Text(String(format: "CPU %.0f%%", top.cpu * 100))
                        .font(.system(size: h * 0.13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(top.cpu > 1.5 ? .orange : .secondary)
                }
                Spacer(minLength: 0)
            } else {
                Image(systemName: "list.bullet.rectangle").font(.system(size: h * 0.3))
                Text("集計中…").font(.system(size: h * 0.14)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, h * 0.12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PeripheralsTile: View {
    let service: PeripheralBatteryService
    let h: CGFloat

    var body: some View {
        HStack(spacing: h * 0.12) {
            if service.devices.isEmpty {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: h * 0.28))
                Text(service.loading ? loc("確認中…") : loc("なし")).font(.system(size: h * 0.14)).lineLimit(1).minimumScaleFactor(0.6)
            } else {
                ForEach(service.devices.prefix(3)) { d in
                    VStack(spacing: h * 0.03) {
                        Image(systemName: PeripheralBatteryService.symbol(for: d))
                            .font(.system(size: h * 0.2))
                            .frame(height: h * 0.26)
                        Text("\(d.level)%")
                            .font(.system(size: h * 0.13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(d.level <= 20 ? .red : .primary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HealthTile: View {
    let service: HealthService
    let h: CGFloat

    var body: some View {
        let level = service.overall
        let symbol = level == .good ? "checkmark.shield.fill" : level == .critical ? "xmark.shield.fill" : "exclamationmark.shield.fill"
        Image(systemName: symbol)
            .font(.system(size: h * 0.42, weight: .semibold))
            .foregroundStyle(Color(nsColor: level.color))
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Details

private struct Caption: View {
    let text: String
    var body: some View { Text(loc(text)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
}

struct GPUDetail: View {
    let service: GPUService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.model.isEmpty ? "GPU" : service.model).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let cores = service.cores {
                        Text(loc("%d コア", cores)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(service.available ? "\(Fmt.percent(service.usage))%" : "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Sparkline(values: service.history, maxValue: 1).fill(.purple.opacity(0.3)).frame(height: 44)
            Caption(text: "直近 1 分の使用率")
        }
        .frame(width: 240)
        .animation(.smooth, value: service.usage)
    }
}

struct MemoryDetail: View {
    let service: SystemStatsService

    var body: some View {
        let total = max(service.memoryTotalGB, 1)
        let parts: [(String, Double, Color)] = [
            ("アプリメモリ", service.appMemoryGB, .cyan),
            ("確保されているメモリ", service.wiredGB, .orange),
            ("圧縮", service.compressedGB, .purple),
        ]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("メモリ").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f / %.0f GB", service.memoryUsedGB, service.memoryTotalGB))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(geo.size.width * part.1 / total, 0))
                    }
                    Rectangle().fill(.primary.opacity(0.1))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            ForEach(parts, id: \.0) { part in
                HStack {
                    Circle().fill(part.2).frame(width: 7, height: 7)
                    Text(loc(part.0)).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f GB", part.1)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                }
            }
            HStack {
                Circle().fill(.primary.opacity(0.25)).frame(width: 7, height: 7)
                Text("キャッシュ").font(.system(size: 12))
                Spacer()
                Text(String(format: "%.1f GB", service.cachedGB)).font(.system(size: 12, design: .rounded)).monospacedDigit()
            }
            Divider()
            HStack {
                Text("スワップ").font(.system(size: 12))
                Spacer()
                Text(String(format: "%.2f GB", service.swapUsedGB)).font(.system(size: 12, design: .rounded)).monospacedDigit()
            }
            HStack {
                Text("メモリプレッシャー").font(.system(size: 12))
                Spacer()
                let p = service.pressureLevel
                Text(p >= 4 ? loc("逼迫") : p >= 2 ? loc("注意") : loc("正常"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p >= 4 ? .red : p >= 2 ? .orange : .green)
            }
            Sparkline(values: service.memoryHistory, maxValue: 1).fill(.cyan.opacity(0.25)).frame(height: 30)
        }
        .frame(width: 250)
    }
}

struct ProcessesDetail: View {
    let service: ProcessMonitor
    @State private var byMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("プロセス").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("", selection: $byMemory) {
                    Text("CPU").tag(false)
                    Text("メモリ").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ForEach(byMemory ? service.topMemory : service.topCPU) { p in
                HStack(spacing: 8) {
                    Group {
                        if let icon = ProcessMonitor.icon(for: p.id) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "gearshape").resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(p.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(byMemory ? Fmt.memory(p.memoryMB * 1_048_576) : String(format: "%.0f%%", p.cpu * 100))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(!byMemory && p.cpu > 1.5 ? .orange : .primary)
                }
                .transition(.opacity)
            }
            if service.topCPU.isEmpty {
                Text("集計中…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(loc("CPU は 1 コア分を 100% として表示します")).font(.system(size: 9)).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 260)
        .animation(.smooth, value: service.topCPU.map(\.id))
    }
}

struct PeripheralsDetail: View {
    let service: PeripheralBatteryService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("周辺機器のバッテリー").font(.system(size: 14, weight: .semibold))
                Spacer()
                if service.loading { ProgressView().controlSize(.small) }
            }
            if service.devices.isEmpty && !service.loading {
                Text("バッテリー残量を取得できる機器が接続されていません")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(service.devices) { d in
                HStack(spacing: 10) {
                    Image(systemName: PeripheralBatteryService.symbol(for: d)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(loc(d.kind)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    ProgressView(value: min(max(Double(d.level) / 100, 0), 1)).frame(width: 60).tint(d.level <= 20 ? .red : .green)
                    Text("\(d.level)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
        .frame(width: 280)
        .onAppear { service.refresh(force: false) }
    }
}

struct HealthDetail: View {
    let service: HealthService

    var body: some View {
        let overall = service.overall
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: overall == .good ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(nsColor: overall.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(overall == .good ? loc("問題は見つかりません") : overall == .critical ? loc("対応が必要です") : loc("注意が必要な項目があります"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("Mac の状態をまとめて確認しています").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Divider()
            ForEach(service.checks) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.symbol).frame(width: 20).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(c.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Circle().fill(Color(nsColor: c.level.color)).frame(width: 8, height: 8).padding(.top, 4)
                }
            }
        }
        .frame(width: 270)
    }
}

struct BatteryHealthRows: View {
    let service: BatteryService

    var body: some View {
        if service.cycleCount != nil || service.healthPercent != nil || service.temperature != nil {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let health = service.healthPercent {
                    row("最大容量", "\(health)%", health < 80 ? .orange : .primary)
                }
                if let cycles = service.cycleCount {
                    row("充放電回数", service.designCycles.map { loc("%d / %d 回", cycles, $0) } ?? loc("%d 回", cycles), .primary)
                }
                if let temp = service.temperature {
                    row("温度", String(format: "%.1f ℃", temp), temp > 40 ? .orange : .primary)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(loc(title)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize().foregroundStyle(color)
        }
    }
}

// MARK: - System overview（システム系の情報をまとめて表示）

struct OverviewTile: View {
    let h: CGFloat

    var body: some View {
        let hub = WidgetHub.shared
        HStack(spacing: h * 0.1) {
            mini("CPU", hub.system.cpu, .green)
            mini("GPU", hub.gpu.usage, .purple)
            mini("MEM", hub.system.memory, hub.system.pressureLevel >= 2 ? .orange : .cyan)
            Circle()
                .fill(Color(nsColor: hub.health.overall.color))
                .frame(width: h * 0.12, height: h * 0.12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mini(_ label: String, _ value: Double, _ color: Color) -> some View {
        ZStack {
            ProgressRing(progress: value, color: color, width: h * 0.06)
            VStack(spacing: 0) {
                Text("\(Fmt.percent(value))")
                    .font(.system(size: h * 0.13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label).font(.system(size: h * 0.065, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, h * 0.06)
        }
        .frame(width: h * 0.5, height: h * 0.5)
    }
}

struct OverviewDetail: View {
    @Namespace private var selectionSpace
    @State private var hovered: OverviewCategory?

    private static let cardSize = CGSize(width: 132, height: 86)
    private static let gridHeight: CGFloat = cardSize.height * 3 + 8 * 2
    private static let columnWidth: CGFloat = 262

    var body: some View {
        let hub = WidgetHub.shared
        let detail = OverviewDetailService.shared
        let checks = hub.health.overviewChecks
        let overall = max(hub.health.overall, checks.map(\.level).max() ?? .good)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: overall == .good ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(nsColor: overall.color))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("システム概要").font(.system(size: 15, weight: .semibold))
                    Text(overall == .good ? loc("問題は見つかりません") : overall == .critical ? loc("対応が必要です") : loc("注意が必要な項目があります"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                LazyVGrid(columns: [GridItem(.fixed(Self.cardSize.width), spacing: 8), GridItem(.fixed(Self.cardSize.width), spacing: 8)], spacing: 8) {
                    card(.cpu, "CPU", String(format: "%.0f%%", hub.system.cpu * 100), .green, history: hub.system.cpuHistory)
                    card(.gpu, "GPU", hub.gpu.available ? String(format: "%.0f%%", hub.gpu.usage * 100) : "—", .purple, history: hub.gpu.history)
                    card(.memory, "メモリ", String(format: "%.1f GB", hub.system.memoryUsedGB),
                         hub.system.pressureLevel >= 2 ? .orange : .cyan, history: hub.system.memoryHistory,
                         sub: String(format: "/ %.0f GB", hub.system.memoryTotalGB))
                    card(.network, "ネットワーク", Fmt.rate(hub.system.down), .blue, history: hub.system.netHistory,
                         sub: "↑ " + Fmt.rate(hub.system.up), scaled: true)
                    let disk = hub.health.diskLevel
                    let diskTotal = hub.system.diskTotal
                    card(.storage, "ストレージ", diskTotal > 0 ? Fmt.storage(hub.system.diskFree) : "—",
                         disk == .good ? .indigo : Color(nsColor: disk.color), history: nil,
                         sub: diskTotal > 0 ? loc("空き / %@", Fmt.storage(diskTotal)) : "",
                         progress: diskTotal > 0 ? 1 - hub.system.diskFree / diskTotal : 0)
                    if hub.battery.hasBattery {
                        card(.battery, "バッテリー", "\(Fmt.percent(hub.battery.level))%", hub.battery.level < 0.2 ? .red : .green, history: nil,
                             sub: hub.battery.healthPercent.map { loc("最大容量 %d%%", $0) } ?? (hub.battery.charging ? loc("充電中") : ""),
                             progress: hub.battery.level)
                    }
                }
                .frame(width: Self.cardSize.width * 2 + 8, height: Self.gridHeight, alignment: .top)

                OverviewInspector(detail: detail)
                    .frame(width: Self.columnWidth - 10, height: Self.gridHeight)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("ヘルスチェック").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                twoColumns {
                    ForEach(checks) { c in
                        HStack(spacing: 7) {
                            Circle().fill(Color(nsColor: c.level.color)).frame(width: 7, height: 7)
                            // 項目名が折り返すと行の高さが変わってパネルが伸び縮みするため 1 行に固定し、値の側を先に省略する
                            Text(c.title).font(.system(size: 11.5)).lineLimit(1).layoutPriority(1)
                            Spacer(minLength: 4)
                            Text(c.detail).font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !hub.peripherals.devices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("周辺機器").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    twoColumns {
                        ForEach(hub.peripherals.devices) { d in
                            HStack(spacing: 7) {
                                Image(systemName: PeripheralBatteryService.symbol(for: d)).font(.system(size: 11)).frame(width: 16)
                                Text(loc("%@（%@）", d.name, loc(d.kind))).font(.system(size: 11.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(d.level)%").font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .monospacedDigit().fixedSize()
                                    .foregroundStyle(d.level <= 20 ? .red : .primary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { detail.attach() }
        .onDisappear { detail.detach() }
    }

    private func twoColumns<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.fixed(Self.columnWidth), spacing: 14), GridItem(.fixed(Self.columnWidth))],
                  alignment: .leading, spacing: 5, content: content)
    }

    private func card(_ category: OverviewCategory, _ title: String, _ value: String, _ color: Color, history: [Double]?,
                      sub: String? = nil, progress: Double? = nil, scaled: Bool = false) -> some View {
        let selected = OverviewDetailService.shared.selection == category
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            Text(loc(title)).font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? color : .secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let sub, !sub.isEmpty {
                Text(sub).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if let history {
                Sparkline(values: history, maxValue: scaled ? nil : 1).fill(color.opacity(selected ? 0.5 : 0.35)).frame(height: 18)
            } else if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(color)
            }
        }
        .padding(9)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(.primary.opacity(hovered == category && !selected ? 0.1 : 0.06))
                if selected {
                    // 選択の縁は matchedGeometryEffect でカード間をすべらせる
                    shape.fill(color.opacity(0.13))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.25)],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
                        .overlay(shape.inset(by: 1.2).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: color.opacity(0.25), radius: 6)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
        }
        .contentShape(shape)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h ? category : (hovered == category ? nil : hovered) }
        }
        .onTapGesture {
            withAnimation(.smooth(duration: 0.35)) { OverviewDetailService.shared.select(category) }
        }
    }
}

// 選んだカードに応じて切り替わる右側の詳細
private struct OverviewInspector: View {
    let detail: OverviewDetailService

    var body: some View {
        let selection = detail.selection
        ZStack(alignment: .topLeading) {
            content(selection)
                .id(selection)
                .transition(.blurReplace)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func content(_ category: OverviewCategory) -> some View {
        let hub = WidgetHub.shared
        let rows = detail.rowsCategory == category ? detail.rows : nil
        switch category {
        case .cpu:
            UsageList(title: "CPU 使用率", symbol: "cpu", color: .green,
                      trailing: loc("%d コア", ProcessInfo.processInfo.activeProcessorCount), rows: rows, limit: 7,
                      empty: "CPU を使っているアプリはありません",
                      note: "1 コア分を 100% として表示（ヘルパーは親アプリに合算）",
                      format: { String(format: "%.0f%%", $0 * 100) }, warn: { $0 > 1.5 })
        case .gpu:
            UsageList(title: "GPU 使用率", symbol: "cpu.fill", color: .purple,
                      trailing: gpuSummary(hub.gpu),
                      rows: rows, limit: 7,
                      empty: "GPU を使っているアプリはありません",
                      note: "GPU の処理時間に占める割合",
                      format: { $0 < 0.005 ? "<1%" : String(format: "%.0f%%", $0 * 100) }, warn: { $0 > 0.8 })
        case .memory:
            let p = hub.system.pressureLevel
            UsageList(title: "メモリ使用量", symbol: "memorychip", color: .cyan,
                      trailing: loc("プレッシャー %@", p >= 4 ? loc("逼迫") : p >= 2 ? loc("注意") : loc("正常")), rows: rows, limit: 7,
                      empty: "集計できませんでした",
                      note: "メモリフットプリント（他のユーザーのプロセスを除く）",
                      format: { Fmt.memory($0) }, warn: { $0 > 4_000_000_000 })
        case .battery:
            let b = hub.battery
            UsageList(title: "エネルギー使用量", symbol: "bolt.fill", color: .yellow,
                      trailing: b.charging ? loc("充電中") : b.pluggedIn ? loc("電源に接続") : b.minutesLeft.map { loc("残り %d:%02d", $0 / 60, $0 % 60) } ?? "",
                      rows: rows, limit: 7,
                      empty: "エネルギーを使っているアプリはありません",
                      note: "CPU などの推定消費電力（直近数秒の平均）",
                      format: { Self.power($0) }, warn: { $0 > 3 })
        case .network:
            NetworkInspector(detail: detail)
        case .storage:
            StorageInspector(detail: detail, rows: rows)
        }
    }

    private func gpuSummary(_ gpu: GPUService) -> String {
        let parts = [gpu.model, gpu.cores.map { loc("%d コア", $0) }].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.count == 2 ? loc("%@・%@", parts[0], parts[1]) : parts.joined()
    }

    static func power(_ w: Double) -> String {
        // 0.9996 W が「1000 mW」にならないよう、丸めたあとの値で単位を決める
        w >= 0.9995 ? String(format: "%.1f W", w) : String(format: "%.0f mW", max(w * 1000, 1))
    }
}

private struct InspectorHeader: View {
    let title: String
    let symbol: String
    let color: Color
    var trailing = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(loc(title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct UsageList: View {
    let title: String
    let symbol: String
    let color: Color
    var trailing = ""
    let rows: [UsageRow]?
    let limit: Int
    let empty: String
    var note: String?
    let format: (Double) -> String
    let warn: (Double) -> Bool
    var showHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showHeader {
                InspectorHeader(title: title, symbol: symbol, color: color, trailing: trailing).padding(.bottom, 3)
            }
            if let rows {
                let shown = Array(rows.prefix(limit))
                let top = max(shown.first?.value ?? 1, .leastNonzeroMagnitude)
                ForEach(shown) { row in
                    UsageRowView(row: row, fraction: row.value / top, color: color, value: format(row.value), warn: warn(row.value))
                        .transition(.opacity)
                }
                if shown.isEmpty {
                    Text(loc(empty)).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("集計中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            if let note, showHeader {
                Spacer(minLength: 0)
                Text(loc(note)).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .animation(.smooth(duration: 0.4), value: rows)
    }
}

private struct UsageRowView: View {
    let row: UsageRow
    let fraction: Double
    let color: Color
    let value: String
    let warn: Bool

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let icon = OverviewDetailService.icon(for: row.id) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(row.name).font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warn ? .orange : .primary)
                .fixedSize()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.16))
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 6))
            }
        }
    }
}

private struct NetworkInspector: View {
    let detail: OverviewDetailService

    var body: some View {
        let top = max(detail.downHistory.max() ?? 0, detail.upHistory.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 7) {
            InspectorHeader(title: "ネットワーク", symbol: "network", color: .blue)
            HStack(spacing: 12) {
                legend("arrow.down", .blue, detail.netDown)
                legend("arrow.up", .orange, detail.netUp)
            }
            ZStack {
                Sparkline(values: detail.downHistory, maxValue: top).fill(.blue.opacity(0.32))
                Sparkline(values: detail.upHistory, maxValue: top).fill(.orange.opacity(0.32))
            }
            .frame(height: 44)
            .animation(.smooth, value: detail.downHistory)
            Divider().padding(.vertical, 2)
            ForEach(detail.interfaces) { i in
                HStack(spacing: 8) {
                    Image(systemName: i.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(i.name).font(.system(size: 11.5)).lineLimit(1)
                        Text(i.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("↓ " + Fmt.rate(i.down))
                        Text("↑ " + Fmt.rate(i.up))
                    }
                    .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            }
            if detail.interfaces.isEmpty {
                Text("接続中のネットワークはありません").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ symbol: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(Fmt.rate(value))
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}

private struct StorageInspector: View {
    let detail: OverviewDetailService
    let rows: [UsageRow]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorHeader(title: "ストレージ", symbol: "internaldrive", color: .indigo)
            ForEach(detail.volumes) { v in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: v.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(v.name).font(.system(size: 11.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(loc("%@ 空き / %@", Fmt.storage(v.free), Fmt.storage(v.total)))
                            .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).layoutPriority(1)
                    }
                    let used = v.total > 0 ? 1 - v.free / v.total : 0
                    Capsule().fill(.primary.opacity(0.1)).frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(used > 0.9 ? Color.orange : Color.indigo).frame(width: geo.size.width * min(max(used, 0), 1))
                            }
                        }
                }
            }
            if detail.volumes.isEmpty {
                Text("確認中…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(Fmt.rate(detail.diskRead), systemImage: "arrow.down.doc")
                Label(Fmt.rate(detail.diskWrite), systemImage: "square.and.arrow.down")
            }
            .font(.system(size: 10.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            .padding(.top, 2)
            Divider().padding(.vertical, 1)
            Text("ディスクを読み書きしているアプリ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            UsageList(title: "", symbol: "", color: .indigo, rows: rows, limit: 3,
                      empty: "読み書きしているアプリはありません",
                      format: { Fmt.rate($0) }, warn: { $0 > 100_000_000 }, showHeader: false)
        }
    }
}
