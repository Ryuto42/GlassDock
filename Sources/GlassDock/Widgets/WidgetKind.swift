import AppKit

enum WidgetCategory: String, CaseIterable, Identifiable {
    case time, day, weather, media, system, tools
    var id: String { rawValue }
    var label: String { loc(jaLabel) }
    private var jaLabel: String {
        switch self {
        case .time: "時計"
        case .day: "予定"
        case .weather: "天気"
        case .media: "メディアとサウンド"
        case .system: "システム"
        case .tools: "ツール"
        }
    }
}

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case analogClock, digitalClock, worldClock, dayProgress
    case calendar, agenda, reminders
    case weather, weatherCompact
    case nowPlaying, volume
    case systemMonitor, battery, storage, network
    case gpu, memory, processes, peripherals, health, overview
    case pomodoro, quickNote, clipboard, colorPicker

    var id: String { rawValue }

    var title: String { loc(jaTitle) }
    private var jaTitle: String {
        switch self {
        case .analogClock: "アナログ時計"
        case .digitalClock: "デジタル時計"
        case .worldClock: "世界時計"
        case .dayProgress: "1日の進み具合"
        case .calendar: "カレンダー"
        case .agenda: "次の予定"
        case .reminders: "リマインダー"
        case .weather: "天気"
        case .weatherCompact: "天気（小）"
        case .nowPlaying: "再生中"
        case .volume: "音量"
        case .systemMonitor: "CPU・メモリ"
        case .battery: "バッテリー"
        case .storage: "ストレージ"
        case .network: "ネットワーク"
        case .gpu: "GPU"
        case .memory: "メモリ"
        case .processes: "プロセス"
        case .peripherals: "周辺機器のバッテリー"
        case .health: "ヘルスチェック"
        case .overview: "システム概要"
        case .pomodoro: "ポモドーロ"
        case .quickNote: "クイックメモ"
        case .clipboard: "クリップボード履歴"
        case .colorPicker: "カラーピッカー"
        }
    }

    var symbol: String {
        switch self {
        case .analogClock: "clock"
        case .digitalClock: "clock.badge"
        case .worldClock: "globe"
        case .dayProgress: "circle.dashed"
        case .calendar: "calendar"
        case .agenda: "calendar.day.timeline.left"
        case .reminders: "checklist"
        case .weather, .weatherCompact: "cloud.sun.fill"
        case .nowPlaying: "music.note"
        case .volume: "speaker.wave.2.fill"
        case .systemMonitor: "cpu"
        case .battery: "battery.75percent"
        case .storage: "internaldrive"
        case .network: "network"
        case .gpu: "cpu.fill"
        case .memory: "memorychip"
        case .processes: "list.bullet.rectangle"
        case .peripherals: "keyboard.badge.ellipsis"
        case .health: "checkmark.shield"
        case .overview: "gauge.with.dots.needle.67percent"
        case .pomodoro: "timer"
        case .quickNote: "note.text"
        case .clipboard: "doc.on.clipboard"
        case .colorPicker: "eyedropper"
        }
    }

    var category: WidgetCategory {
        switch self {
        case .analogClock, .digitalClock, .worldClock, .dayProgress: .time
        case .calendar, .agenda, .reminders: .day
        case .weather, .weatherCompact: .weather
        case .nowPlaying, .volume: .media
        case .systemMonitor, .battery, .storage, .network, .gpu, .memory, .processes, .peripherals, .health, .overview: .system
        case .pomodoro, .quickNote, .clipboard, .colorPicker: .tools
        }
    }

    // Dock 上の幅（アイコン何個分か）
    var widthFactor: CGFloat {
        switch self {
        case .digitalClock, .worldClock, .agenda, .weather, .nowPlaying, .systemMonitor, .network, .processes, .peripherals, .overview: 2
        default: 1
        }
    }

    var summary: String { loc(jaSummary) }
    private var jaSummary: String {
        switch self {
        case .analogClock: "針で時刻を表示。ホバーで日付と世界時計"
        case .digitalClock: "大きな数字の時計と日付"
        case .worldClock: "登録した都市の時刻を交互に表示"
        case .dayProgress: "今日が何％過ぎたかをリングで表示"
        case .calendar: "今日の日付。ホバーで月表示と今日の予定"
        case .agenda: "次の予定までの時間とタイトル"
        case .reminders: "未完了のリマインダー数。ホバーで一覧とチェック"
        case .weather: "現在の気温と天気。ホバーで1時間ごと・週間予報"
        case .weatherCompact: "気温だけのコンパクト表示"
        case .nowPlaying: "Spotify・ミュージックの再生中の曲。クリックで再生/一時停止"
        case .volume: "出力音量。クリックでミュート、ホバーでスライダー"
        case .systemMonitor: "CPU とメモリの使用率をリアルタイム表示"
        case .battery: "バッテリー残量と充電状態"
        case .storage: "起動ディスクの空き容量"
        case .network: "ダウンロード・アップロードの速度"
        case .gpu: "GPU の使用率と機種。ホバーで直近 1 分の推移"
        case .memory: "メモリの使用量。ホバーで内訳・スワップ・メモリプレッシャー"
        case .processes: "CPU を多く使っているアプリ。ホバーで CPU・メモリの上位"
        case .peripherals: "キーボード・マウス・AirPods などの残量"
        case .health: "熱・メモリ・ストレージ・CPU・バッテリーの状態をまとめて判定"
        case .overview: "CPU・GPU・メモリ・ネットワーク・ストレージ・バッテリー・プロセス・ヘルスチェックをひとつにまとめて表示"
        case .pomodoro: "集中・休憩タイマー。クリックで開始/一時停止"
        case .quickNote: "ホバーで開くメモ帳"
        case .clipboard: "最近コピーしたテキストを再コピー"
        case .colorPicker: "クリックで画面の色を取得して HEX をコピー"
        }
    }
}
