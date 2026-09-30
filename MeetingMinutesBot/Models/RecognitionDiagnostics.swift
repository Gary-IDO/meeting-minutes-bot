import Foundation

/// 逐字稿的一段（依說話停頓切段），附上它在錄音裡的起始秒數。
/// 用途：逐字稿分頁顯示 [分:秒]，讓使用者能對照錄音檔回聽有問題的段落。
struct TimedSegment: Codable, Equatable, Hashable, Sendable {
    /// 在錄音檔中的起始時間（秒）。暫停的時間不會錄進檔案，也不會送進辨識器，
    /// 所以只要途中沒有音訊被丟掉，兩邊時間軸一致；有丟掉時見 RecognitionDiagnostics.lostAudioSeconds。
    var start: Double
    var text: String

    /// 例如 "03:25" 或 "1:02:10"
    var timeLabel: String {
        let total = max(0, Int(start.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// 辨識引擎在一場錄音中的統計數字（由引擎在 stop() 之後提供）。
struct EngineCounters: Sendable {
    /// 這個引擎有沒有真的在統計。沒有統計的引擎（備援的 SFSpeechRecognizer）為 false，
    /// 下面的數字都只是預設值，不能拿來顯示，否則「0 秒、0 段」會被誤讀成沒有問題。
    var isTracked: Bool = false
    /// 送進辨識器的音訊格式，例如 "16000 Hz / 1 聲道"
    var analyzerFormat: String?
    /// 格式轉換失敗而被丟掉的音訊片段數（應為 0）
    var failedConversions: Int = 0
    /// 辨識器處理不及、被緩衝區丟掉的音訊片段數（應為 0）
    var droppedBuffers: Int = 0
    /// 辨識器實際收到的音訊長度（秒），已扣掉被丟掉的部分
    var fedAudioSeconds: Double = 0
    /// 被丟掉、辨識器沒聽到的音訊長度（秒）。大於 0 時，之後的時間標記會比錄音早最多這麼多秒。
    var lostAudioSeconds: Double = 0
    /// 辨識器最後一段確定文字結束的位置（秒）
    var recognizedAudioSeconds: Double?
}

/// 每場會議保存一份「這次辨識是怎麼跑的」，用來找出逐字稿不準的原因。
/// 全部欄位都是事後回看用，不影響辨識本身。
struct RecognitionDiagnostics: Codable, Equatable, Hashable {
    var engine: String
    /// 設定裡選的語言，例如 "zh-TW"
    var requestedLocale: String
    /// 辨識器實際採用的語言，例如 "zh-TW"；若與上面不同就是被換成了別的地區
    var resolvedLocale: String
    var localeExactMatch: Bool
    /// 麥克風原始格式，例如 "48000 Hz / 1 聲道"
    var micFormat: String
    var analyzerFormat: String?
    /// 收音裝置，例如 "iPhone 麥克風（MicrophoneBuiltIn）"
    var inputRoute: String
    /// 內建麥克風的哪一顆，例如 "下方"
    var inputDataSource: String?
    /// 收音指向性，例如 "Omnidirectional"（全向）
    var polarPattern: String?
    var osVersion: String
    /// Apple 另一套聽寫模組（支援自訂詞彙與遠距收音）是否支援這個語言；nil 表示沒有查
    var dictationSupportsLocale: Bool?
    /// 以下三項只有會統計的引擎才有值；nil 表示這個引擎不提供，不是「0」。
    var failedConversions: Int?
    var droppedBuffers: Int?
    var fedAudioSeconds: Double?
    /// 被丟掉、辨識器沒聽到的音訊（秒）；大於 0 表示之後的時間標記可能比錄音早
    var lostAudioSeconds: Double?
    var recognizedAudioSeconds: Double?
    var segmentCount: Int

    /// 顯示用：把每個欄位翻成白話的一行。
    var displayRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("辨識引擎", engine),
            ("設定的語言", requestedLocale),
            ("實際使用的語言", resolvedLocale + (localeExactMatch ? "" : "（⚠︎ 與設定不同）")),
            ("麥克風格式", micFormat),
            ("送進辨識器的格式", analyzerFormat ?? "—"),
            ("收音裝置", inputRoute),
            ("麥克風位置", inputDataSource ?? "—"),
            ("收音指向性", polarPattern ?? "—"),
            ("系統版本", osVersion),
        ]
        if let dictationSupportsLocale {
            rows.append(("聽寫模組支援此語言", dictationSupportsLocale ? "是" : "否"))
        }
        let notProvided = "—（此引擎不提供）"
        rows.append(("轉換失敗的片段", failedConversions.map { "\($0)" } ?? notProvided))
        rows.append(("來不及處理而丟掉的片段", droppedBuffers.map { "\($0)" } ?? notProvided))
        rows.append(("辨識器實際收到的音訊", fedAudioSeconds.map { String(format: "%.1f 秒", $0) } ?? notProvided))
        if let lostAudioSeconds, lostAudioSeconds > 0 {
            rows.append(("被丟掉的音訊（時間標記可能提早）", String(format: "%.1f 秒", lostAudioSeconds)))
        }
        if let recognizedAudioSeconds {
            rows.append(("辨識到的最後位置", String(format: "%.1f 秒", recognizedAudioSeconds)))
        }
        rows.append(("逐字稿段數", "\(segmentCount)"))
        return rows
    }
}
