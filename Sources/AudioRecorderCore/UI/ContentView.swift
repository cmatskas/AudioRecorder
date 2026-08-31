import SwiftUI

public struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showRecoveryAlert = false
    @State private var tab: Tab = .record

    private enum Tab: Hashable {
        case record
        case history
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            header
            tabPicker
            if tab == .record {
                updateBanner
                sourcesSection
                destinationSection
                insightsSection
                recordSection
                banner
            } else {
                HistoryView()
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(.background)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            showRecoveryAlert = !state.recoveryItems.isEmpty
        }
        .sheet(isPresented: $state.showInsightsSetup) {
            InsightsSetupSheet()
                .environmentObject(state)
        }
        .onChange(of: state.insightsSessionActive) { _, active in
            if active {
                openWindow(id: "insights")
            }
        }
        .alert("Interrupted recording found", isPresented: $showRecoveryAlert) {
            Button("Recover") { state.recoverAll() }
            Button("Discard", role: .destructive) { state.discardRecoveryItems() }
            Button("Later", role: .cancel) {}
        } message: {
            Text(recoveryMessage)
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text("Record").tag(Tab.record)
            Text("History").tag(Tab.history)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
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
            Text("v\(state.appVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Update banner

    @ViewBuilder
    private var updateBanner: some View {
        if let update = state.availableUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(update.version) is available")
                        .font(.callout.weight(.medium))
                    Text("You're running \(state.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { state.openUpdatePage() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Button("Skip") { state.skipUpdate() }
                    .controlSize(.small)
                Button {
                    state.dismissUpdate()
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remind me later")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.12))
            )
            .transition(.move(edge: .top).combined(with: .opacity))
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
                    enabled: state.micEnabled,
                    rate: state.micSampleRate
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
                    enabled: state.systemAudioEnabled,
                    rate: state.systemSampleRate
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
        rate: Double?,
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
            rateBadge(rate: rate, enabled: enabled)
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

    /// Shows the capture rate for a source, flagging anything below CD quality
    /// (typically a Bluetooth microphone) so the limitation is visible here
    /// rather than discovered in the finished file.
    @ViewBuilder
    private func rateBadge(rate: Double?, enabled: Bool) -> some View {
        if enabled, let rate {
            let isLow = rate < 44_100
            HStack(spacing: 4) {
                if isLow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                }
                Text(String(format: "%.1f kHz", rate / 1000))
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(isLow ? .orange : .secondary)
            .help(
                isLow
                    ? "This source is limited to a low sample rate. Recordings follow the highest active source rate."
                    : "Capture sample rate"
            )
        } else {
            Text(" ").font(.caption)
        }
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

    // MARK: - Insights row

    /// One quiet row: the whole surface area of Live Insights for users who
    /// never enable it. The toggle triggers the setup sheet on first use.
    private var insightsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(state.insightsEnabled ? .purple : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Live insights")
                    .font(.callout)
                Text(insightsCaption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if state.insightsSessionActive {
                Button("Show window") { openWindow(id: "insights") }
                    .controlSize(.small)
            }
            if state.insightsConfiguration != nil {
                Button {
                    state.showInsightsSetup = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(state.isRecording)
                .help("Live Insights settings")
            }
            Toggle("", isOn: $state.insightsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(state.isRecording)
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

    private var insightsCaption: String {
        guard state.insightsEnabled, let config = state.insightsConfiguration else {
            return "Transcribe and get follow-up suggestions during recording"
        }
        switch config.credentialSource {
        case let .profile(name):
            return "On · AWS profile “\(name)” · \(config.region)"
        case .keychain:
            return "On · access keys (Keychain) · \(config.region)"
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
                        Text("≈ \(estimatedSizeText) · AAC \(outputRateText)")
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

    /// The rate the finished recording will be rendered at — the highest active
    /// source rate, since nothing is downsampled.
    private var outputRateText: String {
        guard let rate = state.sessionSampleRate else { return "192 kbps" }
        return String(format: "%.1f kHz", rate / 1000)
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
