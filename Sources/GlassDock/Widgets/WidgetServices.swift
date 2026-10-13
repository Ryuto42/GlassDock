import AppKit
import AudioToolbox
import CoreAudio
import CoreLocation
import Darwin
import EventKit
import IOKit.ps
import MapKit
import SwiftUI

// Dock に置かれているウィジェットの分だけサービスを動かす
@MainActor
final class WidgetHub {
    static let shared = WidgetHub()

    let weather = WeatherService()
    let calendar = CalendarService()
    let media = NowPlayingService()
    let system = SystemStatsService()
    let battery = BatteryService()
    let volume = VolumeService()
    let pomodoro = PomodoroService()
    let clipboard = ClipboardService()
    let notes = QuickNoteStore()
    let colors = ColorPickerService()
    let gpu = GPUService()
    let processes = ProcessMonitor()
    let peripherals = PeripheralBatteryService()
    let health = HealthService()

    private var active: Set<WidgetKind> = []
    private var dockVisible = true

    func update(_ kinds: Set<WidgetKind>) {
        guard kinds != active else { return }
        active = kinds
        weather.setActive(kinds.contains(.weather) || kinds.contains(.weatherCompact))
        calendar.setActive(events: kinds.contains(.calendar) || kinds.contains(.agenda), reminders: kinds.contains(.reminders))
        // 音楽アプリのホバー表示でも使うので常に動かす（通知を受けるだけで軽い）
        media.setActive(true)
        let overview = kinds.contains(.overview)
        battery.setActive(overview || kinds.contains(.battery) || kinds.contains(.health))
        health.setActive(overview || kinds.contains(.health))
        volume.setActive(kinds.contains(.volume))
        // クリップボード履歴は隠れている間のコピーも記録する必要があるため、表示状態に関係なく動かす
        clipboard.setActive(kinds.contains(.clipboard))
        applyPolling()
    }

    // Dock が「自動的に隠す」で隠れている間はウィジェットが見えないので、定期的に取得する処理を止める
    func setDockVisible(_ visible: Bool) {
        guard visible != dockVisible else { return }
        dockVisible = visible
        applyPolling()
    }

    private func applyPolling() {
        let k = active
        let on = dockVisible
        let overview = k.contains(.overview)
        system.setActive(on && (overview || !k.isDisjoint(with: [.systemMonitor, .network, .storage, .memory, .health])))
        gpu.setActive(on && (overview || k.contains(.gpu)))
        processes.setActive(on && (overview || k.contains(.processes) || k.contains(.health)))
        peripherals.setActive(on && (overview || k.contains(.peripherals)))
    }

    func primaryAction(_ kind: WidgetKind) {
        func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        func settings(_ id: String) {
            if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
        }
        switch kind {
        case .analogClock, .digitalClock, .worldClock, .dayProgress:
            if FileManager.default.fileExists(atPath: "/System/Applications/Clock.app") {
                open("/System/Applications/Clock.app")
            } else {
                open("/System/Applications/Calendar.app")
            }
        case .calendar, .agenda: open("/System/Applications/Calendar.app")
        case .reminders: open("/System/Applications/Reminders.app")
        case .weather, .weatherCompact: open("/System/Applications/Weather.app")
        case .nowPlaying: media.send(.playPause)
        case .volume: volume.toggleMute()
        case .systemMonitor, .network, .gpu, .memory, .processes, .health, .overview:
            open("/System/Applications/Utilities/Activity Monitor.app")
        case .peripherals: settings("com.apple.BluetoothSettings")
        case .battery: settings("com.apple.Battery-Settings.extension")
        case .storage: settings("com.apple.settings.Storage")
        case .pomodoro: pomodoro.toggle()
        case .quickNote, .clipboard: break
        case .colorPicker: colors.pick()
        }
    }
}

// MARK: - Weather (Open-Meteo)

struct WeatherSnapshot: Equatable {
    struct Hour: Equatable, Identifiable { let id: Date; let temp: Double; let code: Int; let isDay: Bool }
    struct Day: Equatable, Identifiable { let id: Date; let max: Double; let min: Double; let code: Int; let rain: Int }
    var place: String
    var temp: Double
    var feels: Double
    var code: Int
    var isDay: Bool
    var humidity: Int
    var wind: Double
    var sunrise: Date?
    var sunset: Date?
    var hours: [Hour]
    var days: [Day]
}

@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    private(set) var snapshot: WeatherSnapshot?
    private(set) var status = loc("読み込み中…")

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var location: CLLocationManager?
    @ObservationIgnored private var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var place = ""

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 120
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let settings = DockSettings.shared
        if settings.useCurrentLocation {
            if location == nil {
                let m = CLLocationManager()
                m.delegate = self
                m.desiredAccuracy = kCLLocationAccuracyKilometer
                location = m
            }
            switch location!.authorizationStatus {
            case .notDetermined: location!.requestWhenInUseAuthorization()
            case .denied, .restricted:
                if settings.weatherCity.isEmpty {
                    status = loc("位置情報が許可されていません")
                } else {
                    Task { await self.load(city: settings.weatherCity) }
                }
            default: location!.requestLocation()
            }
        } else if !settings.weatherCity.isEmpty {
            Task { await self.load(city: settings.weatherCity) }
        } else {
            status = loc("設定で都市を指定してください")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
            if let request = MKReverseGeocodingRequest(location: loc), let item = try? await request.mapItems.first {
                self.place = item.addressRepresentations?.cityName ?? item.name ?? ""
            }
            await self.load(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let city = DockSettings.shared.weatherCity
            if !city.isEmpty { await self.load(city: city) } else { self.status = loc("現在地を取得できません") }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
            else if manager.authorizationStatus == .denied { self.refresh() }
        }
    }

    private func load(city: String) async {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        let language = Bundle.main.preferredLocalizations.first == "ja" ? "ja" : "en"
        comps.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: language)]
        if let url = comps.url,
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let first = (json["results"] as? [[String: Any]])?.first,
           let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double {
            place = first["name"] as? String ?? city
            await load(lat: lat, lon: lon)
            return
        }
        // Open-Meteo の検索は日本語の地名（「東京」など）を見つけられないため、macOS のジオコーディングで探し直す
        if let request = MKGeocodingRequest(addressString: city), let item = try? await request.mapItems.first {
            place = item.addressRepresentations?.cityName ?? item.name ?? city
            await load(lat: item.location.coordinate.latitude, lon: item.location.coordinate.longitude)
            return
        }
        status = loc("「%@」が見つかりません", city)
    }

    private func load(lat: Double, lon: Double) async {
        let unit = DockSettings.shared.temperatureUnit == .fahrenheit ? "fahrenheit" : "celsius"
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", lat)),
            .init(name: "longitude", value: String(format: "%.2f", lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: unit),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let daily = json["daily"] as? [String: Any]
        else {
            status = loc("天気を取得できません")
            return
        }
        let offset = json["utc_offset_seconds"] as? Int ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let df = DateFormatter()
        df.locale = f.locale
        df.timeZone = f.timeZone
        df.dateFormat = "yyyy-MM-dd"

        func nums(_ d: [String: Any], _ k: String) -> [Double] { (d[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? [] }
        func strs(_ d: [String: Any], _ k: String) -> [String] { d[k] as? [String] ?? [] }

        let now = Date()
        let hTimes = strs(hourly, "time").compactMap(f.date)
        let hTemps = nums(hourly, "temperature_2m"), hCodes = nums(hourly, "weather_code"), hDay = nums(hourly, "is_day")
        let hours = hTimes.indices
            .filter { hTimes[$0] > now.addingTimeInterval(-3600) && $0 < hTemps.count }
            .prefix(12)
            .map { WeatherSnapshot.Hour(id: hTimes[$0], temp: hTemps[$0], code: Int(hCodes[$0]), isDay: hDay[$0] == 1) }

        let dTimes = strs(daily, "time").compactMap(df.date)
        let dMax = nums(daily, "temperature_2m_max"), dMin = nums(daily, "temperature_2m_min")
        let dCode = nums(daily, "weather_code"), dRain = nums(daily, "precipitation_probability_max")
        let days = dTimes.indices.filter { $0 < dMax.count }.map {
            WeatherSnapshot.Day(id: dTimes[$0], max: dMax[$0], min: dMin[$0], code: Int(dCode[$0]), rain: Int(dRain[safe: $0] ?? 0))
        }
        let sunrise = strs(daily, "sunrise").first.flatMap(f.date)
        let sunset = strs(daily, "sunset").first.flatMap(f.date)

        func num(_ k: String) -> Double { (current[k] as? NSNumber)?.doubleValue ?? 0 }
        snapshot = WeatherSnapshot(
            place: place, temp: num("temperature_2m"), feels: num("apparent_temperature"),
            code: Int(num("weather_code")), isDay: num("is_day") == 1,
            humidity: Int(num("relative_humidity_2m")), wind: num("wind_speed_10m"),
            sunrise: sunrise, sunset: sunset, hours: Array(hours), days: days
        )
        status = ""
    }

    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: loc("cloud.fill")
        case 45, 48: loc("cloud.fog.fill")
        case 51...57: loc("cloud.drizzle.fill")
        case 61, 63, 66: loc("cloud.rain.fill")
        case 65, 67: loc("cloud.heavyrain.fill")
        case 71...77, 85, 86: loc("cloud.snow.fill")
        case 80...82: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95...99: loc("cloud.bolt.rain.fill")
        default: "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: loc("快晴")
        case 1: loc("晴れ")
        case 2: loc("晴れ時々曇り")
        case 3: loc("曇り")
        case 45, 48: loc("霧")
        case 51...57: loc("霧雨")
        case 61, 63, 66: loc("雨")
        case 65, 67: loc("大雨")
        case 71...77: loc("雪")
        case 80...82: loc("にわか雨")
        case 85, 86: loc("にわか雪")
        case 95...99: loc("雷雨")
        default: "—"
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Calendar / Reminders

@Observable
final class CalendarService {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        let location: String?
    }

    struct Reminder: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
        let color: NSColor
    }

    private(set) var events: [Event] = []
    private(set) var monthEvents: [Event] = []
    private(set) var reminders: [Reminder] = []
    // カレンダーの詳細表示で選んでいる日と表示中の月（大きさを測るコピーとも共有する）
    var selectedDay = Calendar.current.startOfDay(for: Date())
    var shownMonth = Date()
    private(set) var eventAccess = true
    private(set) var reminderAccess = true

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wantsEvents = false
    @ObservationIgnored private var wantsReminders = false

    func setActive(events: Bool, reminders: Bool) {
        wantsEvents = events
        wantsReminders = reminders
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard events || reminders else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task {
            if events { eventAccess = (try? await store.requestFullAccessToEvents()) ?? false }
            if reminders { reminderAccess = (try? await store.requestFullAccessToReminders()) ?? false }
            reload()
        }
    }

    func reload() {
        if wantsEvents, eventAccess {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 14, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .prefix(60)
                .map {
                    Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? loc("（タイトルなし）"),
                          start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                          color: $0.calendar.color ?? .systemBlue, location: $0.location)
                }
        }
        if wantsReminders, reminderAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] items in
                let list = (items ?? []).prefix(40).map {
                    Reminder(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date,
                             color: $0.calendar.color ?? .systemOrange)
                }
                Task { @MainActor in self?.reminders = list.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
            }
        }
    }

    func complete(_ reminder: Reminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }

    func resetSelection() {
        selectedDay = Calendar.current.startOfDay(for: Date())
        shownMonth = Date()
        monthEvents = []
    }

    // 表示中の月の予定を読み込む（通常は今日から2週間分しか持っていないため）
    func loadMonth(_ month: Date) {
        guard eventAccess else { return }
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        monthEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? loc("（タイトルなし）"),
                      start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                      color: $0.calendar.color ?? .systemBlue, location: $0.location)
            }
    }

    var markedDays: Set<Date> {
        Set((events + monthEvents).map { Calendar.current.startOfDay(for: $0.start) })
    }

    var nextEvent: Event? {
        let now = Date()
        return events.first { !$0.allDay && $0.end > now } ?? events.first { $0.end > now }
    }

    func events(on day: Date) -> [Event] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        var seen = Set<String>()
        return (events + monthEvents)
            .filter { $0.start < end && $0.end > start }
            .filter { seen.insert($0.id + "\($0.start.timeIntervalSince1970)").inserted }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }
}

// MARK: - Now Playing (Spotify / Music)

@Observable
final class NowPlayingService {
    enum Command { case playPause, next, previous }

    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var isPlaying = false
    private(set) var player: String?
    private(set) var artwork: NSImage?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var progressInFlight = false

    func setActive(_ on: Bool) {
        if on && !observers.isEmpty { return }
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers = []
        guard on else { return }
        for (name, app) in [("com.spotify.client.PlaybackStateChanged", "Spotify"), ("com.apple.Music.playerInfo", "Music")] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo as? [String: Any] ?? [:]
                MainActor.assumeIsolated { self?.handle(info, app: app) }
            })
        }
        refresh()
    }

    private func handle(_ info: [String: Any], app: String) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            if player == app { clear() }
            return
        }
        player = app
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        album = info["Album"] as? String ?? album
        isPlaying = state == "Playing"
        loadArtwork()
    }

    private func clear() {
        player = nil
        title = ""
        artist = ""
        album = ""
        isPlaying = false
        artwork = nil
        artworkKey = ""
    }

    func refresh() {
        for app in ["Spotify", "Music"] where isRunning(app) {
            let script = AppleScript.ifRunning(app, """
                if player state is stopped then return "stopped"
                return (player state as string) & "\\n" & name of current track & "\\n" & artist of current track & "\\n" & album of current track
            """)
            Task {
                guard let out = await AppleScript.run(script), out != "stopped" else { return }
                let parts = out.components(separatedBy: "\n")
                guard parts.count >= 4 else { return }
                if self.player == nil || parts[0] == "playing" {
                    self.player = app
                    self.isPlaying = parts[0] == "playing"
                    self.title = parts[1]
                    self.artist = parts[2]
                    self.album = parts[3]
                    self.loadArtwork()
                }
            }
        }
    }

    static func playerName(for bundleID: String?) -> String? {
        switch bundleID {
        case "com.spotify.client": "Spotify"
        case "com.apple.Music": "Music"
        default: nil
        }
    }

    // AppleScript に渡すアプリ名はこの2つだけに限る
    private static let allowedPlayers: Set<String> = ["Spotify", "Music"]

    // パネル表示中だけ再生位置を取りに行く
    func startProgress() {
        stopProgress()
        updateProgress()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateProgress() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard !progressInFlight, let app = player, Self.allowedPlayers.contains(app), isRunning(app) else { return }
        let script = AppleScript.ifRunning(app, "return (player position as string) & \"|\" & (duration of current track as string)")
        progressInFlight = true
        Task {
            defer { self.progressInFlight = false }
            guard let out = await AppleScript.run(script) else { return }
            let parts = out.replacingOccurrences(of: ",", with: ".").split(separator: "|").map { Double($0) ?? 0 }
            guard parts.count == 2 else { return }
            self.position = parts[0]
            self.duration = app == "Spotify" ? parts[1] / 1000 : parts[1]
        }
    }

    func seek(to seconds: Double) {
        guard let app = player, Self.allowedPlayers.contains(app), seconds.isFinite else { return }
        position = seconds
        Task { _ = await AppleScript.run(AppleScript.ifRunning(app, "set player position to \(seconds)")) }
    }

    func send(_ command: Command, app target: String? = nil) {
        guard let app = target ?? player ?? ["Spotify", "Music"].first(where: isRunning),
              Self.allowedPlayers.contains(app) else { return }
        let verb = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        Task {
            _ = await AppleScript.run(AppleScript.ifRunning(app, verb))
            try? await Task.sleep(for: .milliseconds(300))
            self.refresh()
            self.updateProgress()
        }
    }

    func openPlayer() {
        guard let app = player else { return }
        let id = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func isRunning(_ app: String) -> Bool {
        let id = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func loadArtwork() {
        let key = "\(player ?? "")|\(title)|\(album)"
        guard key != artworkKey, let player, isRunning(player) else { return }
        artworkKey = key
        if player == "Spotify" {
            Task {
                guard let str = await AppleScript.run(AppleScript.ifRunning("Spotify", "return artwork url of current track")),
                      let url = URL(string: str), url.scheme == "https",
                      let (data, _) = try? await URLSession.shared.data(from: url)
                else { return }
                if self.artworkKey == key { self.artwork = NSImage(data: data) }
            }
        } else {
            Task {
                let data = await AppleScript.data(AppleScript.ifRunning("Music", "return raw data of artwork 1 of current track"))
                if self.artworkKey == key { self.artwork = data.flatMap(NSImage.init(data:)) }
            }
        }
    }
}

// NSAppleScript はスレッドセーフではないため、専用のキューで1つずつ実行する。
// 相手のアプリが固まっても待ち続けないよう、スクリプト側でタイムアウトを付ける
enum AppleScript {
    private static let queue = DispatchQueue(label: "GlassDock.AppleScript", qos: .utility)

    private static func wrapped(_ source: String) -> String {
        "with timeout of 3 seconds\n\(source)\nend timeout"
    }

    static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: wrapped(source))?.executeAndReturnError(&error).stringValue
                continuation.resume(returning: result)
            }
        }
    }

    static func data(_ source: String) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: wrapped(source))?.executeAndReturnError(&error).data
                continuation.resume(returning: result)
            }
        }
    }

    // 対象のアプリが終了していたら起動し直さないよう、スクリプトの中でも起動状態を確かめる
    static func ifRunning(_ app: String, _ body: String) -> String {
        "if application \"\(app)\" is running then\ntell application \"\(app)\"\n\(body)\nend tell\nend if"
    }
}

// MARK: - System stats

@Observable
final class SystemStatsService {
    private(set) var cpu: Double = 0
    private(set) var memory: Double = 0
    private(set) var memoryUsedGB: Double = 0
    private(set) var memoryTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    private(set) var diskFree: Double = 0
    private(set) var diskTotal: Double = 0
    private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    private(set) var netHistory: [Double] = Array(repeating: 0, count: 30)
    private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 30)
    // メモリの内訳（GB）
    private(set) var appMemoryGB: Double = 0
    private(set) var wiredGB: Double = 0
    private(set) var compressedGB: Double = 0
    private(set) var cachedGB: Double = 0
    private(set) var swapUsedGB: Double = 0
    // 1: 正常 2: 注意 4: 逼迫（kern.memorystatus_vm_pressure_level）
    private(set) var pressureLevel: Int = 1

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastDiskSample: Date?
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        // 空き容量の取得は macOS の容量計算サービスに問い合わせるため重い。60 秒に1回、メインスレッドの外で行う
        if lastDiskSample.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastDiskSample = Date()
            sampleDisk()
        }
    }

    private func sampleCPU() {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        if let last = lastTicks, total > last.total {
            cpu = Double(busy - last.busy) / Double(total - last.total)
            cpuHistory = Array((cpuHistory + [cpu]).suffix(30))
        }
        lastTicks = (busy, total)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        memoryUsedGB = used / 1_073_741_824
        memory = min(1, memoryUsedGB / memoryTotalGB)
        memoryHistory = Array((memoryHistory + [memory]).suffix(30))
        let gb = page / 1_073_741_824
        appMemoryGB = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * gb
        wiredGB = Double(stats.wire_count) * gb
        compressedGB = Double(stats.compressor_page_count) * gb
        cachedGB = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * gb

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsedGB = Double(swap.xsu_used) / 1_073_741_824 }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { pressureLevel = Int(level) }
    }

    private func sampleNetwork() {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return }
        defer { freeifaddrs(ptr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes)
            tx += UInt64(d.ifi_obytes)
        }
        let now = Date()
        if let last = lastNet, rx >= last.rx, tx >= last.tx {
            let dt = max(now.timeIntervalSince(last.at), 0.5)
            down = Double(rx - last.rx) / dt
            up = Double(tx - last.tx) / dt
            netHistory = Array((netHistory + [down]).suffix(30))
        }
        lastNet = (rx, tx, now)
    }

    private func sampleDisk() {
        Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: "/")
            guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
            let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
            let total = Double(v.volumeTotalCapacity ?? 0) / 1_000_000_000
            await MainActor.run {
                self.diskFree = free
                self.diskTotal = total
            }
        }
    }

    static func rate(_ bytes: Double) -> String {
        switch bytes {
        case ..<1_000: String(format: "%.0f B/s", bytes)
        case ..<1_000_000: String(format: "%.0f KB/s", bytes / 1_000)
        default: String(format: "%.1f MB/s", bytes / 1_000_000)
        }
    }
}

// MARK: - Battery

@Observable
final class BatteryService {
    private(set) var level: Double = 1
    private(set) var charging = false
    private(set) var pluggedIn = false
    private(set) var minutesLeft: Int?
    private(set) var hasBattery = true
    private(set) var cycleCount: Int?
    private(set) var designCycles: Int?
    // 設計容量に対する現在の最大容量（%）
    private(set) var healthPercent: Int?
    private(set) var temperature: Double?

    @ObservationIgnored private var source: CFRunLoopSource?

    func setActive(_ on: Bool) {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        guard on else { return }
        refresh()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { service.refresh() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let ps = list.first,
              let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any]
        else {
            hasBattery = false
            return
        }
        let cur = desc[kIOPSCurrentCapacityKey] as? Double ?? 100
        let max = desc[kIOPSMaxCapacityKey] as? Double ?? 100
        level = cur / Swift.max(max, 1)
        charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        pluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let t = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
        minutesLeft = t > 0 ? t : nil
        readSmartBattery()
    }

    // macOS 26 以降は容量などの値が BatteryData の中に移ったため、両方を見る
    private func readSmartBattery() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let top = props?.takeRetainedValue() as? [String: Any] else { return }
        let nested = top["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (top[key] as? NSNumber)?.intValue ?? (nested[key] as? NSNumber)?.intValue }
        cycleCount = int("CycleCount")
        designCycles = int("DesignCycleCount9C")
        // 100 以下の値は mAh ではなく % なので使わない
        if let design = int("DesignCapacity"), design > 100,
           let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"), full > 100 {
            healthPercent = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        if let raw = int("Temperature") ?? int("VirtualTemperature"), raw > 0 {
            temperature = Double(raw) / 100
        }
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Volume

@Observable
final class VolumeService {
    private(set) var volume: Float = 0.5
    private(set) var muted = false

    @ObservationIgnored private var listening: AudioObjectID = 0
    @ObservationIgnored private var block: AudioObjectPropertyListenerBlock?

    private var device: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    func setActive(_ on: Bool) {
        stopListening()
        guard on else { return }
        refresh()
        let dev = device
        let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(dev, &addr, .main, b)
        }
        listening = dev
        block = b
    }

    private func stopListening() {
        guard let block, listening != 0 else { return }
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = address(sel)
            AudioObjectRemovePropertyListenerBlock(listening, &addr, .main, block)
        }
        self.block = nil
        listening = 0
    }

    func refresh() {
        let dev = device
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { volume = v }
        var m = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = address(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr { muted = m != 0 }
    }

    func set(_ value: Float) {
        var v = Float32(min(max(value, 0), 1))
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        volume = v
        if muted && v > 0 { setMuted(false) }
    }

    func toggleMute() { setMuted(!muted) }

    private func setMuted(_ on: Bool) {
        var m = UInt32(on ? 1 : 0)
        var addr = address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        muted = on
    }

    var symbol: String {
        if muted || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

// MARK: - Pomodoro

@Observable
final class PomodoroService {
    enum Phase { case focus, rest }

    private(set) var phase: Phase = .focus
    private(set) var running = false
    private(set) var remaining: TimeInterval = DockSettings.shared.focusMinutes * 60
    private(set) var completed = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var endDate: Date?

    var total: TimeInterval { (phase == .focus ? DockSettings.shared.focusMinutes : DockSettings.shared.breakMinutes) * 60 }
    var progress: Double { 1 - remaining / max(total, 1) }

    func toggle() { running ? pause() : start() }

    func start() {
        endDate = Date().addingTimeInterval(remaining)
        running = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    func reset() {
        pause()
        phase = .focus
        remaining = total
    }

    func skip() {
        let wasRunning = running
        pause()
        if phase == .focus { completed += 1 }
        phase = phase == .focus ? .rest : .focus
        remaining = total
        if wasRunning { start() }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 {
            NSSound(named: "Glass")?.play()
            skip()
            start()
        }
    }

    var label: String {
        let s = Int(remaining.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Clipboard

@Observable
final class ClipboardService {
    private(set) var items: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // パスワード管理アプリなどが付ける「記録しないで」の印（nspasteboard.org の規約）
    private static let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("com.agilebits.onepassword"),
    ]

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if let types = pb.types, !Self.ignoredTypes.isDisjoint(with: types) { return }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 5000 else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        changeCount = pb.changeCount
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
    }

    func clear() { items = [] }
}

// MARK: - Quick note

@Observable
final class QuickNoteStore {
    var text: String = UserDefaults.standard.string(forKey: "quickNote") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "quickNote") }
    }
}

// MARK: - Color picker

@Observable
final class ColorPickerService {
    private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "pickedColors") ?? []

    func pick() {
        NSColorSampler().show { [weak self] color in
            guard let color, let self else { return }
            let hex = Color(nsColor: color).hexString
            MainActor.assumeIsolated { self.add(hex) }
        }
    }

    func add(_ hex: String) {
        history.removeAll { $0 == hex }
        history.insert(hex, at: 0)
        history = Array(history.prefix(12))
        UserDefaults.standard.set(history, forKey: "pickedColors")
        copy(hex)
    }

    func copy(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }
}
