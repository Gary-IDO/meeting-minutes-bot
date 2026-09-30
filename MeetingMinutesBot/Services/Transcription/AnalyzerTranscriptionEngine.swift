import AVFoundation
import Foundation
import Speech

/// iOS 26 以上的主要路徑：SpeechAnalyzer + SpeechTranscriber。
/// - 完全在裝置端執行（第一次使用某語言時下載模型，之後離線可用）
/// - 沒有一分鐘限制，適合 1～2 小時的會議
/// - 支援 zh_TW；需要 iPhone 12 以上（iPhone 11 / SE2 的 isAvailable 為 false）
/// - 不需要語音辨識授權（NSSpeechRecognitionUsageDescription），只需麥克風權限
@available(iOS 26, *)
final class AnalyzerTranscriptionEngine: TranscriptionEngine {

    enum Failure: LocalizedError {
        case noAnalyzerFormat

        var errorDescription: String? {
            switch self {
            case .noAnalyzerFormat:
                return "無法取得辨識引擎需要的音訊格式（語音模型可能尚未安裝完成）。"
            }
        }
    }

    /// 兩段確定文字之間停頓超過這麼久（秒）就換段。
    private static let paragraphGap: Double = 1.5
    /// 一段超過這麼多字，下一句就換段，確保長時間沒停頓時也有時間標記可以對照錄音。
    private static let paragraphMaxLength = 300

    /// 顯示實際採用的語言，例如「SpeechAnalyzer 裝置端（zh-TW）」，才看得出有沒有被換成別的地區。
    var name: String { "SpeechAnalyzer 裝置端（\(locale.identifier(.bcp47))）" }
    let requiresNetwork = false

    private let locale: Locale
    private let lock = NSLock()

    // 以下狀態皆受 lock 保護（start() 在背景執行、cancel() 可能從主執行緒同時進來）。
    private var finalized = ""
    private var volatile = ""
    private var segments: [TimedSegment] = []
    private var lastFinalEnd: Double?
    private var cancelled = false
    private var inputClosed = false
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var converter: BufferConverter?
    private var onUpdate: (@Sendable (String, String) -> Void)?
    private var onStatus: (@Sendable (String) -> Void)?

    // 診斷統計（受 lock 保護）
    private var analyzerFormatDescription: String?
    private var analyzerSampleRate: Double = 0
    private var fedFrames: Int64 = 0
    private var failedConversions = 0
    private var droppedBuffers = 0
    /// 辨識器沒聽到的音訊（秒），分兩種記：
    /// - failedSeconds：轉換失敗，從來沒交給辨識器（不在 fedFrames 裡）
    /// - droppedSeconds：已交出去、但在緩衝區裡被擠掉（有算進 fedFrames，要扣回來）
    private var failedSeconds: Double = 0
    private var droppedSeconds: Double = 0

    init(locale: Locale) {
        self.locale = locale
    }

    // MARK: - 語言

    /// 找出辨識器要用的語言：優先用語言與地區都完全相同的；
    /// 沒有才退而用 Apple 建議的近似語言（可能是別的地區），並回報不是完全相同，讓畫面能警告。
    /// Apple 文件原文：沒有完全相同時會回傳「同語言、不同地區」的語言，"This may result in an unexpected transcription"。
    static func resolveLocale(for requested: Locale) async -> (locale: Locale, isExact: Bool)? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { sameLanguageAndRegion($0, requested) }) {
            return (exact, true)
        }
        guard let near = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return nil }
        return (near, sameLanguageAndRegion(near, requested))
    }

    /// 只比語言與地區（例如 zh + TW），忽略文字寫法等其他標記，避免 "zh-TW" 與 "zh-Hant-TW" 被誤判為不同。
    static func sameLanguageAndRegion(_ a: Locale, _ b: Locale) -> Bool {
        a.language.languageCode == b.language.languageCode && a.region == b.region
    }

    /// 診斷用：Apple 另一套聽寫模組（DictationTranscriber，支援自訂詞彙與遠距收音提示）支不支援這個語言。
    static func dictationSupports(_ locale: Locale) async -> Bool {
        let supported = await DictationTranscriber.supportedLocales
        return supported.contains { sameLanguageAndRegion($0, locale) }
    }

    // MARK: - Start

    func start(
        onStatus: @escaping @Sendable (String) -> Void,
        onUpdate: @escaping @Sendable (String, String) -> Void
    ) async throws {
        lock.lock()
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        lock.unlock()

        // 會議場景：要 volatile（即時暫定文字），不要 fastResults（犧牲準確度換速度）。
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try checkNotCancelled()

        // 第一次使用該語言需下載模型；模型由系統管理、跨 App 共用、不佔 App 容量。
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("正在下載語音模型（第一次使用需要網路）…")
            let progress = request.progress
            let progressTask = Task {
                while !Task.isCancelled {
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    onStatus("正在下載語音模型 \(percent)%（第一次使用需要網路）…")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
        }
        try checkNotCancelled()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        lock.lock()
        self.analyzer = analyzer
        lock.unlock()

        // 分析器不會自行轉換取樣率/聲道，必須由我們轉成它要的格式，否則會靜悄悄地什麼都辨識不到。
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAnalyzerFormat
        }
        try checkNotCancelled()

        onStatus("正在載入辨識引擎…")
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try checkNotCancelled()

        // 有上限的緩衝：分析器若落後超過約 4 分鐘就丟最舊的資料，而不是吃光記憶體。
        let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(3000))

        lock.lock()
        if cancelled || inputClosed {
            lock.unlock()
            builder.finish()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        inputBuilder = builder
        converter = BufferConverter(outputFormat: analyzerFormat)
        analyzerFormatDescription = analyzerFormat.diagnosticDescription
        analyzerSampleRate = analyzerFormat.sampleRate
        // 結果串流：volatile 是同一段話的暫定版本（取代），isFinal 才追加。
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.lock.lock()
                    if result.isFinal {
                        self.appendFinal(text, start: result.range.start.seconds, end: result.range.end.seconds)
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    let snapshot = (self.finalized, self.volatile)
                    let update = self.onUpdate
                    self.lock.unlock()
                    update?(snapshot.0, snapshot.1)
                }
            } catch {
                // 辨識引擎中途出錯：分析器不會再消化輸入，必須關閉輸入串流，否則 append() 會無上限堆積 buffer。
                guard let self, !(error is CancellationError) else { return }
                let builder = self.closeInput()
                builder?.finish()
                self.lock.lock()
                let status = self.onStatus
                self.lock.unlock()
                status?("辨識引擎中途停止：\(error.localizedDescription)。錄音仍在進行，錄音檔會完整保留，事後可以回聽。")
            }
        }
        lock.unlock()

        try await analyzer.start(inputSequence: stream)
    }

    /// 把一段確定文字加進逐字稿；停頓夠久或這段已經很長時就換段，並記下起始秒數。
    /// 呼叫端必須已持有 lock。
    private func appendFinal(_ text: String, start: Double, end: Double) {
        let startsNewParagraph: Bool
        if let last = segments.last {
            let gapIsLong = start.isFinite && (lastFinalEnd.map { start - $0 > Self.paragraphGap } ?? false)
            startsNewParagraph = gapIsLong || last.text.count >= Self.paragraphMaxLength
        } else {
            startsNewParagraph = true
        }

        if startsNewParagraph {
            let segmentStart = start.isFinite ? start : (lastFinalEnd ?? 0)
            segments.append(TimedSegment(start: segmentStart, text: text))
            finalized += finalized.isEmpty ? text : "\n" + text
        } else {
            segments[segments.count - 1].text += text
            finalized += text
        }
        if end.isFinite {
            lastFinalEnd = end
        }
    }

    /// start() 每個 await 之後呼叫：cancel() 設定的旗標或 SwiftUI 取消 .task 都會讓啟動流程提早結束。
    private func checkNotCancelled() throws {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    // MARK: - Audio in

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let closed = inputClosed
        let builder = inputBuilder
        let converter = self.converter
        lock.unlock()
        guard !closed, let builder, let converter else { return }

        guard let converted = converter.convert(buffer) else {
            // 錄音檔照樣寫進了這段，辨識器卻沒收到：之後的時間標記會比錄音早這麼多。
            lock.lock()
            failedConversions += 1
            if buffer.format.sampleRate > 0 {
                failedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }
            lock.unlock()
            return
        }
        let result = builder.yield(AnalyzerInput(buffer: converted))

        lock.lock()
        switch result {
        case .enqueued(_):
            fedFrames += Int64(converted.frameLength)
        case .dropped(let old):
            // 緩衝區滿了：新的這段有進去，但最舊的一段被擠掉，辨識器永遠不會聽到那一段。
            fedFrames += Int64(converted.frameLength)
            droppedBuffers += 1
            // 用音訊本身的長度算（bufferDuration 要 iOS 27 才有，這裡用 iOS 26 就有的 buffer）。
            let dropped = old.buffer
            if dropped.format.sampleRate > 0 {
                droppedSeconds += Double(dropped.frameLength) / dropped.format.sampleRate
            }
        case .terminated:
            // 輸入串流已經關閉（正在結束），這段沒有送出去，不算數。
            break
        @unknown default:
            break
        }
        lock.unlock()
    }

    /// 標記輸入已關閉並取出 continuation（呼叫端負責 finish()）。回傳 nil 表示已經關過或尚未開啟。
    private func closeInput() -> AsyncStream<AnalyzerInput>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        let wasClosed = inputClosed
        inputClosed = true
        let builder = inputBuilder
        inputBuilder = nil
        return wasClosed ? nil : builder
    }

    // MARK: - Stop / Cancel

    func stop() async -> String {
        let builder = closeInput()
        let inputWasStillOpen = (builder != nil)
        builder?.finish()

        lock.lock()
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        lock.unlock()

        if let analyzer {
            var finished = false
            if inputWasStillOpen {
                // 等輸入序列被完整消化並產出最後的 final 結果；逾時就強制結束。
                finished = await withTimeout(seconds: 45) {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        return true
                    } catch {
                        return false
                    }
                } ?? false
            }
            if !finished {
                // finalize 逾時、拋錯，或引擎先前已因錯誤停止：強制結束（已結束的分析器呼叫這個是 no-op）。
                await analyzer.cancelAndFinishNow()
            }
        }

        if let resultsTask {
            // 結果串流理論上在分析器結束後就會終止；保險起見 10 秒後直接取消。
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                resultsTask.cancel()
            }
            await resultsTask.value
            watchdog.cancel()
        }

        lock.lock()
        defer { lock.unlock() }
        let leftover = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftover.isEmpty else { return finalized }
        // 最後一句還沒確定就結束了：當成一般文字補在最後，分段也一起補上，兩邊內容才會一致。
        if segments.isEmpty {
            segments.append(TimedSegment(start: lastFinalEnd ?? 0, text: leftover))
        } else {
            segments[segments.count - 1].text += leftover
        }
        return finalized + leftover
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let analyzer = self.analyzer
        let task = self.resultsTask
        lock.unlock()

        closeInput()?.finish()
        task?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    // MARK: - 診斷

    var timedSegments: [TimedSegment] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }

    var counters: EngineCounters {
        lock.lock()
        defer { lock.unlock() }
        let handedOver = analyzerSampleRate > 0 ? Double(fedFrames) / analyzerSampleRate : 0
        return EngineCounters(
            isTracked: true,
            analyzerFormat: analyzerFormatDescription,
            failedConversions: failedConversions,
            droppedBuffers: droppedBuffers,
            // 交出去的減掉在緩衝區被擠掉的，才是辨識器真正聽到的長度（轉換失敗的本來就沒算進去）。
            fedAudioSeconds: max(0, handedOver - droppedSeconds),
            // 兩種丟失都會讓之後的時間標記比錄音早。
            lostAudioSeconds: failedSeconds + droppedSeconds,
            recognizedAudioSeconds: lastFinalEnd
        )
    }
}
