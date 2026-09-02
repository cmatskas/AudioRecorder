import AVFoundation
import Foundation
import SwiftUI

/// Main-actor view model owning the capture engine and recording lifecycle.
@MainActor
public final class AppState: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var devices: [AudioInputDevice] = []
    @Published public var selectedMicUID: String? {
        didSet { if oldValue != selectedMicUID && !isInitializing { rebuildEngine() } }
    }
    @Published public var micEnabled = true {
        didSet { if oldValue != micEnabled { rebuildEngine() } }
    }
    @Published public var systemAudioEnabled = true {
        didSet { if oldValue != systemAudioEnabled { rebuildEngine() } }
    }
    @Published public private(set) var isRecording = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var recordingStart: Date?
    @Published public var statusMessage: String?
    @Published public var errorMessage: String?
    @Published public private(set) var lastSavedURL: URL?
    @Published public private(set) var recoveryItems: [RecoveryManager.RecoveryItem] = []
    @Published public private(set) var userDestination: URL?
    /// Sample rate of the microphone track, if active.
    @Published public private(set) var micSampleRate: Double?
    /// Sample rate of the system audio track, if active.
    @Published public private(set) var systemSampleRate: Double?
    /// A newer release found on GitHub, if any.
    @Published public private(set) var availableUpdate: UpdateChecker.Update?

    // MARK: - Insights state

    /// Live data rendered by the insights window.
    public let insightsModel = InsightsModel()
    /// Master switch for live insights; recording never depends on it.
    @Published public var insightsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(insightsEnabled, forKey: Self.insightsEnabledKey)
            if insightsEnabled && insightsConfiguration == nil {
                // First enable: credentials/region must be set up before the
                // toggle can take effect.
                insightsEnabled = false
                showInsightsSetup = true
            }
        }
    }
    @Published public var insightsConfiguration: InsightsConfiguration?
    /// Presents the setup sheet (first enable, or explicit reconfigure).
    @Published public var showInsightsSetup = false
    /// True while an insights pipeline is attached to the current recording;
    /// drives opening of the insights window.
    @Published public private(set) var insightsSessionActive = false
    @Published public private(set) var insightsPaused = false

    /// Injected by the app target — the only place Core meets the AWS
    /// implementation. When nil, the insights UI is inert.
    public var insightsFactory: InsightsPipelineFactory?
    public var insightsValidator: (any InsightsCredentialsValidating)?

    private var insightsPipeline: InsightsPipeline?
    private static let insightsEnabledKey = "insightsEnabled"

    private let updateChecker = UpdateChecker()

    /// Version of the running app, for display.
    public var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The rate a finished recording will be rendered at (the higher of the
    /// active sources, since nothing is downsampled).
    public var sessionSampleRate: Double? {
        let rates = [micSampleRate, systemSampleRate].compactMap { $0 }
        return rates.max()
    }

    /// Set when a source is limited to a low rate (typically a Bluetooth mic),
    /// so the UI can say so rather than letting it be discovered in the file.
    public var lowRateWarning: String? {
        guard let micRate = micSampleRate, micRate < 44_100 else { return nil }
        let name = selectedMic?.name ?? "Microphone"
        return String(
            format: "%@ is limited to %.0f kHz", name, micRate / 1000
        )
    }

    // MARK: - Internals

    public let backupRoot: URL
    private var engine: CaptureEngine?
    private var session: RecordingSession?
    private var stopObservingDevices: (() -> Void)?
    private static let destinationDefaultsKey = "userDestinationPath"
    /// Serial queue for all engine construction/teardown: tap and aggregate
    /// device creation are slow, synchronous Core Audio calls (and the first
    /// tap creation can block on the permission prompt), so they must never
    /// run on the main thread.
    private let engineQueue = DispatchQueue(label: "AudioRecorder.engine", qos: .userInitiated)
    /// Invalidates in-flight engine builds when configuration changes again.
    private var engineGeneration = 0
    private var pendingDeviceRefresh: DispatchWorkItem?
    /// Suppresses engine rebuilds triggered by property observers during init,
    /// so startup builds the capture engine exactly once.
    private var isInitializing = true

    public init() {
        insightsConfiguration = InsightsConfiguration.load()
        insightsEnabled = UserDefaults.standard.bool(forKey: Self.insightsEnabledKey)
        backupRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("AudioRecorderBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        if let path = UserDefaults.standard.string(forKey: Self.destinationDefaultsKey) {
            userDestination = URL(fileURLWithPath: path, isDirectory: true)
        }

        refreshDevices()
        selectedMicUID = defaultMicUID()
        stopObservingDevices = AudioDeviceList.observeDeviceListChanges { [weak self] in
            self?.handleDeviceListChange()
        }
        recoveryItems = RecoveryManager.scan(root: backupRoot)
        isInitializing = false
        rebuildEngine()
        checkForUpdates()
    }

    deinit {
        stopObservingDevices?()
    }

    public var selectedMic: AudioInputDevice? {
        guard micEnabled, let uid = selectedMicUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// Snapshot of current meter levels; safe to call from any thread at UI rate.
    public nonisolated func meterSnapshot() -> (mic: (Float, Float), system: (Float, Float)) {
        guard let meters = meterRef else { return ((0, 0), (0, 0)) }
        return (meters.mic, meters.system)
    }

    /// Meters reference readable off the main actor.
    private nonisolated(unsafe) var meterRef: LevelMeters?

    // MARK: - Devices / engine

    private func defaultMicUID() -> String? {
        if let defaultID = AudioDeviceList.defaultInputDeviceID(),
           let device = devices.first(where: { $0.id == defaultID }) {
            return device.uid
        }
        return devices.first?.uid
    }

    private func refreshDevices() {
        devices = AudioDeviceList.inputDevices()
    }

    /// Device-list notifications are debounced and compared against the
    /// current list. This is essential: creating or destroying our own tap
    /// and aggregate device fires this notification, and reacting to our own
    /// churn would rebuild the engine in an infinite loop.
    private func handleDeviceListChange() {
        guard !isRecording else { return }
        pendingDeviceRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyDeviceListChange()
        }
        pendingDeviceRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func applyDeviceListChange() {
        guard !isRecording else { return }
        let newDevices = AudioDeviceList.inputDevices()
        // Our private aggregates are filtered out of the enumeration, so a
        // notification caused by our own engine rebuild produces an unchanged
        // list and is ignored here — breaking the feedback loop.
        guard newDevices != devices else { return }
        devices = newDevices
        if selectedMicUID == nil || !devices.contains(where: { $0.uid == selectedMicUID }) {
            selectedMicUID = defaultMicUID()  // didSet triggers rebuild
        } else {
            rebuildEngine()
        }
    }

    private func rebuildEngine() {
        guard !isRecording else { return }
        engineGeneration += 1
        let generation = engineGeneration

        // Release the current engine off-main; its teardown is also slow.
        let oldEngine = engine
        engine = nil
        meterRef = nil
        micSampleRate = nil
        systemSampleRate = nil

        let config = CaptureEngine.Configuration(
            micDevice: selectedMic,
            captureSystemAudio: systemAudioEnabled
        )
        guard config.micDevice != nil || config.captureSystemAudio else {
            engineQueue.async { oldEngine?.stop() }
            statusMessage = "Select a microphone or enable system audio"
            return
        }

        engineQueue.async { [weak self] in
            oldEngine?.stop()
            // oldEngine is released here, so its aggregate/tap teardown
            // happens on this queue, not on the main thread.

            let newEngine = CaptureEngine()
            do {
                try newEngine.prepare(config)
                try newEngine.start()
                Task { @MainActor [weak self] in
                    guard let self, self.engineGeneration == generation else {
                        // Configuration changed while building; discard.
                        self?.engineQueue.async { newEngine.stop() }
                        return
                    }
                    self.engine = newEngine
                    self.meterRef = newEngine.meters
                    self.micSampleRate = newEngine.micTrack?.sampleRate
                    self.systemSampleRate = newEngine.systemTrack?.sampleRate
                    self.statusMessage = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.engineGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Destination

    public func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where recordings should be saved"
        if panel.runModal() == .OK, let url = panel.url {
            userDestination = url
            UserDefaults.standard.set(url.path, forKey: Self.destinationDefaultsKey)
        }
    }

    // MARK: - Recording

    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let engine else {
            statusMessage = "Audio engine is still starting — try again in a moment"
            return
        }
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            if selectedMic != nil {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
                    return
                }
            }
            do {
                // Optional live-insights tap: prepared before the session so
                // its rings ride along with the recording sinks. Any failure
                // here disables insights for this recording, never recording.
                var extraSinks = RecordingSession.ExtraSinks()
                var pipeline: InsightsPipeline?
                if insightsEnabled, let config = insightsConfiguration,
                   let factory = insightsFactory {
                    let candidate = factory(config, insightsModel)
                    extraSinks = candidate.makeExtraSinks(
                        micRate: engine.micTrack?.sampleRate,
                        systemRate: engine.systemTrack?.sampleRate
                    )
                    pipeline = candidate
                }

                let newSession = try RecordingSession(
                    engine: engine,
                    backupRoot: backupRoot,
                    userDestinationRoot: userDestination,
                    micName: selectedMic?.name,
                    extraSinks: extraSinks
                )
                newSession.start()
                session = newSession
                isRecording = true
                recordingStart = Date()

                if let pipeline {
                    pipeline.start(
                        destinations: TranscriptDestinations(
                            sessionName: newSession.sessionName,
                            liveDirectory: newSession.backupSessionDirectory,
                            exportRoots: [userDestination].compactMap { $0 }
                        )
                    )
                    insightsPipeline = pipeline
                    insightsPaused = false
                    insightsSessionActive = true
                }
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    private func stopRecording() {
        guard let activeSession = session else { return }
        session = nil
        isRecording = false
        recordingStart = nil
        isSaving = true
        let pipeline = insightsPipeline
        insightsPipeline = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try activeSession.stopAndFinalize()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSaving = false
                    let saved = result.userM4A ?? result.backupM4A
                    self.lastSavedURL = saved
                    var message = "Saved \(saved?.lastPathComponent ?? result.sessionDirectory.lastPathComponent)"
                    if !result.warnings.isEmpty {
                        message += "\n⚠ " + result.warnings.joined(separator: "\n⚠ ")
                    }
                    self.statusMessage = message
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isSaving = false
                    self?.errorMessage = "Finalize failed: \(error.localizedDescription). PCM masters are preserved in the backup folder."
                }
            }
            // Wind down insights after the audio is safe: drains remaining
            // analysis audio, runs a final deep pass, flushes transcript and
            // insights JSON into the session directory.
            if let pipeline {
                await pipeline.finish()
                await MainActor.run { [weak self] in
                    self?.insightsSessionActive = false
                }
            }
        }
    }

    // MARK: - Insights

    /// Pause/resume streaming audio to AWS mid-recording (off the record).
    public func toggleInsightsPaused() {
        guard let pipeline = insightsPipeline else { return }
        insightsPaused.toggle()
        pipeline.setPaused(insightsPaused)
    }

    /// Called by the setup sheet when configuration is saved: persists it and
    /// flips the master switch on.
    public func applyInsightsConfiguration(_ configuration: InsightsConfiguration) {
        insightsConfiguration = configuration
        configuration.save()
        showInsightsSetup = false
        if !insightsEnabled {
            insightsEnabled = true
        }
    }

    /// Forgets configuration and stored keys, and disables insights.
    public func resetInsightsConfiguration() {
        insightsEnabled = false
        insightsConfiguration = nil
        InsightsConfiguration.clear()
        InsightsKeychain().delete()
    }

    // MARK: - Recovery

    public func recoverAll() {
        let items = recoveryItems
        recoveryItems = []
        Task.detached {
            var recovered: [String] = []
            var failures: [String] = []
            for item in items {
                do {
                    let url = try RecoveryManager.recover(item)
                    recovered.append(url.lastPathComponent)
                } catch {
                    failures.append("\(item.manifest.name): \(error.localizedDescription)")
                }
            }
            let recoveredNames = recovered
            let failureNames = failures
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !recoveredNames.isEmpty {
                    self.statusMessage = "Recovered: \(recoveredNames.joined(separator: ", ")) (in \(self.backupRoot.path))"
                }
                if !failureNames.isEmpty {
                    self.errorMessage = "Recovery failed for \(failureNames.joined(separator: "; "))"
                }
            }
        }
    }

    public func discardRecoveryItems() {
        for item in recoveryItems {
            try? RecoveryManager.discard(item)
        }
        recoveryItems = []
    }

    public func openBackupFolder() {
        NSWorkspace.shared.open(backupRoot)
    }

    // MARK: - Updates

    /// Checks for a newer release. Silent on failure for the automatic check —
    /// a missing network is not something to interrupt a recording session for.
    public func checkForUpdates(force: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await self.updateChecker.check(force: force)
                await MainActor.run {
                    if let update {
                        self.availableUpdate = update
                    } else if force {
                        self.statusMessage = "You're running the latest version (\(self.appVersion))"
                    }
                }
            } catch {
                if force {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    public func openUpdatePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.releaseURL)
    }

    public func skipUpdate() {
        guard let update = availableUpdate else { return }
        updateChecker.skip(update)
        availableUpdate = nil
    }

    public func dismissUpdate() {
        availableUpdate = nil
    }

    public func revealLastSaved() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
