import Darwin
import Foundation

// 本体は終了したのに、起動したプロセス（Android Studio の adb など）が残っているアプリ。
// 標準 Dock は「バックグラウンドで実行中」として出すが、NSWorkspace には出ないので LaunchServices の一覧から調べる
nonisolated enum LingeringApps {
    // バンドルのパス → 残っているプロセス
    static func scan() -> [String: [pid_t]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var coalitions: [UInt64: String] = [:]
        var path: String?
        var lingering = false
        func flush(_ coalition: UInt64?) {
            if lingering, let path, let coalition, path.hasSuffix(".app") { coalitions[coalition] = path }
        }
        var coalition: UInt64?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.first?.isNumber == true, text.contains(") \"") {
                flush(coalition)
                path = nil
                lingering = false
                coalition = nil
            } else if text.hasPrefix("bundle path=\"") {
                path = String(text.dropFirst(13).prefix { $0 != "\"" })
            } else if text.hasPrefix("pid = ") {
                lingering = text.contains("(exited-with-subordinates)") && text.contains("type=\"Foreground\"")
            } else if text.hasPrefix("coalition: ") {
                coalition = UInt64(text.dropFirst(11).prefix { $0.isNumber })
            }
        }
        flush(coalition)
        guard !coalitions.isEmpty else { return [:] }

        var result: [String: [pid_t]] = [:]
        for pid in allPIDs() where pid > 0 {
            guard let ids = coalitionIDs(pid), let path = coalitions[ids.0] ?? coalitions[ids.1], ownedByUser(pid) else { continue }
            result[path, default: []].append(pid)
        }
        return result
    }

    static func forceQuit(_ pids: [pid_t]) {
        for pid in pids where ownedByUser(pid) { kill(pid, SIGKILL) }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(max(n, 0))))
    }

    // PROC_PIDCOALITIONINFO（sys/proc_info.h）
    private struct CoalitionInfo {
        var ids: (UInt64, UInt64) = (0, 0)
        var reserved: (UInt64, UInt64, UInt64) = (0, 0, 0)
    }

    private static func coalitionIDs(_ pid: pid_t) -> (UInt64, UInt64)? {
        var info = CoalitionInfo()
        let size = Int32(MemoryLayout<CoalitionInfo>.size)
        guard proc_pidinfo(pid, 20, 0, &info, size) == size else { return nil }
        return info.ids
    }

    private static func ownedByUser(_ pid: pid_t) -> Bool {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbsi_uid == getuid()
    }
}
