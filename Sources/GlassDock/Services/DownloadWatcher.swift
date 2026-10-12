import Foundation

// ダウンロードフォルダに新しいファイルが届いたことを知らせる
@MainActor
final class DownloadWatcher {
    static let shared = DownloadWatcher()

    static let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    // ダウンロード途中のファイル（完了すると名前が変わる）
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pending: DispatchWorkItem?

    // 新しく届いたファイルと、今フォルダにあるファイル名
    var onChange: (([URL], Set<String>) -> Void)?

    func setActive(_ active: Bool) {
        if active, source == nil { start() } else if !active { stop() }
    }

    private func start() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Self.completedNames()
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { DownloadWatcher.shared.changed() } }
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
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = Self.completedNames()
            let added = current.subtracting(known)
            known = current
            onChange?(added.sorted().map { Self.folder.appendingPathComponent($0) }, current)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func completedNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { name in
            !name.hasPrefix(".") && !partialExtensions.contains((name as NSString).pathExtension.lowercased())
        })
    }
}
