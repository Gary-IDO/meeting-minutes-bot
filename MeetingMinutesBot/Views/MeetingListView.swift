import SwiftUI

struct MeetingListView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryRunner.self) private var runner

    @State private var path: [UUID] = []
    @State private var showRecorder = false
    @State private var showSettings = false
    /// 錄音結束後要推入的會議 id；等 fullScreenCover 完全關閉再導頁，避免導頁被吃掉。
    @State private var pendingMeetingID: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.meetings.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("會議紀錄")
            .navigationDestination(for: UUID.self) { id in
                MeetingDetailView(meetingID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                recordButton
            }
            .fullScreenCover(isPresented: $showRecorder, onDismiss: {
                if let id = pendingMeetingID {
                    pendingMeetingID = nil
                    path = [id]
                }
            }) {
                RecordingView { newMeetingID in
                    pendingMeetingID = newMeetingID
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var list: some View {
        List {
            if settings.needsAPIKey && !settings.hasAPIKey {
                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label("尚未設定 Claude API 金鑰，點此設定（或改用零成本模式）", systemImage: "key.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                ForEach(store.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        MeetingRow(meeting: meeting, isSummarizing: runner.isRunning(meeting.id))
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.meetings[$0] }.forEach { meeting in
                        runner.cancel(meetingID: meeting.id)
                        store.delete(meeting)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("還沒有任何會議", systemImage: "waveform.badge.mic")
        } description: {
            // 說明文字要符合實際行為：只有 API 模式且開了自動摘要、也有金鑰時才會自動產生。
            if settings.needsAPIKey {
                Text(settings.autoSummarize && settings.hasAPIKey
                     ? "按下方「開始錄音」，結束後會自動整理成會議紀錄。"
                     : "按下方「開始錄音」，結束後到會議頁按「產生會議紀錄」。")
            } else {
                Text("按下方「開始錄音」，結束後在會議頁把逐字稿複製到 Claude 整理，再把結果貼回來。")
            }
        } actions: {
            if settings.needsAPIKey && !settings.hasAPIKey {
                Button("先設定 Claude API 金鑰") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var recordButton: some View {
        Button {
            showRecorder = true
        } label: {
            Label("開始錄音", systemImage: "record.circle.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let isSummarizing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                Text("·")
                Text(meeting.durationText)
                Spacer()
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isSummarizing || meeting.status == .summarizing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("摘要中")
            }
        } else {
            Text(meeting.status.label)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeColor.opacity(0.15), in: Capsule())
                .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        switch meeting.status {
        case .summarized: return .green
        case .failed: return .red
        case .recording: return .orange
        default: return .secondary
        }
    }
}
