import AVFoundation
import Foundation
import Observation
import Speech

struct RecordingResult {
    var transcript: String
    var audioFileName: String?
    var startedAt: Date
    var duration: TimeInterval
}

enum RecordingError: LocalizedError {
    case alreadyRunning
    case microphoneDenied
    case speechRecognitionDenied
    case localeUnsupported
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已經在錄音中。"
        case .microphoneDenied:
            return "沒有麥克風權限。請到 iOS「設定 → 隱私權與安全性 → 麥克風」開啟。"
        case .speechRecognitionDenied:
            return "沒有語音辨識權限。請到 iOS「設定 → 隱私權與安全性 → 語音辨識」開啟。"
        case .localeUnsupported:
            return "此裝置不支援所選的辨識語言。請在設定中改選其他語言。"
        case .noAudioInput:
            return "找不到可用的麥克風輸入。"
        }
    }
}

/// 音訊執行緒專用的狀態容器（不在 MainActor 上），tap closure 只碰這個物件。
final class AudioTapSink {
    let meter = LevelMeter()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileConverter: BufferConverter?
    private var transcriber: (any TranscriptionEngine)?

    func configure(file: AVAudioFile?, transcriber: any TranscriptionEngine) {
        lock.lock()
        self.file = file
        self.fileConverter = file.map { BufferConverter(outputFormat: $0.processingFormat) }
        self.transcriber = transcriber
        lock.unlock()
    }

    /// 關閉錄音檔（AVAudioFile 在釋放時寫入檔尾）。
    func closeFile() {
        lock.lock()
        file = nil
        fileConverter = nil
        lock.unlock()
    }

    func detachTranscriber() {
        lock.lock()
        transcriber = nil
        lock.unlock()
    }

    /// 在音訊執行緒執行：量音量、寫檔、丟給引擎。不可阻塞、不碰 UI。
    func handle(_ buffer: AVAudioPCMBuffer) {
        meter.update(with: buffer)
        lock.lock()
        let file = self.file
        let converter = self.fileConverter
        let transcriber = self.transcriber
        lock.unlock()

        if let file {
            if let converted = converter?.convert(buffer) {
                try? file.write(from: converted)
            } else {
                try? file.write(from: buffer)
            }
        }
        transcriber?.append(buffer)
    }
}

/// 一次錄音的協調者：麥克風 → (1) 寫入 .m4a 錄音檔 (2) 餵給逐字稿引擎。
/// 錄音檔是「事實來源」：即使辨識失敗，音檔仍保留可事後處理。
@MainActor
@Observable
final class RecordingSession {

    enum State: Equatable {
        case idle, preparing, recording, paused, stopping
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var audioLevel: Float = 0
    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    private(set) var engineName = ""
    /// 準備階段的進度說明（下載模型等）與錄音中的提示。
    private(set) var statusDetail = ""
    private(set) var startedAt: Date?
    var errorMessage: String?

    private let engine = AVAudioEngine()
    private let sink = AudioTapSink()
    private var audioFileName: String?
    private var transcriber: (any TranscriptionEngine)?
    private var tapFormat: AVAudioFormat?

    private var tickTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var interruptedWhileRecording = false

    /// 設定頁顯示用：這台裝置會用哪個引擎。
    static var preferredEngineDescription: String {
        if #available(iOS 26, *) {
            return SpeechTranscriber.isAvailable
                ? "SpeechAnalyzer（iOS 26 裝置端）"
                : "SFSpeechRecognizer（此機型不支援 SpeechAnalyzer）"
        }
        return "SFSpeechRecognizer（iOS 17 / 18）"
    }

    // MARK: - Start

    func start(locale: Locale) async throws {
        guard state == .idle else { throw RecordingError.alreadyRunning }
        state = .preparing
        errorMessage = nil
        finalizedTranscript = ""
        volatileTranscript = ""
        elapsed = 0
        accumulated = 0
        audioFileName = nil
        startedAt = nil
        interruptedWhileRecording = false
        sink.meter.reset()

        do {
            statusDetail = "正在請求麥克風權限…"
            guard await AVAudioApplication.requestRecordPermission() else {
                throw RecordingError.microphoneDenied
            }
            try ensureStillPreparing()

            statusDetail = "正在選擇辨識引擎…"
            let transcriber = try await makeTranscriber(locale: locale)
            try ensureStillPreparing()
            // 先指派，使用者在下載模型時按取消，cancel() 才能中止它。
            self.transcriber = transcriber

            // 先啟動辨識引擎（第一次使用可能要下載模型、耗時數分鐘）。
            // 這段時間還沒佔用麥克風、也沒建立錄音檔，使用者按取消時沒有東西要清。
            try await transcriber.start(
                onStatus: { [weak self] text in
                    Task { @MainActor in self?.statusDetail = text }
                },
                onUpdate: { [weak self] finalized, volatile in
                    Task { @MainActor in
                        guard let self else { return }
                        self.finalizedTranscript = finalized
                        self.volatileTranscript = volatile
                    }
                }
            )
            try ensureStillPreparing()   // 下載 / 載入模型期間使用者可能已按取消

            let session = AVAudioSession.sharedInstance()
            // playAndRecord 而非 record：record 會把系統所有聲音靜音。spokenAudio 適合連續人聲。
            // 不加 .allowBluetoothHFP：會議錄音要用手機內建麥克風收整個房間，而不是耳機上只收配戴者的窄頻麥克風。
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // 硬體格式要在 session 啟用後讀，並且緊接著 installTap；
            // 用過期的格式裝 tap 會觸發無法攔截的 NSException。
            let micFormat = engine.inputNode.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                throw RecordingError.noAudioInput
            }

            let audioFile = try openAudioFile(format: micFormat)
            engineName = transcriber.name
            sink.configure(file: audioFile, transcriber: transcriber)

            installTap(format: micFormat)
            engine.prepare()
            try engine.start()

            let now = Date()
            startedAt = now
            segmentStart = now
            state = .recording
            statusDetail = transcriber.requiresNetwork ? "使用 Apple 伺服器辨識中，請保持網路連線" : ""
            startTicking()
            startDraftSaving()
            observeAudioNotifications()
        } catch {
            await teardown(deleteAudio: true)
            state = .idle
            statusDetail = ""
            throw error
        }
    }

    /// start() 每個 await 之後呼叫：cancel() 會把 state 改成 .idle，SwiftUI 關閉畫面也會取消 .task。
    private func ensureStillPreparing() throws {
        if Task.isCancelled || state != .preparing {
            throw CancellationError()
        }
    }

    private func makeTranscriber(locale: Locale) async throws -> any TranscriptionEngine {
        if #available(iOS 26, *) {
            if let supported = await AnalyzerTranscriptionEngine.supportedLocale(matching: locale) {
                return AnalyzerTranscriptionEngine(locale: supported)
            }
        }
        // 備援：SFSpeechRecognizer 需要語音辨識授權。
        let status = await LegacyTranscriptionEngine.requestAuthorization()
        guard status == .authorized else { throw RecordingError.speechRecognitionDenied }
        guard let legacy = LegacyTranscriptionEngine(locale: locale) else {
            throw RecordingError.localeUnsupported
        }
        return legacy
    }

    private func openAudioFile(format micFormat: AVAudioFormat) throws -> AVAudioFile {
        let fileName = MeetingStore.newRecordingFileName(ext: "m4a")
        let url = MeetingStore.recordingsDirectory.appendingPathComponent(fileName)
        do {
            // AAC 64 kbps：一小時約 28 MB。取樣率與聲道數必須與 tap 格式一致，write(from:) 才不會失敗。
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: micFormat.sampleRate,
                AVNumberOfChannelsKey: micFormat.channelCount,
                AVEncoderBitRateKey: 64_000,
            ])
            audioFileName = fileName
            return file
        } catch {
            // 少數裝置格式組合 AAC 會失敗：退回 Apple 範例用的未壓縮 CAF（約 11 MB/分鐘）。
            let cafName = MeetingStore.newRecordingFileName(ext: "caf")
            let cafURL = MeetingStore.recordingsDirectory.appendingPathComponent(cafName)
            let file = try AVAudioFile(forWriting: cafURL, settings: micFormat.settings)
            audioFileName = cafName
            return file
        }
    }

    private func installTap(format: AVAudioFormat) {
        tapFormat = format
        let sink = self.sink
        // 這個 closure 在音訊執行緒執行，只能碰 sink（非 MainActor）。
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.handle(buffer)
        }
    }

    // MARK: - Pause / Resume

    func pause() {
        guard state == .recording else { return }
        engine.pause()
        accumulated += elapsedInCurrentSegment()
        segmentStart = nil
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        do {
            // 先啟用 session 再讀輸入格式（與 start() 相同順序）：session 未啟用時硬體格式可能還不正確。
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

            // 通話 / Siri 交接後輸入可能仍是 0 Hz；用這種格式啟動引擎會觸發無法攔截的 NSException。
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                errorMessage = "音訊輸入仍無法使用，請稍後再按「繼續」"
                return
            }
            // handleEngineConfigurationChange 在 0 Hz 時提早返回、沒有換 tap；輸入回來後格式若已不同，須重裝 tap。
            if let tapFormat, format != tapFormat {
                engine.inputNode.removeTap(onBus: 0)
                installTap(format: format)
            }
            engine.prepare()
            try engine.start()
            segmentStart = Date()
            state = .recording
            errorMessage = nil
        } catch {
            errorMessage = "無法繼續錄音：\(error.localizedDescription)"
        }
    }

    // MARK: - Stop / Cancel

    func stop() async -> RecordingResult {
        let totalDuration = accumulated + elapsedInCurrentSegment()
        let started = startedAt ?? Date().addingTimeInterval(-totalDuration)
        state = .stopping
        statusDetail = "正在整理最後的辨識結果…"

        tickTask?.cancel()
        draftTask?.cancel()
        removeObservers()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapFormat = nil
        sink.detachTranscriber()
        sink.closeFile()   // 關檔，寫入 m4a 尾端資訊

        var transcript = finalizedTranscript
        if let transcriber {
            let finalText = await withTimeout(seconds: 60) { await transcriber.stop() }
            if let finalText, !finalText.isEmpty {
                transcript = finalText
            } else if !volatileTranscript.isEmpty {
                transcript = finalizedTranscript + volatileTranscript
            }
        }
        transcriber = nil
        removeDraft()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let result = RecordingResult(
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            audioFileName: audioFileName,
            startedAt: started,
            duration: totalDuration
        )
        state = .idle
        statusDetail = ""
        elapsed = 0
        audioLevel = 0
        return result
    }

    func cancel() {
        tickTask?.cancel()
        draftTask?.cancel()
        removeObservers()
        let wasPreparing = (state == .preparing)
        state = .idle
        statusDetail = ""
        // 立刻放棄正在啟動或執行中的引擎。
        transcriber?.cancel()
        if !wasPreparing {
            Task { await teardown(deleteAudio: true) }
        }
        // wasPreparing：start() 會在下一個 await 之後拋出 CancellationError，由它的 catch 執行 teardown，
        // 避免兩邊同時清理。
    }

    private func teardown(deleteAudio: Bool) async {
        if engine.isRunning || tapFormat != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            tapFormat = nil
        }
        sink.detachTranscriber()
        sink.closeFile()
        transcriber?.cancel()
        transcriber = nil
        if deleteAudio, let audioFileName {
            try? FileManager.default.removeItem(
                at: MeetingStore.recordingsDirectory.appendingPathComponent(audioFileName)
            )
        }
        removeDraft()
        audioFileName = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Timer & draft

    private func elapsedInCurrentSegment() -> TimeInterval {
        guard let segmentStart else { return 0 }
        return Date().timeIntervalSince(segmentStart)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.accumulated + self.elapsedInCurrentSegment()
                self.audioLevel = self.state == .recording ? self.sink.meter.read() : 0
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// 每 15 秒把已確定的逐字稿寫到錄音檔旁的 .txt，App 被系統殺掉時不會全部遺失
    /// （MeetingStore 啟動時會把孤兒錄音檔復原成會議）。
    private func startDraftSaving() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            var lastSaved = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                let text = self.finalizedTranscript
                if text != lastSaved, let url = self.draftURL {
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                    lastSaved = text
                }
            }
        }
    }

    private var draftURL: URL? {
        guard let audioFileName else { return nil }
        return MeetingStore.recordingsDirectory
            .appendingPathComponent(audioFileName)
            .deletingPathExtension()
            .appendingPathExtension("txt")
    }

    private func removeDraft() {
        if let draftURL {
            try? FileManager.default.removeItem(at: draftURL)
        }
    }

    // MARK: - Interruptions / route / engine config changes

    private func observeAudioNotifications() {
        removeObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// 來電、鬧鐘、Siri 等中斷：暫停；結束後若系統允許就自動恢復。
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if state == .recording {
                interruptedWhileRecording = true
                pause()
                statusDetail = "錄音被其他 App 或來電中斷，結束後會自動繼續"
            }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if interruptedWhileRecording && options.contains(.shouldResume) {
                interruptedWhileRecording = false
                resume()
                statusDetail = ""
            } else if interruptedWhileRecording {
                interruptedWhileRecording = false
                statusDetail = "中斷已結束，請按「繼續」恢復錄音"
            }
        @unknown default:
            break
        }
    }

    /// 接上／拔掉藍牙耳機等造成輸入格式改變：引擎已自行停止，需重裝 tap 並重新啟動。
    private func handleEngineConfigurationChange() {
        guard state == .recording || state == .paused else { return }
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        // 通話 / Siri 交接期間輸入可能暫時不可用（0 Hz / 0 聲道），
        // 用這種格式 installTap 會觸發無法攔截的 NSException 而閃退。
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            pauseAfterFailure("音訊輸入暫時無法使用，請稍後按「繼續」恢復錄音")
            return
        }
        if let tapFormat, newFormat != tapFormat {
            engine.inputNode.removeTap(onBus: 0)
            installTap(format: newFormat)   // BufferConverter 會自動處理新格式
        }
        guard state == .recording else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            pauseAfterFailure("音訊裝置改變後無法重新啟動錄音：\(error.localizedDescription)。請按「繼續」再試一次")
        }
    }

    /// 引擎無法繼續時改成「已暫停」：計時停止、畫面出現「繼續」按鈕，而不是假裝仍在錄音。
    private func pauseAfterFailure(_ message: String) {
        if state == .recording {
            engine.pause()
            accumulated += elapsedInCurrentSegment()
            segmentStart = nil
            state = .paused
        }
        // 中斷期間由 handleInterruption 負責提示（結束後多半會自動 resume），不顯示要按「繼續」的錯誤訊息。
        if !interruptedWhileRecording {
            errorMessage = message
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        switch reason {
        case .newDeviceAvailable:
            let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
            statusDetail = inputs.isEmpty ? "" : "輸入來源：\(inputs.joined(separator: ", "))"
        case .oldDeviceUnavailable:
            statusDetail = "外接麥克風已移除，改用內建麥克風"
        default:
            break
        }
    }
}
