import Foundation

// ダウンロードフォルダに新しいファイルが届いたことを知らせる
@MainActor
final class DownloadWatcher {
    static let shared = DownloadWatcher()

    static let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    // ダウンロード途中のファイル（完了すると名前が変わる）
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]

    private var source: DispatchSourceFileSystemObject?
    // 完了済みのファイル名と inode。名前を変えただけのファイルを新着と数えないよう、inode でも見分ける
    private var known: [String: UInt64] = [:]
    private var pending: DispatchWorkItem?

    // 新しく届いたファイルと、今フォルダにあるファイル名
    var onChange: (([URL], Set<String>) -> Void)?

    func setActive(_ active: Bool) {
        if active, source == nil { start() } else if !active { stop() }
    }

    private func start() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Self.completedEntries()
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak s] in
            let event = s?.data ?? []
            MainActor.assumeIsolated { DownloadWatcher.shared.changed(folderMoved: !event.isDisjoint(with: [.rename, .delete])) }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
    }

    // 書き込みは連続して届くので、落ち着いてからまとめて調べる
    private func changed(folderMoved: Bool) {
        // フォルダ自体が消えた・移動したときは、同じパスで開き直す（無ければ次に有効にしたとき開く）
        if folderMoved {
            stop()
            start()
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = Self.completedEntries()
            let inodes = Set(known.values)
            let added = current.filter { self.known[$0.key] == nil && !inodes.contains($0.value) }.keys
            known = current
            onChange?(added.sorted().map { Self.folder.appendingPathComponent($0) }, Set(current.keys))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func completedEntries() -> [String: UInt64] {
        guard let dir = opendir(folder.path) else { return [:] }
        defer { closedir(dir) }
        var result: [String: UInt64] = [:]
        while let entry = readdir(dir) {
            var nameBuffer = entry.pointee.d_name
            let name = withUnsafeBytes(of: &nameBuffer) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard !name.hasPrefix("."), !partialExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            result[name] = UInt64(entry.pointee.d_ino)
        }
        return result
    }
}
