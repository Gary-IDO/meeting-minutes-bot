import Foundation
import Observation

/// 管理「呼叫 Claude 產生會議紀錄」的背景工作。
/// 放在 App 環境中，使用者離開詳情頁面時摘要仍會繼續，完成後寫回 MeetingStore。
@MainActor
@Observable
final class SummaryRunner {

    /// 正在摘要中的會議 id → 目前已串流回來的文字（供畫面即時顯示）。
    private(set) var liveText: [UUID: String] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let service = ClaudeSummaryService()

    func isRunning(_ meetingID: UUID) -> Bool {
        tasks[meetingID] != nil
    }

    /// 開始（或重新）產生會議紀錄。若該會議已在進行中則忽略。
    func summarize(meetingID: UUID, store: MeetingStore, settings: AppSettings) {
        guard tasks[meetingID] == nil else { return }
        guard let meeting = store.meeting(id: meetingID) else { return }

        guard let apiKey = settings.currentAPIKey(), !apiKey.isEmpty else {
            store.update(id: meetingID) {
                $0.status = .failed
                $0.lastError = ClaudeAPIError.missingAPIKey.errorDescription
            }
            return
        }

        let transcript = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meeting.hasUsableTranscript else {
            store.update(id: meetingID) {
                $0.status = .failed
                $0.lastError = "逐字稿是空的，沒有內容可以摘要。請確認麥克風權限與辨識語言設定。"
            }
            return
        }

        store.update(id: meetingID) {
            $0.status = .summarizing
            $0.lastError = nil
        }
        liveText[meetingID] = ""

        let model = settings.model
        let effort = settings.effort
        let title = meeting.title
        let startedAt = meeting.startedAt
        let duration = meeting.duration

        tasks[meetingID] = Task { [weak self] in
            guard let self else { return }
            // 不論哪條路徑結束，都要清掉進行中狀態，否則畫面會永遠顯示「摘要中」。
            defer {
                self.liveText[meetingID] = nil
                self.tasks[meetingID] = nil
            }
            do {
                let result = try await service.summarize(
                    transcript: transcript,
                    startedAt: startedAt,
                    duration: duration,
                    title: title,
                    apiKey: apiKey,
                    model: model,
                    effort: effort
                ) { chunk in
                    self.liveText[meetingID, default: ""] += chunk
                }
                try Task.checkCancellation()
                store.update(id: meetingID) {
                    $0.summaryMarkdown = result.markdown
                    $0.summaryModel = result.model
                    $0.summaryGeneratedAt = Date()
                    $0.status = .summarized
                    $0.lastError = result.isTruncated ? "輸出可能不完整（達到長度上限）。" : nil
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    // 使用者取消：若先前已有會議紀錄（重新產生被取消），狀態維持「已完成」。
                    store.update(id: meetingID) {
                        $0.status = $0.summaryMarkdown == nil ? .transcribed : .summarized
                    }
                } else {
                    store.update(id: meetingID) {
                        $0.status = .failed
                        $0.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancel(meetingID: UUID) {
        tasks[meetingID]?.cancel()
    }

    /// 測試 API 金鑰是否可用；回傳 nil 表示成功。
    func validate(apiKey: String) async -> String? {
        await service.validate(apiKey: apiKey)
    }
}
