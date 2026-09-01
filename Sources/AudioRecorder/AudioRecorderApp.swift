import AudioRecorderCore
import AudioRecorderInsights
import SwiftUI

@main
struct AudioRecorderApp: App {
    @StateObject private var state: AppState

    init() {
        let state = AppState()
        // The one seam where the dependency-free recording core meets the
        // AWS-backed insights implementation.
        state.insightsFactory = { configuration, model in
            AWSInsightsPipeline(configuration: configuration, model: model)
        }
        state.insightsValidator = STSCredentialsValidator()
        _state = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup("Audio Recorder") {
            ContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    state.checkForUpdates(force: true)
                }
            }
        }

        Window("Live Insights", id: "insights") {
            // The model is passed explicitly: the panel observes it directly
            // so the transcript refreshes live during a recording.
            InsightsPanelView(insights: state.insightsModel)
                .environmentObject(state)
        }
        .defaultSize(width: 420, height: 640)
        .windowResizability(.contentMinSize)
    }
}
