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

    let name = "SpeechAnalyzer（iOS 26 裝置端辨識）"
    let requiresNetwork = false

    private let locale: Locale
    private let lock = NSLock()

    // 以下狀態皆受 lock 保護（start() 在背景執行、cancel() 可能從主執行緒同時進來）。
    private var finalized = ""
    private var volatile = ""
    private var cancelled = false
    private var inputClosed = false
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var converter: BufferConverter?
    private var onUpdate: (@Sendable (String, String) -> Void)?
    private var onStatus: (@Sendable (String) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    /// 檢查裝置硬體與語言是否可用。回傳實際可用的 Locale（可能是同語言的等價區域）。
    static func supportedLocale(matching locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
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
        // 結果串流：volatile 是同一段話的暫定版本（取代），isFinal 才追加。
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.lock.lock()
                    if result.isFinal {
                        self.finalized += text
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
                status?("辨識引擎中途停止：\(error.localizedDescription)。錄音仍在進行，結束後可用錄音檔重新辨識。")
            }
        }
        lock.unlock()

        try await analyzer.start(inputSequence: stream)
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
        guard !closed, let builder, let converter, let converted = converter.convert(buffer) else { return }
        builder.yield(AnalyzerInput(buffer: converted))
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
        return leftover.isEmpty ? finalized : finalized + leftover
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
}
