import AVFoundation
import Foundation

/// 逐字稿引擎共同介面。
/// RecordingSession 負責麥克風、AVAudioSession 與錄音檔；引擎只負責「音訊 buffer → 文字」。
protocol TranscriptionEngine: AnyObject {
    /// 顯示用名稱。
    var name: String { get }
    /// 是否需要網路（例如 Apple 伺服器辨識）。
    var requiresNetwork: Bool { get }

    /// 啟動引擎（可能耗時：第一次使用需下載語音模型）。引擎會在 append() 時自行把 buffer 轉成需要的格式。
    /// - onStatus: 進度文字（例如下載語音模型），任意執行緒呼叫。
    /// - onUpdate: (已確定文字, 暫定文字) 完整快照，任意執行緒呼叫。
    func start(
        onStatus: @escaping @Sendable (String) -> Void,
        onUpdate: @escaping @Sendable (_ finalized: String, _ volatile: String) -> Void
    ) async throws

    /// 由音訊 tap 執行緒呼叫，傳入原始麥克風 buffer。必須夠快、不可阻塞。
    func append(_ buffer: AVAudioPCMBuffer)

    /// 結束並回傳完整逐字稿（會等待最後的辨識結果）。
    func stop() async -> String

    /// 立即放棄，不等結果。
    func cancel()
}

/// 執行緒安全的 AVAudioConverter 包裝。
/// 輸入格式改變（例如中途接上藍牙耳機導致取樣率變化）時自動重建轉換器。
final class BufferConverter {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }

        lock.lock()
        defer { lock.unlock() }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            // 不做 priming，避免轉換後的 buffer 時間軸偏移（Apple 範例同樣設定）。
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            // 這個 closure 可能被呼叫多次，但我們只有一個 buffer 可以提供。
            if supplied {
                statusPointer.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// 音量表：在音訊執行緒計算 RMS，主執行緒讀取。
final class LevelMeter {
    private let lock = NSLock()
    private var value: Float = 0

    func update(with buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        // 轉成 0...1 的對數刻度，-50 dB 以下視為靜音。
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 50) / 50))
        lock.lock()
        value = value * 0.6 + normalized * 0.4
        lock.unlock()
    }

    func read() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

/// 對一個 async 作業設定逾時；到期時「一定」回傳 nil，即使作業本身不理會取消。
/// （用 withTaskGroup 實作的版本會在離開作用域時等待所有子任務，對不可取消的作業沒有效果。）
/// 逾時後被放棄的作業會在背景繼續跑到結束，對這裡的用途（結束辨識引擎）無害。
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let (stream, continuation) = AsyncStream.makeStream(of: T?.self)
    let work = Task {
        let value = await operation()
        continuation.yield(value)
    }
    let timer = Task {
        try? await Task.sleep(for: .seconds(seconds))
        continuation.yield(nil)
    }
    var iterator = stream.makeAsyncIterator()
    let result = await iterator.next() ?? nil
    work.cancel()
    timer.cancel()
    continuation.finish()
    return result
}
