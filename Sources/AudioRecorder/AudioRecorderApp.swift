import AudioRecorderCore
import SwiftUI

@main
struct AudioRecorderApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Audio Recorder") {
            ContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}
