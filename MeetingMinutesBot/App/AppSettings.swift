import Foundation
import Observation

/// 使用者設定：模型、辨識語言、是否錄音結束後自動摘要。存在 UserDefaults；API 金鑰另存 Keychain。
@MainActor
@Observable
final class AppSettings {

    /// 會議紀錄的產生方式。
    enum SummaryMode: String, CaseIterable, Identifiable {
        /// App 直接呼叫 Anthropic API，自動產生（按用量計費）。
        case api
        /// 零成本：把逐字稿與指示複製出去，使用者自己貼到 Claude App／claude.ai，再把結果貼回來。
        case manual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .api: return "自動呼叫 Claude API（按用量計費）"
            case .manual: return "手動貼到 Claude App（零成本）"
            }
        }

    }

    static let availableLocales: [(id: String, label: String)] = [
        ("zh-TW", "中文（台灣）"),
        ("zh-CN", "中文（中國）"),
        ("en-US", "English (US)"),
        ("ja-JP", "日本語"),
    ]

    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Keys.locale) }
    }

    var autoSummarize: Bool {
        didSet { defaults.set(autoSummarize, forKey: Keys.autoSummarize) }
    }

    /// 思考深度，直接影響 API 費用。
    var effort: ClaudeEffort {
        didSet { defaults.set(effort.rawValue, forKey: Keys.effort) }
    }

    var summaryMode: SummaryMode {
        didSet { defaults.set(summaryMode.rawValue, forKey: Keys.summaryMode) }
    }

    /// 是否已在 Keychain 存有金鑰。改變金鑰後請呼叫 refreshAPIKeyStatus()。
    private(set) var hasAPIKey: Bool = false

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let model = "settings.model"
        static let locale = "settings.locale"
        static let autoSummarize = "settings.autoSummarize"
        static let effort = "settings.effort"
        static let summaryMode = "settings.summaryMode"
    }

    init() {
        // 模型清單可能在改版後變動：舊值若已不存在就修正並寫回，
        // 否則 Picker 會顯示未選取、而實際送出的是清單第一個模型。
        let storedModel = defaults.string(forKey: Keys.model)
        if let storedModel, ClaudeSummaryService.models.contains(where: { $0.id == storedModel }) {
            model = storedModel
        } else {
            model = ClaudeSummaryService.defaultModel
            defaults.set(ClaudeSummaryService.defaultModel, forKey: Keys.model)
        }
        localeIdentifier = defaults.string(forKey: Keys.locale) ?? "zh-TW"
        autoSummarize = defaults.object(forKey: Keys.autoSummarize) as? Bool ?? true
        effort = defaults.string(forKey: Keys.effort).flatMap(ClaudeEffort.init(rawValue:)) ?? .high
        summaryMode = defaults.string(forKey: Keys.summaryMode).flatMap(SummaryMode.init(rawValue:)) ?? .api
        refreshAPIKeyStatus()
    }

    /// 這個模式是否需要 API 金鑰才能運作。
    var needsAPIKey: Bool { summaryMode == .api }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// 目前選用模型的設定（含價格與 API 能力）。
    var modelOption: ClaudeModelOption { ClaudeSummaryService.option(for: model) }

    /// 一小時會議的粗估費用文字。
    var estimatedCostText: String {
        let twd = modelOption.estimatedCostTWD(effort: effort)
        return String(format: "一小時會議約新台幣 %.1f 元", twd)
    }

    func refreshAPIKeyStatus() {
        hasAPIKey = !(KeychainStore.read() ?? "").isEmpty
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete()
        } else {
            try KeychainStore.save(trimmed)
        }
        refreshAPIKeyStatus()
    }

    func currentAPIKey() -> String? {
        KeychainStore.read()
    }
}
