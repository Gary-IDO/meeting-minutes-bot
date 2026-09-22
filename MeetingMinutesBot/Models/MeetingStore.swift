import AVFoundation
import Foundation
import Observation

/// 會議清單的本機儲存：JSON 檔放在 Documents/meetings.json，錄音檔放在 Documents/Recordings/。
/// 不用 Core Data / SwiftData，一個人的會議紀錄用 JSON 就夠，也方便透過「檔案」App 備份。
@MainActor
@Observable
final class MeetingStore {

    private(set) var meetings: [Meeting] = []

    // 路徑常數標為 nonisolated：Meeting（非 MainActor）與音訊執行緒也會用到。
    nonisolated static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    nonisolated static let recordingsDirectory: URL = {
        let url = documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated private static let indexURL = documentsDirectory.appendingPathComponent("meetings.json")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        load()
        recoverOrphanRecordings()
    }

    // MARK: - CRUD

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func upsert(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        meetings.sort { $0.startedAt > $1.startedAt }
        save()
    }

    func update(id: UUID, _ mutate: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&meetings[index])
        save()
    }

    func delete(_ meeting: Meeting) {
        if let url = meeting.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        meetings.removeAll { $0.id == meeting.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        offsets.map { meetings[$0] }.forEach(delete)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        do {
            meetings = try decoder.decode([Meeting].self, from: data)
                .sorted { $0.startedAt > $1.startedAt }
            // App 被殺掉時若還在錄音 / 摘要中，狀態要修正回可重試的狀態。
            for i in meetings.indices {
                switch meetings[i].status {
                case .recording, .summarizing:
                    meetings[i].status = meetings[i].hasUsableTranscript ? .transcribed : .failed
                default: break
                }
            }
        } catch {
            print("MeetingStore load failed: \(error)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(meetings)
            try data.write(to: Self.indexURL, options: [.atomic])
        } catch {
            print("MeetingStore save failed: \(error)")
        }
    }

    /// App 在錄音中被系統殺掉時，Recordings/ 裡會留下沒有對應會議的音檔（旁邊可能有 .txt 逐字稿草稿）。
    /// 啟動時把它們復原成會議，讓使用者仍可產生紀錄。
    private func recoverOrphanRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let known = Set(meetings.compactMap(\.audioFileName))
        var recovered = false

        for url in files {
            let ext = url.pathExtension.lowercased()
            guard ["m4a", "caf", "wav"].contains(ext), !known.contains(url.lastPathComponent) else { continue }

            let draftURL = url.deletingPathExtension().appendingPathExtension("txt")
            // 草稿可能只剩換行或空白（辨識一直沒有結果時），一律視同沒有逐字稿。
            let transcript = ((try? String(contentsOf: draftURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 啟動失敗或取消時殘留的空檔案：直接刪掉，不要變成一場假會議。
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < 4_096 && transcript.isEmpty {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: draftURL)
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let duration: TimeInterval = (try? AVAudioFile(forReading: url))
                .map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0

            var meeting = Meeting(
                title: "（已復原的錄音）",
                startedAt: created,
                duration: duration,
                audioFileName: url.lastPathComponent,
                transcript: transcript,
                status: transcript.isEmpty ? .failed : .transcribed
            )
            if transcript.isEmpty {
                meeting.lastError = "App 在錄音途中被關閉，只保留了錄音檔，沒有逐字稿。"
            } else {
                meeting.lastError = "App 在錄音途中被關閉，逐字稿為最後一次自動儲存的版本（可能少了最後幾秒）。"
            }
            meetings.append(meeting)
            try? fm.removeItem(at: draftURL)
            recovered = true
        }

        if recovered {
            meetings.sort { $0.startedAt > $1.startedAt }
            save()
        }
    }

    /// 產生新的錄音檔名（含時間戳）。
    nonisolated static func newRecordingFileName(for date: Date = Date(), ext: String = "m4a") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // 固定西曆與阿拉伯數字，檔名才穩定
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date) + "." + ext
    }
}
