import AppKit
import Observation
import Sparkle

// Sparkle によるアップデート。配布物は EdDSA 署名で検証されるため、改ざんされた更新は適用されない
@Observable
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    @ObservationIgnored private let controller: SPUStandardUpdaterController

    // 公開鍵が埋め込まれていないビルド（ローカルの開発ビルドなど）ではアップデートを無効にする
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return !key.isEmpty && !feed.isEmpty
    }

    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = Self.isConfigured && controller.updater.automaticallyChecksForUpdates
    }

    func start() {
        _ = controller
    }

    func checkForUpdates() {
        guard Self.isConfigured else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
