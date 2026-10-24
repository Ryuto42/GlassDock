import SwiftUI

// Dock に並ぶウィジェット本体。size はアイコン1個分の大きさ
struct WidgetTile: View {
    let kind: WidgetKind
    let size: CGFloat

    var body: some View {
        let inset = size * 0.08
        let w = size * kind.widthFactor - inset * 2
        let h = size - inset * 2
        content(w: w, h: h)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: h * 0.24, style: .continuous))
            .background(AppGlass(cornerRadius: h * 0.24))
            .padding(inset)
    }

    @ViewBuilder private func content(w: CGFloat, h: CGFloat) -> some View {
        let hub = WidgetHub.shared
        switch kind {
        case .analogClock: AnalogClockTile(h: h)
        case .digitalClock: DigitalClockTile(h: h)
        case .worldClock: WorldClockTile(h: h)
        case .dayProgress: DayProgressTile(h: h)
        case .calendar: CalendarTile(h: h)
        case .agenda: AgendaTile(service: hub.calendar, h: h)
        case .reminders: RemindersTile(service: hub.calendar, h: h)
        case .weather: WeatherTile(service: hub.weather, h: h, compact: false)
        case .weatherCompact: WeatherTile(service: hub.weather, h: h, compact: true)
        case .nowPlaying: NowPlayingTile(service: hub.media, h: h)
        case .volume: VolumeTile(service: hub.volume, h: h)
        case .systemMonitor: SystemTile(service: hub.system, h: h)
        case .battery: BatteryTile(service: hub.battery, h: h)
        case .storage: StorageTile(service: hub.system, h: h)
        case .network: NetworkTile(service: hub.system, h: h)
        case .pomodoro: PomodoroTile(service: hub.pomodoro, h: h)
        case .quickNote: QuickNoteTile(store: hub.notes, h: h)
        case .clipboard: ClipboardTile(service: hub.clipboard, h: h)
        case .colorPicker: ColorPickerTile(service: hub.colors, h: h)
        case .gpu: GPUTile(service: hub.gpu, h: h)
        case .memory: MemoryTile(service: hub.system, h: h)
        case .processes: ProcessesTile(service: hub.processes, h: h)
        case .peripherals: PeripheralsTile(service: hub.peripherals, h: h)
        case .health: HealthTile(service: hub.health, h: h)
        case .overview: OverviewTile(h: h)
        }
    }
}

struct AnalogClockTile: View {
    let h: CGFloat
    private var settings: DockSettings { .shared }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: settings.clockSeconds ? 1 : 15)) { ctx in
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: ctx.date)
            let hr = Double(comps.hour ?? 0), mn = Double(comps.minute ?? 0), sc = Double(comps.second ?? 0)
            let face: Color = .clear
            let ink: Color = scheme == .dark ? .white : .black
            ZStack {
                face
                ForEach(0..<12) { i in
                    Capsule().fill(ink.opacity(i % 3 == 0 ? 0.9 : 0.35))
                        .frame(width: h * (i % 3 == 0 ? 0.035 : 0.022), height: h * 0.08)
                        .offset(y: -h * 0.4)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
                hand(width: 0.06, length: 0.26, angle: (hr.truncatingRemainder(dividingBy: 12) + mn / 60) * 30, color: ink)
                hand(width: 0.04, length: 0.38, angle: (mn + sc / 60) * 6, color: ink)
                if settings.clockSeconds {
                    hand(width: 0.018, length: 0.4, angle: sc * 6, color: .orange)
                }
                Circle().fill(.orange).frame(width: h * 0.07)
            }
        }
    }

    private func hand(width: CGFloat, length: CGFloat, angle: Double, color: Color) -> some View {
        Capsule().fill(color)
            .frame(width: h * width, height: h * length)
            .offset(y: -h * length / 2)
            .rotationEffect(.degrees(angle))
    }
}

struct DigitalClockTile: View {
    let h: CGFloat
    private var settings: DockSettings { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: settings.clockSeconds ? 1 : 10)) { ctx in
            VStack(spacing: h * 0.02) {
                Text(ctx.date, format: ClockFormat.time(seconds: settings.clockSeconds, h24: settings.clock24h))
                    .font(.system(size: h * 0.36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(ctx.date, format: .dateTime.month(.defaultDigits).day().weekday(.short))
                    .font(.system(size: h * 0.14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, h * 0.08)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum ClockFormat {
    // Date.FormatStyle の hour はロケールの 12/24 時間制に従い、設定を無視してしまう（英語で 24 時間制にしても「01:05」になる）。
    // 設定に合わせて時間制を固定したロケールで書式化する
    static func locale(h24: Bool) -> Locale {
        var c = Locale.Components(locale: .current)
        c.hourCycle = h24 ? .zeroToTwentyThree : .oneToTwelve
        return Locale(components: c)
    }

    static func time(seconds: Bool, h24: Bool) -> Date.FormatStyle {
        var f = Date.FormatStyle.dateTime.hour(h24 ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        if seconds { f = f.second(.twoDigits) }
        return f.locale(locale(h24: h24))
    }
}

struct WorldClockTile: View {
    let h: CGFloat
    private var settings: DockSettings { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let zones = settings.worldClocks.compactMap(TimeZone.init(identifier:)).prefix(2)
            HStack(spacing: h * 0.12) {
                ForEach(Array(zones), id: \.identifier) { tz in
                    VStack(spacing: 0) {
                        Text(WorldClock.city(tz))
                            .font(.system(size: h * 0.13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(WorldClock.time(ctx.date, tz, h24: settings.clock24h))
                            .font(.system(size: h * 0.27, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(WorldClock.offset(ctx.date, tz))
                            .font(.system(size: h * 0.11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum WorldClock {
    static func city(_ tz: TimeZone) -> String {
        let fallback = tz.identifier.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? tz.identifier
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("ja") == true else { return fallback }
        return tz.localizedName(for: .generic, locale: Locale(identifier: "ja_JP"))?
            .replacingOccurrences(of: "時間", with: "")
            .replacingOccurrences(of: "標準", with: "")
            ?? fallback
    }

    static func time(_ date: Date, _ tz: TimeZone, h24: Bool) -> String {
        var f = Date.FormatStyle.dateTime.hour(h24 ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(ClockFormat.locale(h24: h24))
        f.timeZone = tz
        return date.formatted(f)
    }

    static func offset(_ date: Date, _ tz: TimeZone) -> String {
        let minutes = (tz.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 60
        // 日だけの引き算だと月末（31 日と 1 日）で逆になるため、年月日で比べる
        let cal = Calendar.current
        let there = cal.dateComponents(in: tz, from: date), here = cal.dateComponents(in: .current, from: date)
        let a = (there.year ?? 0, there.month ?? 0, there.day ?? 0), b = (here.year ?? 0, here.month ?? 0, here.day ?? 0)
        let dayText = a > b ? loc("明日") : a < b ? loc("昨日") : loc("今日")
        let sign = minutes < 0 ? "-" : "+"
        // インド（+5:30）など 30 分単位の時差もある
        let h = abs(minutes) / 60, m = abs(minutes) % 60
        return m == 0 ? loc("%@ %@%d時間", dayText, sign, h) : loc("%@ %@%d時間%d分", dayText, sign, h, m)
    }
}

struct ProgressRing: View {
    let progress: Double
    let color: Color
    let width: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: width)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct DayProgressTile: View {
    let h: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let p = DayProgress.value(ctx.date)
            ZStack {
                ProgressRing(progress: p, color: .mint, width: h * 0.1)
                    .padding(h * 0.14)
                Text("\(Fmt.percent(p))%")
                    .font(.system(size: h * 0.2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, h * 0.24)
            }
        }
    }
}

enum DayProgress {
    // 夏時間の切り替え日は 1 日が 23・25 時間になるため、86400 秒で割らない
    static func value(_ date: Date) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start), end > start else { return 0 }
        return min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }
}

struct CalendarTile: View {
    let h: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            VStack(spacing: 0) {
                Text(ctx.date, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: h * 0.17, weight: .semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, h * 0.08)
                Text("\(Calendar.current.component(.day, from: ctx.date))")
                    .font(.system(size: h * 0.5, weight: .light))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AgendaTile: View {
    let service: CalendarService
    let h: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(spacing: h * 0.1) {
                if let e = service.nextEvent {
                    Capsule().fill(Color(nsColor: e.color)).frame(width: h * 0.06)
                    VStack(alignment: .leading, spacing: h * 0.02) {
                        Text(Agenda.relative(e, now: ctx.date))
                            .font(.system(size: h * 0.13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: e.color))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(e.title)
                            .font(.system(size: h * 0.17, weight: .semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: h * 0.3))
                    Text(service.eventAccess ? loc("予定なし") : loc("未許可")).font(.system(size: h * 0.16, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, h * 0.14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum Agenda {
    static func relative(_ e: CalendarService.Event, now: Date) -> String {
        if e.allDay { return loc("終日") }
        if e.start <= now { return loc("進行中") }
        let mins = max(0, Int(e.start.timeIntervalSince(now) / 60))
        if mins < 60 { return loc("あと%d分", mins) }
        if Calendar.current.isDateInToday(e.start) { return e.start.formatted(date: .omitted, time: .shortened) }
        return e.start.formatted(.dateTime.month().day().hour().minute())
    }
}

struct RemindersTile: View {
    let service: CalendarService
    let h: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "checklist")
                .font(.system(size: h * 0.4, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if service.reminderCount > 0 {
                // 2 桁以上でも折り返さないよう 1 行に固定する
                Text(service.reminderCount > 99 ? "99+" : "\(service.reminderCount)")
                    .font(.system(size: h * 0.17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, h * 0.06)
                    .frame(minWidth: h * 0.22)
                    .background(Capsule().fill(.orange))
                    .padding(h * 0.08)
            }
        }
    }
}

struct WeatherTile: View {
    let service: WeatherService
    let h: CGFloat
    let compact: Bool

    var body: some View {
        let s = service.snapshot
        Group {
            if let s {
                if compact {
                    VStack(spacing: 0) {
                        Image(systemName: WeatherService.symbol(s.code, day: s.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: h * 0.3))
                        Text("\(Int(s.temp.rounded()))°")
                            .font(.system(size: h * 0.26, weight: .semibold, design: .rounded))
                    }
                } else {
                    HStack(spacing: h * 0.1) {
                        Image(systemName: WeatherService.symbol(s.code, day: s.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: h * 0.42))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(s.temp.rounded()))°")
                                .font(.system(size: h * 0.34, weight: .semibold, design: .rounded))
                            Text(s.place.isEmpty ? WeatherService.describe(s.code) : s.place)
                                .font(.system(size: h * 0.13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: h * 0.4))
            }
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NowPlayingTile: View {
    let service: NowPlayingService
    let h: CGFloat

    var body: some View {
        HStack(spacing: h * 0.1) {
            ZStack {
                if let art = service.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: h * 0.28, weight: .semibold)).foregroundStyle(.primary)
                }
            }
            .frame(width: h * 0.64, height: h * 0.64)
            .clipShape(RoundedRectangle(cornerRadius: h * 0.1, style: .continuous))
            VStack(alignment: .leading, spacing: h * 0.02) {
                Text(service.title.isEmpty ? loc("再生していません") : service.title)
                    .font(.system(size: h * 0.15, weight: .semibold))
                    .lineLimit(1)
                if !service.artist.isEmpty {
                    Text(service.artist)
                        .font(.system(size: h * 0.12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if service.player != nil {
                    Image(systemName: service.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: h * 0.12, weight: .bold))
                        .foregroundStyle(.secondary)
                        // 再生中ずっと動くアニメーションは Dock 全体の描画を続けさせるので付けない
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, h * 0.12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let art = service.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).opacity(0.3)
            }
        }
    }
}

struct VolumeTile: View {
    let service: VolumeService
    let h: CGFloat

    var body: some View {
        VStack(spacing: h * 0.08) {
            Image(systemName: service.symbol)
                .font(.system(size: h * 0.3, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Capsule().fill(.primary.opacity(0.2))
                .frame(width: h * 0.56, height: h * 0.07)
                .overlay(alignment: .leading) {
                    Capsule().fill(.primary).frame(width: h * 0.56 * CGFloat(service.muted ? 0 : service.volume))
                }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SystemTile: View {
    let service: SystemStatsService
    let h: CGFloat

    var body: some View {
        HStack(spacing: h * 0.14) {
            gauge("CPU", service.cpu, .green)
            gauge("MEM", service.memory, .cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gauge(_ label: String, _ v: Double, _ color: Color) -> some View {
        ZStack {
            ProgressRing(progress: v, color: color, width: h * 0.08)
            VStack(spacing: 0) {
                Text("\(Fmt.percent(v))")
                    .font(.system(size: h * 0.17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label).font(.system(size: h * 0.08, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, h * 0.08)
            .foregroundStyle(.primary)
        }
        .frame(width: h * 0.62, height: h * 0.62)
    }
}

struct BatteryTile: View {
    let service: BatteryService
    let h: CGFloat

    var body: some View {
        let color: Color = service.level < 0.2 && !service.charging ? .red : .green
        ZStack {
            if service.hasBattery {
                ProgressRing(progress: service.level, color: color, width: h * 0.09).padding(h * 0.14)
                VStack(spacing: 0) {
                    // 白固定だとライトモードで見えないため secondary にする
                    Image(systemName: service.charging ? "bolt.fill" : "battery.100percent")
                        .font(.system(size: h * 0.12, weight: .bold))
                        .foregroundStyle(service.charging ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    Text("\(Fmt.percent(service.level))")
                        .font(.system(size: h * 0.2, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, h * 0.24)
            } else {
                // バッテリーのない Mac（デスクトップ）
                Image(systemName: "powerplug.fill")
                    .font(.system(size: h * 0.3, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StorageTile: View {
    let service: SystemStatsService
    let h: CGFloat

    var body: some View {
        let free = service.diskFree, total = service.diskTotal
        let used = total > 0 ? 1 - free / total : 0
        // 1000 GB 以上は TB にして桁を抑える
        let tb = free >= 999.5
        ZStack {
            ProgressRing(progress: used, color: .indigo, width: h * 0.09).padding(h * 0.14)
            VStack(spacing: 0) {
                Text(total <= 0 ? "—" : tb ? String(format: "%.1f", free / 1000) : "\(Int(free))")
                    .font(.system(size: h * 0.2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(loc(tb ? "TB空き" : "GB空き")).font(.system(size: h * 0.08, weight: .semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, h * 0.24)
            .foregroundStyle(.primary)
        }
    }
}

struct NetworkTile: View {
    let service: SystemStatsService
    let h: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: h * 0.06) {
            Label(Fmt.rate(service.down), systemImage: "arrow.down")
                .foregroundStyle(.cyan)
            Label(Fmt.rate(service.up), systemImage: "arrow.up")
                .foregroundStyle(.pink)
        }
        .font(.system(size: h * 0.16, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, h * 0.12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            Sparkline(values: service.netHistory).fill(.cyan.opacity(0.18)).frame(height: h * 0.5)
        }
    }
}

struct Sparkline: Shape {
    let values: [Double]
    var maxValue: Double?

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let top = maxValue ?? values.max() ?? 1
        let maxV = top.isFinite ? max(top, 0.0001) : 1
        let step = rect.width / CGFloat(values.count - 1)
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        for (i, v) in values.enumerated() {
            // 上限を超えた値や NaN で枠の外に描かないようにする
            let f = v.isFinite ? min(max(v / maxV, 0), 1) : 0
            p.addLine(to: CGPoint(x: CGFloat(i) * step, y: rect.maxY - rect.height * CGFloat(f)))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct PomodoroTile: View {
    let service: PomodoroService
    let h: CGFloat

    var body: some View {
        let color: Color = service.phase == .focus ? .red : .green
        ZStack {
            ProgressRing(progress: service.progress, color: color, width: h * 0.08).padding(h * 0.12)
            VStack(spacing: 0) {
                Image(systemName: service.running ? "pause.fill" : "play.fill")
                    .font(.system(size: h * 0.1, weight: .bold))
                    .foregroundStyle(color)
                Text(service.label)
                    .font(.system(size: h * 0.17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, h * 0.2)
        }
    }
}

struct QuickNoteTile: View {
    let store: QuickNoteStore
    let h: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: h * 0.04) {
            Image(systemName: "note.text").font(.system(size: h * 0.2, weight: .semibold))
                .foregroundStyle(.yellow)
            // 先頭の空行で中身が見えなくならないよう前後の空白を除く。黄色の文字はライトモードで読めないので primary にする
            let text = store.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(text.isEmpty ? loc("メモ") : text)
                .font(.system(size: h * 0.12, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .opacity(0.8)
        }
        .padding(h * 0.12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ClipboardTile: View {
    let service: ClipboardService
    let h: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: h * 0.36))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !service.items.isEmpty {
                Text("\(service.items.count)")
                    .font(.system(size: h * 0.14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(h * 0.08)
            }
        }
    }
}

struct ColorPickerTile: View {
    let service: ColorPickerService
    let h: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: h * 0.1)
                .padding(h * 0.14)
            Circle().fill(service.history.first.map(Color.init(hex:)) ?? .gray).padding(h * 0.3)
            Image(systemName: "eyedropper")
                .font(.system(size: h * 0.16, weight: .bold))
                .foregroundStyle(.primary)
                .shadow(radius: 1)
        }
    }
}
