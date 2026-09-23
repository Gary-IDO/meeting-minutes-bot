import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var keyStatus: KeyStatus = .idle
    @State private var isValidating = false

    private enum KeyStatus: Equatable {
        case idle
        case saved
        case valid
        case invalid(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                modeSection
                if settings.summaryMode == .api {
                    apiKeySection
                    modelSection
                }
                recordingSection
                if settings.summaryMode == .manual && settings.hasAPIKey {
                    unusedKeySection
                }
                aboutSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if settings.hasAPIKey { keyStatus = .saved }
            }
        }
    }

    // MARK: - 摘要方式

    @ViewBuilder
    private var modeSection: some View {
        @Bindable var settings = settings

        Section {
            Picker("摘要方式", selection: $settings.summaryMode) {
                ForEach(AppSettings.SummaryMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("會議紀錄怎麼產生")
        } footer: {
            Text(settings.summaryMode == .api
                 ? "App 直接呼叫 Anthropic API，錄音結束後自動產生。需要 API 金鑰，並依用量計費。"
                 : "不會產生 Anthropic API 費用：在會議頁按「複製逐字稿與指示」，貼到 Claude App 或 claude.ai 請它整理，再把結果貼回 App 保存。不需要 API 金鑰，但會用到你 Claude 帳號本身的用量額度（免費或 Pro 方案）。")
        }
    }

    // MARK: - API 金鑰

    @ViewBuilder
    private var apiKeySection: some View {
        Section {
            SecureField("sk-ant-api03-…", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))

            HStack {
                Button("儲存金鑰") { saveKey() }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if settings.hasAPIKey {
                    Button("刪除金鑰", role: .destructive) {
                        try? settings.saveAPIKey("")   // 空字串 → 從 Keychain 刪除
                        apiKeyInput = ""
                        keyStatus = .idle
                    }
                    Spacer()
                }
                Button {
                    Task { await validateKey() }
                } label: {
                    if isValidating {
                        ProgressView()
                    } else {
                        Text("測試連線")
                    }
                }
                .disabled(isValidating || (apiKeyInput.isEmpty && !settings.hasAPIKey))
            }

            statusRow
        } header: {
            Text("Claude API 金鑰")
        } footer: {
            Text("金鑰只存在這支手機的 Keychain，不會上傳到任何地方（除了 Anthropic 官方 API）。到 console.anthropic.com → API Keys 建立金鑰，那裡也可以設定每月用量上限。實際金額請看下方「摘要模型與費用」。")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch keyStatus {
        case .idle:
            if settings.hasAPIKey {
                Label("已儲存金鑰", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Label("尚未設定金鑰", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
        case .saved:
            Label("已儲存金鑰（尚未測試）", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .valid:
            Label("連線成功，金鑰可用", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var unusedKeySection: some View {
        Section {
            Button("刪除已儲存的 API 金鑰", role: .destructive) {
                try? settings.saveAPIKey("")
                apiKeyInput = ""
                keyStatus = .idle
            }
        } footer: {
            Text("目前是零成本模式，不會用到金鑰。金鑰仍留在這支手機的 Keychain 裡，可以刪除。")
        }
    }

    // MARK: - 模型與費用

    @ViewBuilder
    private var modelSection: some View {
        @Bindable var settings = settings

        Section {
            Picker("模型", selection: $settings.model) {
                ForEach(ClaudeSummaryService.models) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if settings.modelOption.supportsEffort {
                Picker("思考深度", selection: $settings.effort) {
                    ForEach(ClaudeEffort.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
            }

            LabeledContent("預估費用", value: settings.estimatedCostText)
                .foregroundStyle(.secondary)
        } header: {
            Text("摘要模型與費用")
        } footer: {
            Text("費用是 Anthropic API 的用量計費，與 Claude 訂閱方案（Pro／Team）分開計算，不能互相折抵。想省錢就選 Haiku、把思考深度調低，或改用上面的零成本模式。金額為粗估，實際以 Anthropic Console 的用量為準。")
        }
    }

    // MARK: - 錄音與辨識

    @ViewBuilder
    private var recordingSection: some View {
        @Bindable var settings = settings

        Section {
            Picker("辨識語言", selection: $settings.localeIdentifier) {
                ForEach(AppSettings.availableLocales, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            if settings.summaryMode == .api {
                Toggle("錄音結束後自動產生會議紀錄", isOn: $settings.autoSummarize)
            }
        } header: {
            Text("錄音與辨識")
        } footer: {
            Text("語音辨識完全在手機上執行，不需網路也不收費；第一次使用某個語言時，系統可能需要下載語言模型。\n\n一場錄音只使用這裡選定的一種語言，中途不會自動切換。中文模式下夾雜的英文單字與專有名詞通常辨識得到，但整段英語對話會變差。台語、客語等方言不在 Apple 支援的語言內，那些段落會被硬套成發音相近的國語，看起來通順但內容不對；產生會議紀錄時會請 Claude 標記出這類段落，看到標記請回聽錄音確認。\n\n若辨識結果為空，請到 iOS「設定 → 一般 → 鍵盤 → 聽寫」確認已啟用聽寫並下載該語言。")
        }
    }

    // MARK: - 關於

    @ViewBuilder
    private var aboutSection: some View {
        Section("關於") {
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
            LabeledContent("逐字稿引擎", value: RecordingSession.preferredEngineDescription)
        }
    }

    // MARK: - Actions

    private func saveKey() {
        do {
            try settings.saveAPIKey(apiKeyInput)
            keyStatus = .saved
            apiKeyInput = ""
        } catch {
            keyStatus = .invalid(error.localizedDescription)
        }
    }

    private func validateKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (settings.currentAPIKey() ?? "")
            : apiKeyInput
        guard !key.isEmpty else { return }
        isValidating = true
        defer { isValidating = false }
        if let error = await runner.validate(apiKey: key) {
            keyStatus = .invalid(error)
        } else {
            keyStatus = .valid
            if !apiKeyInput.isEmpty {
                try? settings.saveAPIKey(apiKeyInput)
                apiKeyInput = ""
            }
        }
    }
}
