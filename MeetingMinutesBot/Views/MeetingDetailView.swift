import SwiftUI
import UIKit

struct MeetingDetailView: View {
    let meetingID: UUID

    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryRunner.self) private var runner
    @Environment(\.openURL) private var openURL

    private enum Tab: String, CaseIterable {
        case summary = "會議紀錄"
        case transcript = "逐字稿"
    }

    @State private var tab: Tab = .summary
    @State private var editingTitle = ""
    @State private var showDeleteConfirm = false
    /// 零成本模式：複製成功後的短暫提示，以及貼上時的錯誤訊息。
    @State private var didCopyPrompt = false
    @State private var manualMessage: String?
    @State private var showManualInAPIMode = false

    private var meeting: Meeting? { store.meeting(id: meetingID) }

    var body: some View {
        if let meeting {
            content(meeting)
                .navigationTitle(meeting.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: meeting.exportText, subject: Text(meeting.displayTitle)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!meeting.hasUsableTranscript)
                    }
                }
                .onAppear {
                    editingTitle = meeting.title
                    if meeting.summaryMarkdown == nil && !runner.isRunning(meetingID) {
                        tab = meeting.hasUsableTranscript ? .summary : .transcript
                    }
                }
                // 離開畫面時才存檔：每打一個字就重寫整份 meetings.json 會讓打字卡頓。
                .onDisappear { commitTitle() }
        } else {
            ContentUnavailableView("這場會議已被刪除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            metaHeader(meeting)
            Picker("內容", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .summary: summaryTab(meeting)
            case .transcript: transcriptTab(meeting)
            }
        }
    }

    private func metaHeader(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("會議名稱", text: $editingTitle)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit { commitTitle() }

            HStack(spacing: 8) {
                // 日期是這排最有用的資訊：給它較高的佈局優先權，
                // 空間不足時讓模型名稱先被截斷，而不是日期先縮小。
                Label {
                    Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                } icon: {
                    Image(systemName: "calendar")
                }
                .layoutPriority(1)

                Label(meeting.durationText, systemImage: "clock")

                if let model = meeting.summaryModel {
                    Label(model, systemImage: "sparkles")
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - 會議紀錄

    @ViewBuilder
    private func summaryTab(_ meeting: Meeting) -> some View {
        let isRunning = runner.isRunning(meetingID)
        let live = runner.liveText[meetingID] ?? ""

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(live.isEmpty ? "Claude 正在閱讀逐字稿並思考…" : "正在產生會議紀錄…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { runner.cancel(meetingID: meetingID) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if !live.isEmpty {
                        MarkdownView(markdown: live)
                    }
                } else if let markdown = meeting.summaryMarkdown {
                    MarkdownView(markdown: markdown)
                    if let error = meeting.lastError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    if settings.summaryMode == .api {
                        regenerateButton(label: "重新產生會議紀錄")
                    } else {
                        DisclosureGroup("重新整理這份紀錄（零成本模式）") {
                            manualSection(meeting)
                        }
                        .font(.subheadline)
                    }
                } else {
                    VStack(spacing: 12) {
                        if meeting.status == .failed, let error = meeting.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                        } else if settings.summaryMode == .api {
                            Text("尚未產生會議紀錄。")
                                .foregroundStyle(.secondary)
                        }

                        if settings.summaryMode == .api {
                            if !settings.hasAPIKey {
                                Text("請先到「設定」輸入 Claude API 金鑰。")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                            regenerateButton(label: "產生會議紀錄")

                            DisclosureGroup(isExpanded: $showManualInAPIMode) {
                                manualSection(meeting)
                            } label: {
                                Text("不想花 API 費用？改用零成本模式")
                                    .font(.subheadline)
                            }
                            .padding(.top, 8)
                        } else {
                            manualSection(meeting)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, settings.summaryMode == .api ? 24 : 0)
                }
            }
            .padding()
        }
    }

    private func regenerateButton(label: String) -> some View {
        Button {
            runner.summarize(meetingID: meetingID, store: store, settings: settings)
        } label: {
            Label(label, systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!settings.hasAPIKey || !(meeting?.hasUsableTranscript ?? false))
    }

    // MARK: - 零成本模式

    /// 不呼叫 API：複製逐字稿與指示 → 貼到 Claude → 把結果貼回來。
    private func manualSection(_ meeting: Meeting) -> some View {
        let hasTranscript = meeting.hasUsableTranscript

        return VStack(alignment: .leading, spacing: 10) {
            Text("不呼叫 API，不會產生 API 費用（用你自己的 Claude 額度）。三個步驟：複製、貼到 Claude、把結果貼回來。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyPrompt(meeting)
            } label: {
                Label(
                    didCopyPrompt ? "已複製，接著貼到 Claude" : "① 複製逐字稿與指示",
                    systemImage: didCopyPrompt ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasTranscript)

            HStack(spacing: 10) {
                Button {
                    // Claude App 若已安裝，會由系統接手這個網址；沒安裝則開啟網頁版。
                    if let url = URL(string: "https://claude.ai/new") {
                        openURL(url)
                    }
                } label: {
                    Label("② 開啟 Claude", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(
                    item: SummaryPrompt.clipboardText(
                        transcript: meeting.transcript,
                        startedAt: meeting.startedAt,
                        duration: meeting.duration,
                        title: meeting.title
                    ),
                    subject: Text(meeting.displayTitle)
                ) {
                    // 與工具列的「分享」不同：這裡分享的是「指示＋逐字稿」的提示，
                    // 可直接丟給 Claude App 的分享擴充功能，是②的替代路徑。
                    Label("分享指示給 Claude", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasTranscript)
            }

            Button {
                pasteSummary()
            } label: {
                Label("③ 從剪貼簿貼上會議紀錄", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasTranscript)

            if let manualMessage {
                Text(manualMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copyPrompt(_ meeting: Meeting) {
        UIPasteboard.general.string = SummaryPrompt.clipboardText(
            transcript: meeting.transcript,
            startedAt: meeting.startedAt,
            duration: meeting.duration,
            title: meeting.title
        )
        manualMessage = nil
        didCopyPrompt = true
        // 幾秒後把按鈕文字還原，避免使用者以為要再按一次。
        Task {
            try? await Task.sleep(for: .seconds(4))
            didCopyPrompt = false
        }
    }

    private func pasteSummary() {
        guard let meeting, meeting.hasUsableTranscript else {
            manualMessage = "這場會議沒有逐字稿，無法建立會議紀錄。錄音檔仍保留在「檔案」App 中。"
            return
        }
        // hasStrings 只探測型別，不會觸發 iOS 16 之後的「要貼上嗎？」詢問，
        // 所以先用它分流「真的沒東西」與「使用者按了不允許」。
        guard UIPasteboard.general.hasStrings else {
            manualMessage = "剪貼簿裡沒有文字。請先在 Claude 裡複製它產生的會議紀錄。"
            return
        }
        guard let raw = UIPasteboard.general.string else {
            manualMessage = "沒有取得剪貼簿內容。系統詢問是否允許貼上時，請選「允許貼上」。"
            return
        }
        let pasted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else {
            manualMessage = "剪貼簿裡只有空白字元。請先在 Claude 裡複製它產生的會議紀錄。"
            return
        }
        // 防手誤：使用者可能把剛才複製出去的指示又貼回來。
        if pasted.contains(SummaryPrompt.clipboardMarker) || pasted.contains("【會議逐字稿】") {
            manualMessage = "剪貼簿裡還是剛才複製出去的逐字稿與指示。請改複製 Claude 產生的會議紀錄。"
            return
        }
        store.update(id: meetingID) {
            $0.summaryMarkdown = pasted
            $0.summaryModel = "手動貼上"
            $0.summaryGeneratedAt = Date()
            $0.status = .summarized
            $0.lastError = nil
        }
        manualMessage = nil
        didCopyPrompt = false
        showManualInAPIMode = false
    }

    // MARK: - 逐字稿

    private func transcriptTab(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !meeting.hasUsableTranscript {
                    Text("沒有逐字稿內容。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(meeting.transcript)
                        .textSelection(.enabled)
                }
                if let url = meeting.audioURL, FileManager.default.fileExists(atPath: url.path) {
                    Divider()
                    Label("錄音檔：\(url.lastPathComponent)（可在「檔案」App → 我的 iPhone → 會議紀錄機器人 → Recordings 找到）", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    // MARK: - Actions

    private func commitTitle() {
        guard let meeting, meeting.title != editingTitle else { return }
        store.update(id: meetingID) { $0.title = editingTitle }
    }
}
