import AppKit
import Darwin
import IOKit
import SystemConfiguration

// MARK: - GPU

@Observable
final class GPUService {
    private(set) var usage: Double = 0
    private(set) var history: [Double] = Array(repeating: 0, count: 30)
    private(set) var model = ""
    private(set) var cores: Int?

    @ObservationIgnored private var timer: Timer?

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
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                if let stats = dict["PerformanceStatistics"] as? [String: Any],
                   let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                    best = max(best ?? 0, value / 100)
                }
                if model.isEmpty, let m = dict["model"] as? String { model = m }
                if cores == nil { cores = (dict["gpu-core-count"] as? NSNumber)?.intValue }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard let best else { return }
        usage = min(max(best, 0), 1)
        history = Array((history + [usage]).suffix(30))
    }
}

// MARK: - Processes

struct ProcessSample: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double          // 1.0 = 1 コア分
    let memoryMB: Double
    let isApp: Bool
}

@Observable
final class ProcessMonitor {
    private(set) var topCPU: [ProcessSample] = []
    private(set) var topMemory: [ProcessSample] = []
    // 2 分以上 1.5 コアを超えて使い続けているプロセス
    private(set) var hogs: [ProcessSample] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTimes: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSample: UInt64 = 0
    @ObservationIgnored private var hotSince: [pid_t: Date] = [:]
    @ObservationIgnored private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        lastTimes = [:]
        guard on else { return }
        sample()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = 0.8
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = mach_absolute_time()
        let elapsed = lastSample > 0 ? Double((now - lastSample) * timebase.numer / timebase.denom) : 0
        var times: [pid_t: UInt64] = [:]
        var samples: [ProcessSample] = []
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        for pid in pids.prefix(got) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            // 他のユーザー（root など）のプロセスは読めないので飛ばす
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let total = (info.pti_total_user + info.pti_total_system) * timebase.numer / timebase.denom
            times[pid] = total
            var cpu = 0.0
            if elapsed > 0, let prev = lastTimes[pid], total >= prev { cpu = Double(total - prev) / elapsed }
            let app = apps[pid]
            samples.append(ProcessSample(id: pid, name: app?.localizedName ?? Self.name(of: pid),
                                         cpu: cpu, memoryMB: Double(info.pti_resident_size) / 1_048_576,
                                         isApp: app?.activationPolicy == .regular))
        }
        lastTimes = times
        lastSample = now
        guard elapsed > 0 else { return }

        topCPU = Array(samples.sorted { $0.cpu > $1.cpu }.prefix(6))
        topMemory = Array(samples.sorted { $0.memoryMB > $1.memoryMB }.prefix(6))
        let date = Date()
        for s in samples {
            if s.cpu > 1.5 { hotSince[s.id] = hotSince[s.id] ?? date } else { hotSince[s.id] = nil }
        }
        hotSince = hotSince.filter { times[$0.key] != nil }
        hogs = samples.filter { s in hotSince[s.id].map { date.timeIntervalSince($0) > 120 } ?? false }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "PID \(pid)" : name
    }

    static func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

// MARK: - Peripheral batteries

struct PeripheralBattery: Identifiable, Equatable {
    var id: String { name + kind }
    let name: String
    let kind: String
    let level: Int
}

@Observable
final class PeripheralBatteryService {
    private(set) var devices: [PeripheralBattery] = []
    private(set) var loading = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastBluetooth: Date?

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh(force: true)
        let t = Timer(timeInterval: 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(force: false) } }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // キーボード・マウス・トラックパッドは IOKit、AirPods などは system_profiler（数百ミリ秒かかるので間隔をあける）
    func refresh(force: Bool) {
        let hid = Self.hidDevices()
        let needsBluetooth = force || lastBluetooth.map { Date().timeIntervalSince($0) > 300 } ?? true
        if !needsBluetooth {
            merge(hid: hid, bluetooth: nil)
            return
        }
        lastBluetooth = Date()
        loading = true
        Task {
            let bt = await Self.bluetoothDevices()
            self.merge(hid: hid, bluetooth: bt)
            self.loading = false
        }
    }

    @ObservationIgnored private var lastBT: [PeripheralBattery] = []

    private func merge(hid: [PeripheralBattery], bluetooth: [PeripheralBattery]?) {
        if let bluetooth { lastBT = bluetooth }
        var seen = Set<String>()
        devices = (hid + lastBT).filter { seen.insert($0.id).inserted }
    }

    private static func hidDevices() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [PeripheralBattery] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let level = (dict["BatteryPercent"] as? NSNumber)?.intValue {
                let name = dict["Product"] as? String ?? loc("デバイス")
                result.append(PeripheralBattery(name: name, kind: Self.kind(for: name), level: level))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    private static func bluetoothDevices() async -> [PeripheralBattery] {
        await Task.detached(priority: .utility) { () -> [PeripheralBattery] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
                  let connected = root["device_connected"] as? [[String: Any]] else { return [] }
            var result: [PeripheralBattery] = []
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
                    }
                    let kind = PeripheralBatteryService.kind(for: name, minor: info["device_minorType"] as? String)
                    if let l = level("device_batteryLevelLeft") { result.append(.init(name: name, kind: "左", level: l)) }
                    if let r = level("device_batteryLevelRight") { result.append(.init(name: name, kind: "右", level: r)) }
                    if let c = level("device_batteryLevelCase") { result.append(.init(name: name, kind: "ケース", level: c)) }
                    if let m = level("device_batteryLevelMain") { result.append(.init(name: name, kind: kind, level: m)) }
                }
            }
            return result
        }.value
    }

    nonisolated static func kind(for name: String, minor: String? = nil) -> String {
        let n = (name + " " + (minor ?? "")).lowercased()
        if n.contains("keyboard") { return "キーボード" }
        if n.contains("mouse") { return "マウス" }
        if n.contains("trackpad") { return "トラックパッド" }
        if n.contains("airpods") || n.contains("headphone") || n.contains("beats") { return "ヘッドフォン" }
        return "デバイス"
    }

    static func symbol(for device: PeripheralBattery) -> String {
        switch device.kind {
        case "キーボード": "keyboard"
        case "マウス": "magicmouse"
        case "トラックパッド": "rectangle.and.hand.point.up.left"
        case "左", "右", "ヘッドフォン": "airpods"
        case "ケース": "airpods.chargingcase"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Health

enum HealthLevel: Int, Comparable {
    case good, notice, warning, critical
    static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }

    var color: NSColor {
        switch self {
        case .good: .systemGreen
        case .notice: .systemYellow
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

struct HealthCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let level: HealthLevel
    let symbol: String
}

// 熱・メモリ・ディスク・CPU・バッテリーをまとめて判定する
@Observable
final class HealthService {
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    @ObservationIgnored private var observer: NSObjectProtocol?

    func setActive(_ on: Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard on else { return }
        thermal = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermal = ProcessInfo.processInfo.thermalState }
        }
    }

    var checks: [HealthCheck] {
        let hub = WidgetHub.shared
        var list: [HealthCheck] = []

        list.append(.init(id: "thermal", title: loc("熱の状態"), detail: thermalText, level: thermalLevel, symbol: "thermometer.medium"))

        let p = hub.system.pressureLevel
        list.append(.init(id: "memory", title: loc("メモリ"),
                          detail: p >= 4 ? loc("逼迫しています") : p >= 2 ? loc("やや不足しています") : loc("余裕あり（%.1f GB 使用）", hub.system.memoryUsedGB),
                          level: p >= 4 ? .critical : p >= 2 ? .warning : .good, symbol: "memorychip"))

        let total = hub.system.diskTotal
        list.append(.init(id: "disk", title: loc("ストレージ"),
                          detail: total > 0 ? loc("%.0f GB 空き", hub.system.diskFree) : loc("確認中…"),
                          level: diskLevel, symbol: "internaldrive"))

        let hogs = hub.processes.hogs
        list.append(.init(id: "cpu", title: loc("CPU"),
                          detail: hogs.isEmpty ? loc("使用率 %.0f%%", hub.system.cpu * 100)
                                               : loc("使い続けているアプリ: %@", ListFormatter.localizedString(byJoining: hogs.map(\.name))),
                          level: hogs.isEmpty ? .good : .warning, symbol: "cpu"))

        if hub.battery.hasBattery, let health = hub.battery.healthPercent {
            list.append(.init(id: "battery", title: loc("バッテリー"),
                              detail: hub.battery.cycleCount.map { loc("最大容量 %d%%・充放電 %d 回", health, $0) } ?? loc("最大容量 %d%%", health),
                              level: health < 70 ? .warning : health < 80 ? .notice : .good, symbol: "battery.75percent"))
        }
        return list
    }

    var overall: HealthLevel { checks.map(\.level).max() ?? .good }

    var diskLevel: HealthLevel {
        let free = WidgetHub.shared.system.diskFree, total = WidgetHub.shared.system.diskTotal
        guard total > 0, free < 15 || free / total < 0.1 else { return .good }
        return free < 5 ? .critical : .warning
    }

    var thermalLevel: HealthLevel {
        switch thermal {
        case .nominal: .good
        case .fair: .notice
        case .serious: .warning
        case .critical: .critical
        @unknown default: .good
        }
    }

    var thermalText: String {
        switch thermal {
        case .nominal: loc("正常")
        case .fair: loc("やや高め")
        case .serious: loc("高温（性能を抑制中）")
        case .critical: loc("非常に高温")
        @unknown default: loc("不明")
        }
    }

    // システム概要用。左のカードに出ている値（メモリ使用量・空き容量・CPU 使用率・最大容量）は載せない
    var overviewChecks: [HealthCheck] {
        let hub = WidgetHub.shared
        let temps = OverviewDetailService.shared.temps
        var list: [HealthCheck] = []
        list.append(.init(id: "thermal", title: loc("熱の状態"), detail: thermalText, level: thermalLevel, symbol: "thermometer.medium"))
        if let soc = temps.soc {
            let peak = temps.socMax ?? soc
            list.append(.init(id: "soc", title: loc("SoC 温度"), detail: loc("%.0f ℃（最高 %.0f ℃）", soc, peak),
                              level: peak >= 100 ? .warning : peak >= 90 ? .notice : .good, symbol: "cpu"))
        }
        if hub.battery.hasBattery, let temp = temps.battery ?? hub.battery.temperature {
            list.append(.init(id: "batteryTemp", title: loc("バッテリー温度"), detail: loc("%.1f ℃", temp),
                              level: temp >= 45 ? .warning : temp >= 40 ? .notice : .good, symbol: "thermometer.low"))
        }
        if hub.battery.hasBattery, let cycles = hub.battery.cycleCount {
            let design = hub.battery.designCycles
            list.append(.init(id: "cycles", title: loc("充放電回数"), detail: design.map { loc("%d / %d 回", cycles, $0) } ?? loc("%d 回", cycles),
                              level: design.map { Double(cycles) >= Double($0) * 0.9 ? .notice : .good } ?? .good,
                              symbol: "arrow.triangle.2.circlepath"))
        }
        let p = hub.system.pressureLevel
        list.append(.init(id: "swap", title: loc("スワップ"),
                          detail: p >= 4 ? loc("%.2f GB（メモリ逼迫）", hub.system.swapUsedGB) : p >= 2 ? loc("%.2f GB（メモリ不足気味）", hub.system.swapUsedGB) : String(format: "%.2f GB", hub.system.swapUsedGB),
                          level: p >= 4 ? .critical : p >= 2 ? .warning : .good, symbol: "arrow.left.arrow.right"))
        list.append(.init(id: "uptime", title: loc("稼働時間"), detail: Self.uptimeText(ProcessInfo.processInfo.systemUptime),
                          level: .good, symbol: "clock"))
        let hogs = hub.processes.hogs
        if !hogs.isEmpty {
            list.append(.init(id: "hogs", title: loc("高負荷が続くアプリ"), detail: ListFormatter.localizedString(byJoining: hogs.map(\.name)),
                              level: .warning, symbol: "flame"))
        }
        if diskLevel != .good {
            list.append(.init(id: "disk", title: loc("ストレージ"), detail: loc("空き容量が残りわずかです"), level: diskLevel, symbol: "internaldrive"))
        }
        return list
    }

    static func uptimeText(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60), hours = minutes / 60, days = hours / 24
        if days > 0 { return loc("%d 日 %d 時間", days, hours % 24) }
        if hours > 0 { return loc("%d 時間 %d 分", hours, minutes % 60) }
        return loc("%d 分", minutes)
    }
}

// MARK: - Overview detail（システム概要パネルの右側）

nonisolated enum OverviewCategory: Hashable, Sendable {
    case cpu, gpu, memory, network, storage, battery

    var usesProcesses: Bool { self != .network }
}

nonisolated struct UsageRow: Identifiable, Equatable, Sendable {
    let id: pid_t
    let name: String
    let value: Double
    let isApp: Bool
}

nonisolated struct NetInterfaceInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let address: String
    let down: Double
    let up: Double
}

nonisolated struct VolumeInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let free: Double
    let total: Double
}

nonisolated struct SensorTemps: Equatable, Sendable {
    var soc: Double?
    var socMax: Double?
    var battery: Double?
}

nonisolated struct OverviewSnapshot: Sendable {
    let category: OverviewCategory
    var rows: [UsageRow]?
    var interfaces: [NetInterfaceInfo]?
    var netDown: Double?
    var netUp: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var volumes: [VolumeInfo]?
    var temps: SensorTemps?
}

// パネルが開いている間だけ、選択中のカテゴリの分をメインスレッドの外で集計する
@Observable
final class OverviewDetailService {
    static let shared = OverviewDetailService()

    private(set) var selection: OverviewCategory = .cpu
    private(set) var rows: [UsageRow] = []
    private(set) var rowsCategory: OverviewCategory?
    private(set) var interfaces: [NetInterfaceInfo] = []
    private(set) var netDown: Double = 0
    private(set) var netUp: Double = 0
    private(set) var downHistory: [Double] = Array(repeating: 0, count: 30)
    private(set) var upHistory: [Double] = Array(repeating: 0, count: 30)
    private(set) var diskRead: Double = 0
    private(set) var diskWrite: Double = 0
    private(set) var volumes: [VolumeInfo] = []
    private(set) var temps = SensorTemps()

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastVolumes: Date?
    @ObservationIgnored private let sampler = OverviewSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "GlassDock.overview", qos: .utility)
    @ObservationIgnored private static var icons: [pid_t: NSImage?] = [:]

    // パネルは寸法を測るための非表示コピーも作るので、表示中のビューの数で管理する
    func attach() {
        viewers += 1
        if viewers == 1 { start() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stop() }
    }

    func select(_ category: OverviewCategory) {
        guard category != selection else { return }
        selection = category
        tick()
    }

    private func start() {
        generation += 1
        tickCount = 0
        lastVolumes = nil
        downHistory = Array(repeating: 0, count: 30)
        upHistory = Array(repeating: 0, count: 30)
        let gen = generation, sampler = sampler
        queue.async {
            let temps = sampler.readTemps()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(temps: temps, generation: gen) } }
        }
        tick()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        busy = false
        pending = false
        Self.icons = [:]
        let sampler = sampler
        queue.async { sampler.reset() }
    }

    private func tick() {
        guard viewers > 0 else { return }
        if busy {
            pending = true
            return
        }
        busy = true
        let category = selection
        let wantTemps = tickCount % 2 == 1
        tickCount += 1
        let wantVolumes = category == .storage && (lastVolumes.map { Date().timeIntervalSince($0) > 30 } ?? true)
        if wantVolumes { lastVolumes = Date() }
        var apps: [pid_t: OverviewSampler.AppInfo] = [:]
        if category.usesProcesses {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                apps[app.processIdentifier] = .init(name: app.localizedName ?? "", bundlePath: app.bundleURL?.path)
            }
        }
        let gen = generation, sampler = sampler
        queue.async {
            let snapshot = sampler.sample(category, apps: apps, temps: wantTemps, volumes: wantVolumes)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(snapshot, generation: gen) } }
        }
    }

    private func apply(_ s: OverviewSnapshot, generation gen: Int) {
        guard gen == generation else { return }
        busy = false
        if let r = s.rows, r != rows || rowsCategory != s.category {
            rows = r
            rowsCategory = s.category
        }
        if let i = s.interfaces, i != interfaces { interfaces = i }
        if let d = s.netDown, let u = s.netUp {
            netDown = d
            netUp = u
            downHistory = Array((downHistory + [d]).suffix(30))
            upHistory = Array((upHistory + [u]).suffix(30))
        }
        if let r = s.diskRead, let w = s.diskWrite {
            diskRead = r
            diskWrite = w
        }
        if let v = s.volumes, v != volumes { volumes = v }
        apply(temps: s.temps, generation: gen)
        if pending {
            pending = false
            tick()
        }
    }

    private func apply(temps t: SensorTemps?, generation gen: Int) {
        guard gen == generation, let t, t != temps else { return }
        temps = t
    }

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = image
        return image
    }
}

// 前回値との差分を持つため、専用のシリアルキューからだけ使う
nonisolated final class OverviewSampler: @unchecked Sendable {
    struct AppInfo: Sendable {
        let name: String
        let bundlePath: String?
    }

    private struct Counters {
        let cpu: UInt64
        let energy: UInt64
        let disk: UInt64
    }

    private struct ProcStat {
        let pid: pid_t
        let cpu: Double
        let memory: Double
        let power: Double
        let disk: Double
    }

    private var procPrev: [pid_t: Counters] = [:]
    private var procAt: UInt64 = 0
    private var gpuPrev: [pid_t: UInt64] = [:]
    private var gpuAt: UInt64 = 0
    private var netPrev: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var netAt: UInt64 = 0
    private var diskPrev: (read: UInt64, write: UInt64)?
    private var diskAt: UInt64 = 0
    private var paths: [pid_t: String] = [:]
    private var interfaceKinds: [String: (name: String, symbol: String)]?
    private var sensors: ThermalSensors?
    private var sensorsTried = false
    private let toNanos: Double
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    // ヘルパーやシステムの XPC サービスがどのアプリのために動いているかを返す（非公開 API）
    private let responsible: ResponsibleFn?

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        toNanos = Double(info.numer) / Double(max(info.denom, 1))
        responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }
    }

    func reset() {
        procPrev = [:]; procAt = 0
        gpuPrev = [:]; gpuAt = 0
        netPrev = [:]; netAt = 0
        diskPrev = nil; diskAt = 0
        paths = [:]
        sensors = nil
        sensorsTried = false
    }

    func sample(_ category: OverviewCategory, apps: [pid_t: AppInfo], temps: Bool, volumes: Bool) -> OverviewSnapshot {
        var s = OverviewSnapshot(category: category)
        switch category {
        case .cpu, .memory, .battery, .storage:
            let withDisk = category == .storage
            // 差分を取るための前回値がなければ、少し待って2回測る
            if isStale(procAt) || (withDisk && isStale(diskAt)) {
                _ = readProcesses()
                if withDisk { _ = readDiskIO() }
                usleep(400_000)
            }
            let stats = readProcesses()
            let values: [(pid_t, Double)] = switch category {
            case .cpu: stats.map { ($0.pid, $0.cpu) }
            case .memory: stats.map { ($0.pid, $0.memory) }
            case .battery: stats.map { ($0.pid, $0.power) }
            default: stats.map { ($0.pid, $0.disk) }
            }
            s.rows = group(values, apps: apps)
            if withDisk, let io = readDiskIO() {
                s.diskRead = io.read
                s.diskWrite = io.write
            }
        case .gpu:
            if isStale(gpuAt) {
                _ = readGPU()
                usleep(400_000)
            }
            s.rows = group(readGPU().map { ($0.key, $0.value) }, apps: apps)
        case .network:
            if isStale(netAt) {
                _ = readNetwork()
                usleep(400_000)
            }
            let net = readNetwork()
            s.interfaces = net.interfaces
            s.netDown = net.down
            s.netUp = net.up
        }
        if volumes { s.volumes = readVolumes() }
        if temps { s.temps = readTemps() }
        return s
    }

    func readTemps() -> SensorTemps? {
        if !sensorsTried {
            sensorsTried = true
            sensors = ThermalSensors()
        }
        return sensors?.read()
    }

    private func seconds(since t: UInt64, now: UInt64 = mach_absolute_time()) -> Double {
        Double(now &- t) * toNanos / 1e9
    }

    private func isStale(_ t: UInt64) -> Bool { t == 0 || seconds(since: t) > 10 }

    // MARK: Processes

    private func readProcesses() -> [ProcStat] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = mach_absolute_time()
        let dt = procAt > 0 ? max(seconds(since: procAt, now: now), 0.05) : 0
        var next: [pid_t: Counters] = [:]
        var result: [ProcStat] = []
        for pid in pids.prefix(max(got, 0)) where pid > 0 {
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            // 他のユーザー（root など）のプロセスは読めないので飛ばす
            guard ok == 0 else { continue }
            let c = Counters(cpu: ri.ri_user_time &+ ri.ri_system_time, energy: ri.ri_energy_nj,
                             disk: ri.ri_diskio_bytesread &+ ri.ri_diskio_byteswritten)
            next[pid] = c
            var cpu = 0.0, power = 0.0, disk = 0.0
            if dt > 0, let p = procPrev[pid] {
                if c.cpu >= p.cpu { cpu = Double(c.cpu - p.cpu) * toNanos / 1e9 / dt }
                if c.energy >= p.energy { power = Double(c.energy - p.energy) / 1e9 / dt }
                if c.disk >= p.disk { disk = Double(c.disk - p.disk) / dt }
            }
            result.append(ProcStat(pid: pid, cpu: cpu, memory: Double(ri.ri_phys_footprint), power: power, disk: disk))
        }
        procPrev = next
        procAt = now
        let alive = Set(pids.prefix(max(got, 0)))
        paths = paths.filter { alive.contains($0.key) }
        return result
    }

    // ヘルパー（"Google Chrome Helper (Renderer)" など）は親アプリにまとめる
    private func group(_ values: [(pid_t, Double)], apps: [pid_t: AppInfo]) -> [UsageRow] {
        var sums: [pid_t: Double] = [:]
        for (pid, v) in values where v > 0 { sums[owner(of: pid, apps: apps), default: 0] += v }
        // アプリ以外で同じ名前のプロセス（複数起動した CLI など）は1行にまとめる
        var merged: [String: UsageRow] = [:]
        for (pid, value) in sums.sorted(by: { $0.value > $1.value }).prefix(40) {
            let app = apps[pid]
            let n = app?.name ?? name(of: pid)
            let key = app != nil ? "app:\(pid)" : "name:\(n)"
            let prev = merged[key]
            merged[key] = UsageRow(id: prev?.id ?? pid, name: n, value: (prev?.value ?? 0) + value, isApp: app != nil)
        }
        return Array(merged.values.sorted { $0.value > $1.value }.prefix(8))
    }

    private func owner(of pid: pid_t, apps: [pid_t: AppInfo]) -> pid_t {
        if apps[pid] != nil { return pid }
        guard let responsible else { return pid }
        let r = responsible(pid)
        guard r > 0, r != pid, let app = apps[r], let path = path(of: pid) else { return pid }
        // ターミナルから起動したコマンドはまとめず、アプリ内のヘルパーと XPC サービスだけをまとめる
        if let bundle = app.bundlePath, path.hasPrefix(bundle + "/") { return r }
        return path.contains(".xpc/") || path.contains(".appex/") ? r : pid
    }

    private func path(of pid: pid_t) -> String? {
        if let cached = paths[pid] { return cached.isEmpty ? nil : cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        paths[pid] = path
        return path.isEmpty ? nil : path
    }

    private func name(of pid: pid_t) -> String {
        if let path = path(of: pid) {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "PID \(pid)" : name
    }

    // MARK: GPU

    // IOAccelerator の下にあるクライアントごとの累積 GPU 時間（ns）から、プロセス別の使用率を出す
    private func readGPU() -> [pid_t: Double] {
        var totals: [pid_t: UInt64] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var accel = IOIteratorNext(iterator)
        while accel != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
                       !usage.isEmpty,
                       let pidText = creator.split(separator: ",").first?.split(separator: " ").last,
                       let pid = pid_t(pidText) {
                        let sum = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                        totals[pid, default: 0] &+= sum
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accel)
            accel = IOIteratorNext(iterator)
        }
        let now = mach_absolute_time()
        let elapsed = gpuAt > 0 ? max(seconds(since: gpuAt, now: now), 0.05) * 1e9 : 0
        var result: [pid_t: Double] = [:]
        if elapsed > 0 {
            for (pid, total) in totals {
                if let prev = gpuPrev[pid], total > prev { result[pid] = min(Double(total - prev) / elapsed, 1) }
            }
        }
        gpuPrev = totals
        gpuAt = now
        return result
    }

    // MARK: Network

    private func readNetwork() -> (interfaces: [NetInterfaceInfo], down: Double, up: Double) {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return ([], 0, 0) }
        defer { freeifaddrs(ptr) }
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        var running = Set<String>()
        var v4: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name != "lo0" else { continue }
            if addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
                let flags = Int32(bitPattern: ifa.ifa_flags)
                if flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 { running.insert(name) }
            } else if addr.pointee.sa_family == UInt8(AF_INET), v4[name] == nil {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                v4[name] = String(cString: buffer)
            }
        }
        let now = mach_absolute_time()
        let dt = netAt > 0 ? max(seconds(since: netAt, now: now), 0.05) : 0
        // if_data のカウンタは 32 ビットなので一周したときを考える
        func delta(_ cur: UInt64, _ prev: UInt64) -> Double {
            if cur >= prev { return Double(cur - prev) }
            return prev > 0xC000_0000 ? Double(cur + (1 << 32) - prev) : 0
        }
        var rates: [String: (down: Double, up: Double)] = [:]
        if dt > 0 {
            for (name, c) in counters {
                guard let p = netPrev[name] else { continue }
                rates[name] = (delta(c.rx, p.rx) / dt, delta(c.tx, p.tx) / dt)
            }
        }
        netPrev = counters
        netAt = now

        let kinds = interfaceKindMap()
        let shown = v4.keys.filter { name in
            running.contains(name) && ["en", "utun", "ipsec", "ppp", "pdp_ip", "bridge"].contains { name.hasPrefix($0) }
        }
        let interfaces = shown.sorted { a, b in
            a.hasPrefix("en") != b.hasPrefix("en") ? a.hasPrefix("en") : a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(4).map { name in
            let kind = kinds[name] ?? Self.fallbackKind(name)
            return NetInterfaceInfo(id: name, name: kind.name, symbol: kind.symbol, address: v4[name] ?? "",
                                    down: rates[name]?.down ?? 0, up: rates[name]?.up ?? 0)
        }
        // VPN やブリッジは物理インターフェースと二重に数えるため、合計には含めない
        let physical = rates.filter { $0.key.hasPrefix("en") || $0.key.hasPrefix("pdp_ip") }.values
        return (Array(interfaces), physical.reduce(0) { $0 + $1.down }, physical.reduce(0) { $0 + $1.up })
    }

    private func interfaceKindMap() -> [String: (name: String, symbol: String)] {
        if let interfaceKinds { return interfaceKinds }
        var map: [String: (name: String, symbol: String)] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(i)
            let symbol = if type == kSCNetworkInterfaceTypeIEEE80211 { "wifi" }
                else if type == kSCNetworkInterfaceTypeEthernet { "cable.connector" }
                else if bsd.hasPrefix("bridge") { "point.3.connected.trianglepath.dotted" }
                else { "network" }
            map[bsd] = (name, symbol)
        }
        interfaceKinds = map
        return map
    }

    private static func fallbackKind(_ bsd: String) -> (name: String, symbol: String) {
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") { return (loc("VPN（%@）", bsd), "lock.shield") }
        if bsd.hasPrefix("bridge") { return (loc("ブリッジ（%@）", bsd), "point.3.connected.trianglepath.dotted") }
        if bsd.hasPrefix("pdp_ip") { return (loc("モバイル通信"), "antenna.radiowaves.left.and.right") }
        return (bsd, "network")
    }

    // MARK: Storage

    private func readDiskIO() -> (read: Double, write: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        let now = mach_absolute_time()
        defer {
            diskPrev = (read, write)
            diskAt = now
        }
        guard diskAt > 0, let prev = diskPrev, read >= prev.read, write >= prev.write else { return nil }
        let dt = max(seconds(since: diskAt, now: now), 0.05)
        return (Double(read - prev.read) / dt, Double(write - prev.write) / dt)
    }

    private func readVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        var list: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            var free = Double(v.volumeAvailableCapacity ?? 0)
            // 起動ボリュームはカードと同じく「重要な用途に使える容量」（パージ可能な領域を含む）で数える
            if url.path == "/", let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                free = Double(important)
            }
            let symbol = v.volumeIsLocal == false ? "server.rack" : v.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            list.append(VolumeInfo(id: url.path, name: v.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol,
                                   free: free / 1_000_000_000, total: Double(total) / 1_000_000_000))
        }
        return Array(list.prefix(3))
    }
}

// Apple シリコンの温度センサー（IOHIDEventSystemClient、非公開 API）
nonisolated final class ThermalSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int64, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    private let client: AnyObject
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let die: [AnyObject]
    private let battery: [AnyObject]

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(h, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(h, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // Usage Page 0xFF00（Apple ベンダー）/ Usage 5（温度センサー）
        unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let services = unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?.takeRetainedValue() as? [AnyObject] ?? []
        let property = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        let named: [(String, AnyObject)] = services.compactMap { s in
            (property(s, "Product" as CFString)?.takeRetainedValue() as? String).map { ($0, s) }
        }
        // M2 以降は "PMU tdie*"、M1 は "pACC/eACC MTR Temp Sensor*" が CPU ダイの温度
        var die = named.filter { $0.0.hasPrefix("PMU tdie") }.map(\.1)
        if die.isEmpty { die = named.filter { $0.0.contains("ACC MTR Temp Sensor") }.map(\.1) }
        let battery = named.filter { $0.0.hasPrefix("gas gauge battery") }.map(\.1)
        guard !die.isEmpty || !battery.isEmpty else { return nil }
        self.client = client
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)
        self.die = die
        self.battery = battery
    }

    func read() -> SensorTemps {
        func values(_ list: [AnyObject]) -> [Double] {
            list.compactMap { s -> Double? in
                guard let event = copyEvent(s, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
                return getFloat(event, Int32(Self.temperatureEvent << 16))
            }
            .filter { $0 > 0 && $0 < 130 }
        }
        let d = values(die), b = values(battery)
        return SensorTemps(soc: d.isEmpty ? nil : d.reduce(0, +) / Double(d.count), socMax: d.max(),
                           battery: b.isEmpty ? nil : b.reduce(0, +) / Double(b.count))
    }
}
