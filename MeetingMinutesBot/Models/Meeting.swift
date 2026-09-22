import Foundation

/// 一場會議的所有資料：錄音檔位置、逐字稿、Claude 產出的會議紀錄。
struct Meeting: Identifiable, Codable, Equatable, Hashable {

    enum Status: String, Codable {
        case recording      // 正在錄音 / 辨識中
        case transcribed    // 錄音結束，已有逐字稿，尚未摘要
        case summarizing    // 正在呼叫 Claude
        case summarized     // 已產出會議紀錄
        case failed         // 摘要失敗（可重試）

        var label: String {
            switch self {
            case .recording: return "錄音中"
            case .transcribed: return "待摘要"
            case .summarizing: return "摘要中"
            case .summarized: return "已完成"
            case .failed: return "失敗"
            }
        }
    }

    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    /// 相對於 Documents/Recordings 的檔名，例如 "2026-09-17_1030.m4a"
    var audioFileName: String?
    var transcript: String
    var summaryMarkdown: String?
    var summaryModel: String?
    var summaryGeneratedAt: Date?
    var lastError: String?
    var status: Status

    init(
        id: UUID = UUID(),
        title: String = "",
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String? = nil,
        transcript: String = "",
        summaryMarkdown: String? = nil,
        summaryModel: String? = nil,
        summaryGeneratedAt: Date? = nil,
        lastError: String? = nil,
        status: Status = .recording
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.summaryMarkdown = summaryMarkdown
        self.summaryModel = summaryModel
        self.summaryGeneratedAt = summaryGeneratedAt
        self.lastError = lastError
        self.status = status
    }

    /// 顯示用標題：使用者沒取名時用日期時間。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "會議 " + Meeting.titleFormatter.string(from: startedAt)
    }

    /// 是否有可用的逐字稿。只有空白字元（換行、空格）視同沒有內容。
    /// UI 的按鈕啟用條件與 SummaryRunner 的前置檢查都用這個，避免兩邊判斷不一致。
    var hasUsableTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var durationText: String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return MeetingStore.recordingsDirectory.appendingPathComponent(audioFileName)
    }

    /// 匯出用純文字：會議紀錄 + 逐字稿。
    var exportText: String {
        var text = ""
        if let summaryMarkdown {
            text += summaryMarkdown + "\n\n---\n\n"
        }
        text += "## 逐字稿\n\n" + transcript
        return text
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d HH:mm"
        return f
    }()
}
