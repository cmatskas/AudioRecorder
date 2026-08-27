import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showRecoveryAlert = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            sourcesSection
            destinationSection
            Divider()
            recordSection
            statusSection
        }
        .padding(24)
        .frame(minWidth: 460)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            showRecoveryAlert = !state.recoveryItems.isEmpty
        }
        .alert(
            "Interrupted recording found",
            isPresented: $showRecoveryAlert
        ) {
            Button("Recover") { state.recoverAll() }
            Button("Discard", role: .destructive) { state.discardRecoveryItems() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(recoveryMessage)
        }
    }

    private var recoveryMessage: String {
        let items = state.recoveryItems
        guard !items.isEmpty else { return "" }
        let details = items
            .map { item in
                let minutes = Int(item.estimatedDuration / 60)
                return "\(item.manifest.name) (~\(minutes) min)"
            }
            .joined(separator: ", ")
        return "A previous recording did not finish cleanly: \(details). All captured audio is intact and can be recovered."
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let levels = state.meterSnapshot()
            HStack(alignment: .top, spacing: 32) {
                VStack(spacing: 10) {
                    Toggle("Microphone", isOn: $state.micEnabled)
                        .toggleStyle(.switch)
                        .disabled(state.isRecording)
                    Picker("Microphone", selection: $state.selectedMicUID) {
                        ForEach(state.devices) { device in
                            Text(device.displayName).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .disabled(state.isRecording || !state.micEnabled)
                    StereoVUMeter(
                        title: "Microphone",
                        left: levels.mic.0,
                        right: levels.mic.1,
                        enabled: state.micEnabled
                    )
                }
                VStack(spacing: 10) {
                    Toggle("System Audio", isOn: $state.systemAudioEnabled)
                        .toggleStyle(.switch)
                        .disabled(state.isRecording)
                    Text("Everything your Mac plays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    StereoVUMeter(
                        title: "System audio",
                        left: levels.system.0,
                        right: levels.system.1,
                        enabled: state.systemAudioEnabled
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Save to:")
                Text(state.userDestination?.path ?? "Not set (backup folder only)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { state.chooseDestination() }
                    .disabled(state.isRecording)
            }
            HStack {
                Text("Backup:")
                Text(state.backupRoot.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show") { state.openBackupFolder() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Record control

    private var recordSection: some View {
        HStack(spacing: 16) {
            if state.isRecording {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Label(elapsedText, systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3.monospacedDigit())
                        .symbolEffect(.pulse)
                }
            }
            Spacer()
            if state.isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .foregroundStyle(.secondary)
            } else {
                Button(action: state.toggleRecording) {
                    Text(state.isRecording ? "Stop Recording" : "Start Recording")
                        .frame(minWidth: 140)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.isRecording ? .red : .green)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var elapsedText: String {
        guard let start = state.recordingStart else { return "00:00" }
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if let error = state.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else if let status = state.statusMessage {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
