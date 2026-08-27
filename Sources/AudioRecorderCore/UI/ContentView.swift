import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showRecoveryAlert = false

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            header
            sourcesSection
            destinationSection
            recordSection
            banner
        }
        .padding(20)
        .frame(width: 520)
        .background(.background)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            showRecoveryAlert = !state.recoveryItems.isEmpty
        }
        .alert("Interrupted recording found", isPresented: $showRecoveryAlert) {
            Button("Recover") { state.recoverAll() }
            Button("Discard", role: .destructive) { state.discardRecoveryItems() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(recoveryMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Recorder")
                    .font(.title2.bold())
                Text("Microphone and system audio, crash-safe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let levels = state.meterSnapshot()
            HStack(spacing: 12) {
                sourceCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    isOn: $state.micEnabled,
                    levels: levels.mic,
                    enabled: state.micEnabled
                ) {
                    Picker("Microphone", selection: $state.selectedMicUID) {
                        ForEach(state.devices) { device in
                            Text(device.displayName).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .disabled(state.isRecording || !state.micEnabled)
                }
                sourceCard(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    isOn: $state.systemAudioEnabled,
                    levels: levels.system,
                    enabled: state.systemAudioEnabled
                ) {
                    Text("Everything your Mac plays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 3)
                }
            }
        }
    }

    private func sourceCard<Content: View>(
        icon: String,
        title: String,
        isOn: Binding<Bool>,
        levels: (Float, Float),
        enabled: Bool,
        @ViewBuilder detail: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(state.isRecording)
            }
            detail()
            StereoVUMeter(title: title, left: levels.0, right: levels.1, enabled: enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    // MARK: - Destinations

    private var destinationSection: some View {
        VStack(spacing: 8) {
            destinationRow(
                icon: "folder.fill",
                label: "Save to",
                path: state.userDestination?.path ?? "Backup folder only",
                pathURL: state.userDestination
            ) {
                Button("Choose…") { state.chooseDestination() }
                    .controlSize(.small)
                    .disabled(state.isRecording)
            }
            destinationRow(
                icon: "externaldrive.fill",
                label: "Backup",
                path: state.backupRoot.path,
                pathURL: state.backupRoot
            ) {
                Button("Show") { state.openBackupFolder() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func destinationRow<Trailing: View>(
        icon: String,
        label: String,
        path: String,
        pathURL: URL?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .frame(width: 60, alignment: .leading)
            Group {
                if let url = pathURL {
                    Button(path) { state.revealInFinder(url) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                } else {
                    Text(path).foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
            trailing()
        }
    }

    // MARK: - Record control

    private var recordSection: some View {
        HStack(spacing: 20) {
            recordButton
            VStack(alignment: .leading, spacing: 2) {
                if state.isRecording {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(elapsedText)
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                        Text("≈ \(estimatedSizeText) · AAC 192 kbps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if state.isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Ready")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("⌘R to start recording")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var recordButton: some View {
        Button(action: state.toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 3)
                    .frame(width: 64, height: 64)
                if state.isRecording {
                    // Pulsing ring while recording.
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 3)
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulse ? 1.25 : 1.0)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 26, height: 26)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 48, height: 48)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(state.isSaving)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(state.isRecording ? "Stop recording" : "Start recording")
        .onAppear { pulse = true }
    }

    @State private var pulse = false

    private var elapsedText: String {
        guard let start = state.recordingStart else { return "00:00" }
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var estimatedSizeText: String {
        guard let start = state.recordingStart else { return "0 MB" }
        let seconds = Date().timeIntervalSince(start)
        let bytes = seconds * 24_000  // 192 kbps AAC
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Banner

    @ViewBuilder
    private var banner: some View {
        if let error = state.errorMessage {
            bannerView(text: error, icon: "xmark.octagon.fill", color: .red) {
                state.errorMessage = nil
            }
        } else if let status = state.statusMessage {
            let isWarning = status.contains("⚠")
            bannerView(
                text: status,
                icon: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                color: isWarning ? .yellow : .green,
                extraButton: state.lastSavedURL != nil && !isWarning
                    ? ("Show in Finder", { state.revealLastSaved() })
                    : nil
            ) {
                state.statusMessage = nil
            }
        }
    }

    private func bannerView(
        text: String,
        icon: String,
        color: Color,
        extraButton: (String, () -> Void)? = nil,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let (label, action) = extraButton {
                Button(label, action: action)
                    .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.12))
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Recovery

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
}
