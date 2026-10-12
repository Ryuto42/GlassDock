import SwiftUI

// ウィジェットにホバーしたときにグラスパネルの中に出す詳細表示
struct WidgetDetail: View {
    let kind: WidgetKind

    var body: some View {
        let hub = WidgetHub.shared
        Group {
            switch kind {
            case .analogClock, .digitalClock, .worldClock, .dayProgress: ClockDetail()
            case .calendar: CalendarDetail(service: hub.calendar)
            case .agenda: AgendaDetail(service: hub.calendar)
            case .reminders: RemindersDetail(service: hub.calendar)
            case .weather, .weatherCompact: WeatherDetail(service: hub.weather)
            case .nowPlaying: NowPlayingDetail(service: hub.media)
            case .volume: VolumeDetail(service: hub.volume)
            case .systemMonitor, .storage, .network: SystemDetail(service: hub.system)
            case .battery: BatteryDetail(service: hub.battery)
            case .pomodoro: PomodoroDetail(service: hub.pomodoro)
            case .quickNote: QuickNoteDetail(store: hub.notes)
            case .clipboard: ClipboardDetail(service: hub.clipboard)
            case .colorPicker: ColorPickerDetail(service: hub.colors)
            case .gpu: GPUDetail(service: hub.gpu)
            case .memory: MemoryDetail(service: hub.system)
            case .processes: ProcessesDetail(service: hub.processes)
            case .peripherals: PeripheralsDetail(service: hub.peripherals)
            case .health: HealthDetail(service: hub.health)
            case .overview: OverviewDetail()
            }
        }
        .padding(4)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(loc(text)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct PillButton: View {
    let symbol: String
    var size: CGFloat = 30
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? .white : .primary)
            .background(Circle().fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(hovering ? 0.16 : 0.08))))
            .scaleEffect(hovering ? 1.06 : 1)
            .contentShape(Circle())
            .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
            .onTapGesture(perform: action)
    }
}

private struct ClockDetail: View {
    private var settings: DockSettings { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.date, format: .dateTime.hour(settings.clock24h ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)).minute().second())
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.year().month().day().weekday(.wide))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    let p = DayProgress.value(ctx.date)
                    SectionTitle(text: loc("今日の経過 %d%%", Int(p * 100)))
                    ProgressView(value: p).tint(.mint)
                }
                if !settings.worldClocks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "世界時計")
                        ForEach(settings.worldClocks.compactMap(TimeZone.init(identifier:)), id: \.identifier) { tz in
                            HStack {
                                Text(WorldClock.city(tz)).font(.system(size: 13, weight: .medium))
                                Text(WorldClock.offset(ctx.date, tz)).font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Text(WorldClock.time(ctx.date, tz, h24: settings.clock24h))
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
        }
    }
}

private struct CalendarDetail: View {
    let service: CalendarService

    var body: some View {
        let cal = Calendar.current
        let selected = service.selectedDay
        let dayEvents = service.events(on: selected)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(service.shownMonth, format: .dateTime.year().month(.wide)).font(.system(size: 15, weight: .semibold))
                Spacer()
                PillButton(symbol: "chevron.left", size: 24) { shift(-1) }
                PillButton(symbol: "circle.fill", size: 24) { goToday() }
                PillButton(symbol: "chevron.right", size: 24) { shift(1) }
            }
            MonthGrid(month: service.shownMonth, selected: selected, marked: service.markedDays) { day in
                withAnimation(.spring(duration: 0.25)) { service.selectedDay = day }
            }
            Divider()
            SectionTitle(text: cal.isDateInToday(selected) ? loc("今日") : selected.formatted(.dateTime.month().day().weekday(.wide)))
            if !service.eventAccess {
                Text("設定 > プライバシーとセキュリティ > カレンダー で GlassDock を許可してください")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if dayEvents.isEmpty {
                Text("予定はありません").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(dayEvents.prefix(5)) { EventRow(event: $0) }
                if dayEvents.count > 5 {
                    Text(loc("ほか %d 件", dayEvents.count - 5)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 260)
    }

    private func shift(_ m: Int) {
        let cal = Calendar.current
        guard let month = cal.date(byAdding: .month, value: m, to: service.shownMonth) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            service.shownMonth = month
            // 月を移ったら、その月の1日（今月なら今日）を選ぶ
            service.selectedDay = cal.isDate(month, equalTo: Date(), toGranularity: .month)
                ? cal.startOfDay(for: Date())
                : cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        }
        service.loadMonth(month)
    }

    private func goToday() {
        withAnimation(.smooth(duration: 0.25)) { service.resetSelection() }
    }
}

private struct MonthGrid: View {
    let month: Date
    let selected: Date
    let marked: Set<Date>
    let onSelect: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: start)!.count
        let cells: [Date?] = Array(repeating: nil, count: lead) + (0..<days).map { cal.date(byAdding: .day, value: $0, to: start) }
        let symbols = cal.veryShortWeekdaySymbols
        let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                if let d {
                    DayCell(date: d, today: cal.isDateInToday(d), selected: cal.isDate(d, inSameDayAs: selected),
                            marked: marked.contains(cal.startOfDay(for: d))) { onSelect(d) }
                } else {
                    Color.clear.frame(height: 28)
                }
            }
        }
    }
}

private struct DayCell: View {
    let date: Date
    let today: Bool
    let selected: Bool
    let marked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 1) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 12, weight: today || selected ? .bold : .regular, design: .rounded))
                .foregroundStyle(selected ? .white : today ? .red : .primary)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(selected ? AnyShapeStyle(today ? Color.red : Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.1 : 0)))
                }
            Circle().fill(marked ? Color.secondary : .clear).frame(width: 3, height: 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

private struct EventRow: View {
    let event: CalendarService.Event

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(event.allDay ? loc("終日") : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AgendaDetail: View {
    let service: CalendarService

    var body: some View {
        let upcoming = service.events.filter { $0.end > Date() }
        let groups = Dictionary(grouping: upcoming.prefix(20)) { Calendar.current.startOfDay(for: $0.start) }
        VStack(alignment: .leading, spacing: 10) {
            if let next = service.nextEvent {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Agenda.relative(next, now: Date())).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: next.color))
                    Text(next.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    if let place = next.location, !place.isEmpty {
                        Label(place, systemImage: "mappin.and.ellipse").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Divider()
            }
            if upcoming.isEmpty {
                Text(service.eventAccess ? loc("今後2週間の予定はありません") : loc("カレンダーへのアクセスが許可されていません"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted().prefix(4), id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: day.formatted(.dateTime.month().day().weekday(.wide)))
                    ForEach(groups[day] ?? []) { EventRow(event: $0) }
                }
            }
        }
        .frame(width: 270)
    }
}

private struct RemindersDetail: View {
    let service: CalendarService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("リマインダー").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(service.reminders.count)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
            }
            if !service.reminderAccess {
                Text("リマインダーへのアクセスが許可されていません").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if service.reminders.isEmpty {
                Text("すべて完了しました 🎉").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(service.reminders.prefix(8)) { r in
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(nsColor: r.color))
                        .onTapGesture { withAnimation(.spring) { service.complete(r) } }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if let due = r.due {
                            Text(due.formatted(.dateTime.month().day().hour().minute()))
                                .font(.system(size: 10))
                                .foregroundStyle(due < Date() ? .red : .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 250)
    }
}

private struct WeatherDetail: View {
    let service: WeatherService
    private var settings: DockSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = service.snapshot {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.place.isEmpty ? loc("現在地") : s.place).font(.system(size: 14, weight: .semibold))
                        Text("\(Int(s.temp.rounded()))°").font(.system(size: 46, weight: .light, design: .rounded))
                        Text(WeatherService.describe(s.code)).font(.system(size: 12, weight: .medium))
                        if let d = s.days.first {
                            Text(loc("最高 %d°  最低 %d°", Int(d.max.rounded()), Int(d.min.rounded()))).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: WeatherService.symbol(s.code, day: s.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 44))
                }
                HStack(spacing: 14) {
                    Label(loc("体感 %d°", Int(s.feels.rounded())), systemImage: "thermometer.medium")
                    Label("\(s.humidity)%", systemImage: "humidity.fill")
                    Label("\(Int(s.wind.rounded()))km/h", systemImage: "wind")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(s.hours) { h in
                            VStack(spacing: 5) {
                                Text(h.id, format: .dateTime.hour()).font(.system(size: 10)).foregroundStyle(.secondary)
                                Image(systemName: WeatherService.symbol(h.code, day: h.isDay))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 15)).frame(height: 18)
                                Text("\(Int(h.temp.rounded()))°").font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                }
                Divider()
                let lo = s.days.map(\.min).min() ?? 0, hi = s.days.map(\.max).max() ?? 1
                VStack(spacing: 6) {
                    ForEach(s.days) { d in
                        HStack(spacing: 8) {
                            Text(Calendar.current.isDateInToday(d.id) ? loc("今日") : d.id.formatted(.dateTime.weekday(.short)))
                                .font(.system(size: 12, weight: .medium)).frame(width: 30, alignment: .leading)
                            Image(systemName: WeatherService.symbol(d.code)).symbolRenderingMode(.multicolor)
                                .font(.system(size: 13)).frame(width: 22)
                            Text(d.rain > 0 ? "\(d.rain)%" : "").font(.system(size: 10)).foregroundStyle(.cyan).frame(width: 28)
                            Text("\(Int(d.min.rounded()))°").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 26)
                            TemperatureBar(lo: lo, hi: hi, min: d.min, max: d.max)
                            Text("\(Int(d.max.rounded()))°").font(.system(size: 11, weight: .medium)).frame(width: 26)
                        }
                    }
                }
                if let rise = s.sunrise, let set = s.sunset {
                    HStack {
                        Label(rise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill")
                        Spacer()
                        Label(set.formatted(date: .omitted, time: .shortened), systemImage: "sunset.fill")
                    }
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Text("天気データ: Open-Meteo").font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                Label(service.status, systemImage: "cloud.sun").font(.system(size: 13))
            }
        }
        .frame(width: 290)
    }
}

private struct TemperatureBar: View {
    let lo: Double, hi: Double, min: Double, max: Double

    var body: some View {
        GeometryReader { geo in
            let span = Swift.max(hi - lo, 1)
            let x0 = (min - lo) / span * geo.size.width
            let x1 = (max - lo) / span * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: Swift.max(x1 - x0, 6))
                    .offset(x: x0)
            }
        }
        .frame(height: 4)
    }
}

private struct NowPlayingDetail: View {
    let service: NowPlayingService

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let art = service.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 50, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .scaleEffect(service.isPlaying ? 1 : 0.92)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: service.isPlaying)
            .onTapGesture { service.openPlayer() }

            VStack(spacing: 2) {
                Text(service.title.isEmpty ? loc("再生していません") : service.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([service.artist, service.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 18) {
                PillButton(symbol: "backward.fill", size: 34) { service.send(.previous) }
                PillButton(symbol: service.isPlaying ? "pause.fill" : "play.fill", size: 44, prominent: true) { service.send(.playPause) }
                PillButton(symbol: "forward.fill", size: 34) { service.send(.next) }
            }
            if let p = service.player {
                Text(p == "Spotify" ? "Spotify" : loc("ミュージック")).font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Text("Spotify かミュージックで再生すると表示されます").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 240)
    }
}

private struct VolumeDetail: View {
    let service: VolumeService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("サウンド").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int(service.volume * 100))%").font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 10) {
                PillButton(symbol: service.symbol, size: 30) { service.toggleMute() }
                Slider(value: Binding(get: { Double(service.volume) }, set: { service.set(Float($0)) }), in: 0...1)
            }
        }
        .frame(width: 240)
        .onAppear { service.refresh() }
    }
}

private struct SystemDetail: View {
    let service: SystemStatsService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            metric("CPU", "\(Int(service.cpu * 100))%", service.cpu, .green, history: service.cpuHistory)
            metric("メモリ", String(format: "%.1f / %.0f GB", service.memoryUsedGB, service.memoryTotalGB), service.memory, .cyan, history: nil)
            let used = service.diskTotal > 0 ? 1 - service.diskFree / service.diskTotal : 0
            metric("ストレージ", loc("%.0f GB 空き / %.0f GB", service.diskFree, service.diskTotal), used, .indigo, history: nil)
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: "ネットワーク")
                HStack {
                    Label(SystemStatsService.rate(service.down), systemImage: "arrow.down").foregroundStyle(.cyan)
                    Spacer()
                    Label(SystemStatsService.rate(service.up), systemImage: "arrow.up").foregroundStyle(.pink)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                Sparkline(values: service.netHistory).fill(.cyan.opacity(0.25)).frame(height: 28)
            }
        }
        .frame(width: 260)
        .animation(.smooth, value: service.cpu)
    }

    private func metric(_ title: String, _ value: String, _ p: Double, _ color: Color, history: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(text: title)
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let history {
                Sparkline(values: history, maxValue: 1).fill(color.opacity(0.3)).frame(height: 28)
            }
            ProgressView(value: min(max(p, 0), 1)).tint(color)
        }
    }
}

private struct BatteryDetail: View {
    let service: BatteryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: service.level, color: service.level < 0.2 && !service.charging ? .red : .green, width: 7)
                Image(systemName: service.symbol).font(.system(size: 18))
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Int(service.level * 100))%").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(service.charging ? loc("充電中") : service.pluggedIn ? loc("電源に接続中") : loc("バッテリー駆動"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let m = service.minutesLeft, !service.pluggedIn {
                    Text(loc("残り約 %d 時間 %d 分", m / 60, m % 60)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        BatteryHealthRows(service: service)
        }
        .frame(width: 220, alignment: .leading)
    }
}

private struct PomodoroDetail: View {
    let service: PomodoroService
    private var settings: DockSettings { .shared }

    var body: some View {
        let color: Color = service.phase == .focus ? .red : .green
        VStack(spacing: 14) {
            Text(service.phase == .focus ? loc("集中") : loc("休憩")).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            ZStack {
                ProgressRing(progress: service.progress, color: color, width: 10)
                Text(service.label).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 150, height: 150)
            .animation(.smooth, value: service.remaining)
            HStack(spacing: 16) {
                PillButton(symbol: "arrow.counterclockwise", size: 32) { service.reset() }
                PillButton(symbol: service.running ? "pause.fill" : "play.fill", size: 44, prominent: true) { service.toggle() }
                PillButton(symbol: "forward.end.fill", size: 32) { service.skip() }
            }
            .tint(color)
            Text(loc("完了 %d 回 ・ 集中 %d 分 / 休憩 %d 分", service.completed, Int(settings.focusMinutes), Int(settings.breakMinutes)))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 230)
    }
}

private struct QuickNoteDetail: View {
    @Bindable var store: QuickNoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("クイックメモ").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(loc("%d 文字", store.text.count)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            TextEditor(text: $store.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
                .frame(width: 280, height: 170)
        }
    }
}

private struct ClipboardDetail: View {
    let service: ClipboardService
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("クリップボード").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !service.items.isEmpty {
                    Text("消去").font(.system(size: 11)).foregroundStyle(.secondary).onTapGesture { service.clear() }
                }
            }
            if service.items.isEmpty {
                Text("テキストをコピーするとここに残ります").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(service.items.prefix(8), id: \.self) { item in
                HStack {
                    Text(item).font(.system(size: 12)).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: copied == item ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11)).foregroundStyle(copied == item ? .green : .secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
                .contentShape(Rectangle())
                .onTapGesture {
                    service.copy(item)
                    withAnimation { copied = item }
                }
            }
        }
        .frame(width: 270)
    }
}

private struct ColorPickerDetail: View {
    let service: ColorPickerService
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("カラーピッカー").font(.system(size: 14, weight: .semibold))
                Spacer()
                PillButton(symbol: "eyedropper", size: 30, prominent: true) { service.pick() }
            }
            if service.history.isEmpty {
                Text("スポイトで画面の色を取得すると HEX がコピーされます").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 8), count: 4), spacing: 8) {
                ForEach(service.history, id: \.self) { hex in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: hex)).frame(height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                        Text(copied == hex ? loc("コピー済") : hex).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        service.copy(hex)
                        withAnimation { copied = hex }
                    }
                }
            }
        }
        .frame(width: 240)
    }
}
