import Foundation

/// 呼叫 Claude API（Anthropic Messages API）把逐字稿整理成會議紀錄。
/// Swift 沒有官方 SDK，因此直接用 URLSession 走 REST + Server-Sent Events 串流。
///
/// 規格來源（2026-09）：
/// - POST https://api.anthropic.com/v1/messages
/// - 預設模型 claude-opus-5；thinking 預設為 adaptive；用 output_config.effort 控制深度
/// - fallbacks: "default" + header anthropic-beta: server-side-fallback-2026-07-01
///   → 安全分類器拒答時，伺服器端自動改用建議的替代模型重跑，不必自己重試
/// - stop_reason == "refusal" 代表整條 fallback 鏈都拒答，必須先檢查再讀 content
enum ClaudeAPIError: LocalizedError {
    case missingAPIKey
    case transcriptTooLong(characters: Int)
    case invalidResponse
    case httpError(status: Int, type: String?, message: String)
    case streamError(type: String, message: String)
    case refused(category: String?, explanation: String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未設定 Claude API 金鑰，請到「設定」輸入。"
        case .transcriptTooLong(let n):
            return "逐字稿過長（\(n) 字），超過單次可處理的上限，請分段摘要。"
        case .invalidResponse:
            return "伺服器回應格式不正確。"
        case .httpError(let status, let type, let message):
            switch status {
            case 401: return "API 金鑰無效或已被停用（401）。請確認金鑰是否正確。"
            case 402: return "帳戶帳務問題（402），請到 Anthropic Console 檢查餘額。"
            case 403: return "此金鑰沒有權限使用該模型（403）。"
            case 404: return "找不到模型或端點（404），請確認模型名稱。"
            case 413: return "逐字稿過大，請求被拒絕（413）。"
            case 429: return "請求過於頻繁，已達速率上限（429），請稍後再試。"
            case 500...599: return "Anthropic 伺服器暫時異常（\(status)），請稍後再試。"
            default: return "API 錯誤 \(status) \(type ?? "")：\(message)"
            }
        case .streamError(let type, let message):
            return "串流中斷（\(type)）：\(message)"
        case .refused(let category, let explanation):
            var text = "模型拒絕處理這段內容"
            if let category { text += "（分類：\(category)）" }
            if let explanation, !explanation.isEmpty { text += "：\(explanation)" }
            return text
        case .emptyResponse:
            return "模型沒有回傳任何內容。"
        }
    }
}

struct ClaudeSummaryResult: Equatable {
    var markdown: String
    var model: String
    var stopReason: String?
    var inputTokens: Int
    var outputTokens: Int

    /// 輸出因 max_tokens 被截斷。注意思考 token 也計入 max_tokens，
    /// 所以 effort 拉高時實際消耗會比「可見的會議紀錄長度」多得多。
    var isTruncated: Bool { stopReason == "max_tokens" }
}

/// 各模型的計費與 API 形狀差異。
/// 重要：Haiku 4.5 不接受 adaptive thinking，也不接受 output_config.effort（會回 400），
/// 且 context 只有 200K，逐字稿上限要跟著降。
struct ClaudeModelOption: Identifiable, Sendable {
    let id: String
    let label: String
    /// 每百萬 token 價格（美元）。
    let inputPricePerMTok: Double
    let outputPricePerMTok: Double
    let supportsAdaptiveThinking: Bool
    let supportsEffort: Bool
    let supportsServerFallbacks: Bool
    let maxTranscriptCharacters: Int
    let maxOutputTokens: Int

    /// 一小時中文會議的粗估費用（新台幣）。
    /// 基準：輸入約 2.6 萬 token；輸出含思考依 effort 為 2,500／4,000／6,500 token，
    /// 不支援 effort 的模型（不思考）固定以 2,500 估算。
    func estimatedCostTWD(effort: ClaudeEffort) -> Double {
        let inputTokens = 26_000.0
        let outputTokens: Double = supportsEffort ? effort.estimatedOutputTokens : 2_500
        let usd = inputTokens / 1_000_000 * inputPricePerMTok
            + outputTokens / 1_000_000 * outputPricePerMTok
        return usd * 32.5   // 匯率僅供粗估
    }
}

/// 思考深度：直接對應 API 的 output_config.effort，影響思考 token 數，也就是費用。
enum ClaudeEffort: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "省錢（較快，適合單純的例會）"
        case .medium: return "平衡"
        case .high: return "品質優先（預設）"
        }
    }

    /// 粗估輸出 token（含思考），用來換算費用。
    var estimatedOutputTokens: Double {
        switch self {
        case .low: return 2_500
        case .medium: return 4_000
        case .high: return 6_500
        }
    }
}

final class ClaudeSummaryService {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let defaultModel = "claude-opus-5"
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// 可選模型。逐字稿字元上限：中文約 1~2 token/字，1M context 的模型給 30 萬字綽綽有餘；
    /// Haiku 只有 200K context，降到 10 萬字才安全。
    static let models: [ClaudeModelOption] = [
        ClaudeModelOption(
            id: "claude-opus-5", label: "Claude Opus 5（品質最佳）",
            inputPricePerMTok: 5, outputPricePerMTok: 25,
            supportsAdaptiveThinking: true, supportsEffort: true, supportsServerFallbacks: true,
            maxTranscriptCharacters: 300_000, maxOutputTokens: 64_000
        ),
        ClaudeModelOption(
            id: "claude-sonnet-5", label: "Claude Sonnet 5（品質好，約 1/2.5 價）",
            inputPricePerMTok: 2, outputPricePerMTok: 10,
            supportsAdaptiveThinking: true, supportsEffort: true, supportsServerFallbacks: false,
            maxTranscriptCharacters: 300_000, maxOutputTokens: 64_000
        ),
        ClaudeModelOption(
            id: "claude-haiku-4-5", label: "Claude Haiku 4.5（最便宜，品質較普通）",
            inputPricePerMTok: 1, outputPricePerMTok: 5,
            supportsAdaptiveThinking: false, supportsEffort: false, supportsServerFallbacks: false,
            maxTranscriptCharacters: 100_000, maxOutputTokens: 16_000
        ),
    ]

    static func option(for id: String) -> ClaudeModelOption {
        models.first { $0.id == id } ?? models[0]
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        // adaptive thinking 在長逐字稿上可能思考數十秒才吐出第一個字，
        // timeoutIntervalForRequest 是「兩次收到資料之間」的閒置逾時，預設 60 秒太短。
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    /// 串流產生會議紀錄。`onDelta` 會在主執行緒被呼叫，每次帶入新增的文字片段，方便即時顯示。
    func summarize(
        transcript: String,
        startedAt: Date,
        duration: TimeInterval,
        title: String?,
        apiKey: String,
        model: String = ClaudeSummaryService.defaultModel,
        effort: ClaudeEffort = .high,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> ClaudeSummaryResult {

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClaudeAPIError.missingAPIKey }

        let option = Self.option(for: model)
        guard transcript.count <= option.maxTranscriptCharacters else {
            throw ClaudeAPIError.transcriptTooLong(characters: transcript.count)
        }

        var body: [String: Any] = [
            "model": option.id,
            "max_tokens": option.maxOutputTokens,
            "stream": true,
            "system": [["type": "text", "text": SummaryPrompt.system]],
            "messages": [[
                "role": "user",
                "content": SummaryPrompt.userMessage(
                    transcript: transcript, startedAt: startedAt, duration: duration, title: title
                ),
            ]],
        ]
        // Haiku 4.5 不支援 adaptive thinking 與 effort，送了會被 400 拒絕，直接不帶（也最省）。
        if option.supportsAdaptiveThinking {
            body["thinking"] = ["type": "adaptive"]
        }
        if option.supportsEffort {
            body["output_config"] = ["effort": effort.rawValue]
        }
        // 伺服器端 fallbacks 目前只在 Opus 5 / Fable 5 系列有文件保證；其他模型不帶，以免被 400 拒絕。
        let usesFallbacks = option.supportsServerFallbacks
        if usesFallbacks {
            body["fallbacks"] = "default"
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // URLRequest 自己的 timeoutInterval（預設 60 秒）會優先於 session 設定，所以這裡也要拉長。
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesFallbacks {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }

        if http.statusCode != 200 {
            // 非 200 時 body 是一般 JSON 錯誤，不是 SSE。
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let err = obj?["error"] as? [String: Any]
            throw ClaudeAPIError.httpError(
                status: http.statusCode,
                type: err?["type"] as? String,
                message: err?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            )
        }

        var text = ""
        var servedModel = model
        var stopReason: String?
        var stopCategory: String?
        var stopExplanation: String?
        var inputTokens = 0
        var outputTokens = 0

        // SSE：每個事件是 "event: xxx" 加 "data: {...}"，以空行分隔。只需解析 data 行並依 type 分派。
        func handle(line: String) async throws {
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String
            else { return }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any] {
                    // fallback 發生時，這裡的 model 就是實際服務的替代模型。
                    if let m = message["model"] as? String { servedModel = m }
                    if let usage = message["usage"] as? [String: Any],
                       let n = usage["input_tokens"] as? Int { inputTokens = n }
                }

            case "content_block_delta":
                // 只取 text_delta；thinking_delta / signature_delta 忽略。
                if let delta = event["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let chunk = delta["text"] as? String, !chunk.isEmpty {
                    text += chunk
                    await onDelta(chunk)
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let s = delta["stop_reason"] as? String { stopReason = s }
                    if let details = delta["stop_details"] as? [String: Any] {
                        stopCategory = details["category"] as? String
                        stopExplanation = details["explanation"] as? String
                    }
                }
                if let usage = event["usage"] as? [String: Any],
                   let n = usage["output_tokens"] as? Int { outputTokens = n }

            case "error":
                let err = event["error"] as? [String: Any]
                throw ClaudeAPIError.streamError(
                    type: err?["type"] as? String ?? "unknown_error",
                    message: err?["message"] as? String ?? ""
                )

            default:
                // ping / content_block_start / content_block_stop / message_stop
                break
            }
        }

        // 自己以 LF 切行：AsyncBytes.lines 也會把 U+2028 / U+2029 / U+0085 當換行，
        // JSON 內若原樣出現這些字元，整段 data 會被切壞而靜默丟失。SSE 只用 LF / CRLF。
        var lineBuffer: [UInt8] = []
        lineBuffer.reserveCapacity(4096)
        for try await byte in bytes {
            if byte == 0x0A {
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                try await handle(line: line)
            } else {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            try await handle(line: String(decoding: lineBuffer, as: UTF8.self))
        }

        if stopReason == "refusal" {
            throw ClaudeAPIError.refused(category: stopCategory, explanation: stopExplanation)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeAPIError.emptyResponse }

        return ClaudeSummaryResult(
            markdown: trimmed,
            model: servedModel,
            stopReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    /// 用最便宜的方式驗證金鑰是否有效（用最便宜的模型送一個極短請求）。回傳 nil 代表成功。
    func validate(apiKey: String) async -> String? {
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 16,
            "messages": [["role": "user", "content": "回覆 OK"]],
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "伺服器回應格式不正確。" }
            if http.statusCode == 200 { return nil }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let err = obj?["error"] as? [String: Any]
            return ClaudeAPIError.httpError(
                status: http.statusCode,
                type: err?["type"] as? String,
                message: err?["message"] as? String ?? ""
            ).errorDescription
        } catch {
            return "無法連線到 Anthropic：\(error.localizedDescription)"
        }
    }
}
