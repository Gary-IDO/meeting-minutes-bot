import AVFoundation
import Foundation
import Speech

/// 備援路徑：iOS 17/18，或 iOS 26 但硬體不支援 SpeechAnalyzer 的機型（iPhone 11、SE2）。
///
/// 使用 SFSpeechRecognizer。中文（台灣）在多數裝置上沒有裝置端模型，只能走 Apple 伺服器辨識：
/// 單一請求約 1 分鐘就會被系統停止，因此每 55 秒換一個新請求、把各段結果串起來。
/// 若裝置支援裝置端辨識（supportsOnDeviceRecognition），則沒有一分鐘限制，改為每 4 分鐘輪替一次以防長任務失效。
final class LegacyTranscriptionEngine: TranscriptionEngine {

    enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "語音辨識服務目前無法使用（請確認網路，或稍後再試）。"
            }
        }
    }

    let name: String
    let requiresNetwork: Bool

    private let recognizer: SFSpeechRecognizer
    private let isOnDevice: Bool
    private let rotationInterval: Duration
    /// 段落之間的分隔：中日文不加空格。
    private let partSeparator: String

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotateTask: Task<Void, Never>?
    /// segments[i] = 第 i 個請求的文字片段（通常只有一個；iOS 17 停頓 bug 時會有多個）。
    private var segments: [[String]] = []
    private var finishedSegments = Set<Int>()
    private var failedSegmentsInARow = 0   // 受 lock 保護
    private var stopped = false
    private var onUpdate: (@Sendable (String, String) -> Void)?
    private var onStatus: (@Sendable (String) -> Void)?

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.recognizer = recognizer
        isOnDevice = recognizer.supportsOnDeviceRecognition
        requiresNetwork = !isOnDevice
        name = isOnDevice
            ? "SFSpeechRecognizer（裝置端）"
            : "SFSpeechRecognizer（Apple 伺服器，每 55 秒分段）"
        rotationInterval = isOnDevice ? .seconds(240) : .seconds(55)
        let language = locale.language.languageCode?.identifier ?? ""
        partSeparator = ["zh", "ja", "yue"].contains(language) ? "" : " "
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func start(
        onStatus: @escaping @Sendable (String) -> Void,
        onUpdate: @escaping @Sendable (String, String) -> Void
    ) async throws {
        guard recognizer.isAvailable else { throw Failure.unavailable }
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        if requiresNetwork {
            onStatus("此系統版本的中文（台灣）辨識需透過 Apple 伺服器，請保持網路連線。")
        }
        beginSegment()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    // MARK: - 分段輪替

    private func beginSegment() {
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = true
        if isOnDevice {
            newRequest.requiresOnDeviceRecognition = true
        }

        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        let index = segments.count
        segments.append([])
        let previous = request
        request = newRequest
        lock.unlock()

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.record(text: result.bestTranscription.formattedString, segment: index, isFinal: result.isFinal)
            }
            guard error != nil || result?.isFinal == true else { return }

            // 一段時間沒人說話時，請求結束會回 kAFAssistantErrorDomain 1110「No speech detected」，
            // 取消則是 216；這兩種是正常現象，不算辨識失敗。
            let nsError = error.map { $0 as NSError }
            let isBenign = nsError.map {
                $0.domain == "kAFAssistantErrorDomain" && ($0.code == 1110 || $0.code == 216)
            } ?? false

            self.lock.lock()
            self.finishedSegments.insert(index)
            let segmentEmpty = self.segments.indices.contains(index) && self.segments[index].joined().isEmpty
            let hadFailures = self.failedSegmentsInARow > 0
            if error != nil && segmentEmpty && !isBenign {
                self.failedSegmentsInARow += 1
            } else if result?.isFinal == true {
                self.failedSegmentsInARow = 0
            }
            let failures = self.failedSegmentsInARow
            let isStopped = self.stopped
            self.lock.unlock()

            // 沒網路、被 Apple 限流、或裝置端語言未下載時，每段都會很快失敗：告訴使用者，而不是整場安靜沒字。
            if let error, segmentEmpty, !isBenign, !isStopped {
                let hint = self.requiresNetwork ? "請確認網路連線；" : ""
                self.onStatus?("語音辨識失敗（連續 \(failures) 段）：\(error.localizedDescription)。\(hint)錄音仍在進行。")
            } else if hadFailures, failures == 0, !isStopped, self.requiresNetwork {
                // 只在從失敗恢復時才更新狀態列，避免每 55 秒覆蓋掉 RecordingSession 寫入的中斷／路由提示。
                self.onStatus?("使用 Apple 伺服器辨識中，請保持網路連線")
            }
        }

        // 讓上一段送出最終結果。不能 cancel()，否則最後一段文字會遺失。
        previous?.endAudio()

        rotateTask?.cancel()
        let interval = rotationInterval
        rotateTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.beginSegment()
        }
    }

    private func record(text: String, segment index: Int, isFinal: Bool) {
        lock.lock()
        guard index < segments.count else {
            lock.unlock()
            return
        }
        var parts = segments[index]
        if let last = parts.last, !isFinal, last.count >= 10, text.count < last.count / 2 {
            // iOS 17.x 已知 bug：停頓後的結果不再累積、從頭開始。文字突然大幅縮短時視為新片段追加。
            parts.append(text)
        } else if parts.isEmpty {
            parts = [text]
        } else {
            parts[parts.count - 1] = text
        }
        segments[index] = parts

        let currentIndex = segments.count - 1
        let finalizedText = segments[..<currentIndex]
            .map { $0.joined(separator: partSeparator) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let volatileText = segments[currentIndex].joined(separator: partSeparator)
        lock.unlock()

        onUpdate?(finalizedText, volatileText)
    }

    // MARK: - 結束

    func stop() async -> String {
        rotateTask?.cancel()
        lock.lock()
        stopped = true
        let current = request
        request = nil
        let lastIndex = segments.count - 1
        lock.unlock()

        current?.endAudio()

        // 最多等 4 秒讓最後一段的 isFinal 回來。
        for _ in 0..<20 {
            lock.lock()
            let done = lastIndex < 0 || finishedSegments.contains(lastIndex)
            lock.unlock()
            if done { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        lock.lock()
        defer { lock.unlock() }
        return segments
            .map { $0.joined(separator: partSeparator) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func cancel() {
        rotateTask?.cancel()
        lock.lock()
        stopped = true
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
        task?.cancel()
    }
}
