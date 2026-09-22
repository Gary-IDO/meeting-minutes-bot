import SwiftUI
import UIKit

/// 錄音畫面：顯示計時、音量、即時逐字稿；按「停止」後建立 Meeting 並（可選）自動送 Claude 摘要。
struct RecordingView: View {
    /// 錄音結束後回傳新會議 id（取消或失敗時為 nil）。
    let onFinish: (UUID?) -> Void

    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss

    @State private var session = RecordingSession()
    @State private var title = ""
    @State private var isStopping = false
    @State private var showCancelConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header
                transcriptArea
                controls
            }
            .padding()
            .navigationTitle("錄音中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        if session.state == .recording || session.state == .paused {
                            showCancelConfirm = true
                        } else {
                            cancelAndClose()
                        }
                    }
                    .disabled(isStopping)
                }
            }
            .confirmationDialog("放棄這段錄音？", isPresented: $showCancelConfirm, titleVisibility: .visible) {
                Button("放棄錄音", role: .destructive) { cancelAndClose() }
                Button("繼續錄音", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(true)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            do {
                try await session.start(locale: settings.locale)
            } catch is CancellationError {
                // 使用者在準備階段按了取消，畫面即將關閉。
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 10) {
            TextField("會議名稱（選填）", text: $title)
                .textFieldStyle(.roundedBorder)

            Text(timeString(session.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()

            LevelBar(level: session.audioLevel)
                .frame(height: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(stateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.engineName)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            if !session.statusDetail.isEmpty {
                Text(session.statusDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.finalizedTranscript.isEmpty && session.volatileTranscript.isEmpty {
                        Text(session.state == .recording ? "開始說話後，這裡會即時顯示辨識結果…" : " ")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(session.finalizedTranscript)
                        + Text(session.volatileTranscript.isEmpty ? "" : " " + session.volatileTranscript)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: session.finalizedTranscript) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                if session.state == .recording {
                    Button {
                        session.pause()
                    } label: {
                        Label("暫停", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                } else if session.state == .paused {
                    Button {
                        session.resume()
                    } label: {
                        Label("繼續", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await stopAndSave() }
                } label: {
                    HStack {
                        if isStopping {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(isStopping ? "整理中…" : stopButtonLabel)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isStopping || !(session.state == .recording || session.state == .paused))
            }
        }
    }

    // MARK: - Actions

    private func stopAndSave() async {
        guard !isStopping else { return }
        isStopping = true
        let result = await session.stop()

        var meeting = Meeting(
            title: title,
            startedAt: result.startedAt,
            duration: result.duration,
            audioFileName: result.audioFileName,
            transcript: result.transcript,
            status: .transcribed
        )
        if result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meeting.status = .failed
            meeting.lastError = "沒有辨識到任何語音。錄音檔已保留。"
        }
        store.upsert(meeting)

        // 零成本模式不呼叫 API，改由使用者在會議頁手動複製到 Claude。
        if meeting.status == .transcribed
            && settings.summaryMode == .api
            && settings.autoSummarize
            && settings.hasAPIKey {
            runner.summarize(meetingID: meeting.id, store: store, settings: settings)
        }

        isStopping = false
        dismiss()
        onFinish(meeting.id)
    }

    private func cancelAndClose() {
        session.cancel()
        dismiss()
        onFinish(nil)
    }

    // MARK: - Helpers

    /// 零成本模式或關掉自動摘要時，按下去只會停止錄音，不會產生紀錄，按鈕文字要誠實。
    private var stopButtonLabel: String {
        let willSummarize = settings.summaryMode == .api && settings.autoSummarize && settings.hasAPIKey
        return willSummarize ? "停止並產生紀錄" : "停止錄音"
    }

    private var stateColor: Color {
        switch session.state {
        case .recording: return .red
        case .paused: return .orange
        case .preparing, .stopping: return .gray
        case .idle: return .gray
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle: return "準備中"
        case .preparing: return "啟動麥克風與辨識引擎…"
        case .recording: return "錄音中（可鎖定螢幕，背景會繼續錄）"
        case .paused: return "已暫停"
        case .stopping: return "正在結束…"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// 簡單的音量條（名稱避免與 TranscriptionEngine.swift 的 LevelMeter 類別衝突）。
private struct LevelBar: View {
    let level: Float  // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
