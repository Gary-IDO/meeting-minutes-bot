import SwiftUI

@main
struct MeetingMinutesBotApp: App {
    @State private var store = MeetingStore()
    @State private var settings = AppSettings()
    @State private var summaryRunner = SummaryRunner()

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(store)
                .environment(settings)
                .environment(summaryRunner)
        }
    }
}
