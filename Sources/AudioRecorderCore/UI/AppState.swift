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
    /// Display name of the last finished recording, shown as an editable field.
    @Published public private(set) var lastSavedName: String?
    /// Session directory of the last finished recording: what a rename acts on.
    @Published public private(set) var lastSavedSessionDirectory: URL?
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

    // MARK: - Naming state

    /// Where the text used to name a recording comes from.
    public enum NamingBackend: String, Codable, Sendable, CaseIterable {
        /// Only a Live Insights transcript, if there happens to be one. Nothing
        /// extra is transcribed and no audio ever leaves the machine.
        case transcriptOnly
        /// Apple's on-device speech recognition over the recording's opening.
        case onDevice
        /// Amazon Transcribe, which means uploading that opening window.
        case amazonTranscribe

        public var label: String {
            switch self {
            case .transcriptOnly: return "Live transcript only"
            case .onDevice: return "On-device"
            case .amazonTranscribe: return "Amazon Transcribe"
            }
        }
    }

    /// Master switch for content-based naming. Recording never depends on it.
    @Published public var autoNameRecordings: Bool {
        didSet {
            UserDefaults.standard.set(autoNameRecordings, forKey: Self.autoNameKey)
        }
    }

    /// Which transcription backend naming may use.
    @Published public var namingBackend: NamingBackend {
        didSet {
            guard oldValue != namingBackend else { return }
            // Uploading audio is never a side effect of a picker: Live Insights
            // being off must not be quietly overridden by naming.
            if namingBackend == .amazonTranscribe && !cloudNamingConsentGranted {
                namingBackend = oldValue
                showCloudNamingConsent = true
                return
            }
            UserDefaults.standard.set(namingBackend.rawValue, forKey: Self.namingBackendKey)
            refreshNamingAvailability()
        }
    }

    /// True while a name is being derived for the recording just saved.
    @Published public private(set) var isNaming = false
    /// True while a rename is being applied.
    @Published public private(set) var isRenaming = false
    /// Set when the selected backend cannot run (no model, permission denied),
    /// so settings can say so instead of naming failing invisibly.
    @Published public private(set) var namingAvailabilityNote: String?
    /// Drives the one-time confirmation before audio may be sent for naming.
    @Published public var showCloudNamingConsent = false

    /// Builds the model client used for titles. Injected by the app target, the
    /// same seam as `insightsFactory`.
    public var llmClientFactory: ((InsightsConfiguration) -> any LLMClient)?
    /// Builds the cloud transcription backend. Injected by the app target.
    public var cloudNamingTranscriberFactory: ((InsightsConfiguration) -> any NamingTranscriber)?

    private var namingTask: Task<Void, Never>?
    private var cloudNamingConsentGranted: Bool
    private static let autoNameKey = "autoNameRecordings"
    private static let namingBackendKey = "namingBackend"
    private static let cloudNamingConsentKey = "namingCloudConsentGranted"
    /// How much of a recording's opening may be transcribed for naming.
    public static let namingTranscriptionWindow: TimeInterval = 180

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
        let defaults = UserDefaults.standard
        // Naming defaults to on, and to the backend that keeps audio local.
        autoNameRecordings = defaults.object(forKey: Self.autoNameKey) as? Bool ?? true
        cloudNamingConsentGranted = defaults.bool(forKey: Self.cloudNamingConsentKey)
        let storedBackend = defaults.string(forKey: Self.namingBackendKey)
            .flatMap(NamingBackend.init(rawValue:)) ?? .onDevice
        // A stored cloud choice is honoured only while consent stands.
        namingBackend = (storedBackend == .amazonTranscribe && !cloudNamingConsentGranted)
            ? .onDevice
            : storedBackend
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
        refreshNamingAvailability()
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
        // Naming the previous recording must never compete with capturing the
        // next one; it is a convenience and loses by design.
        cancelNaming()
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
            var sessionDirectory: URL?
            var audioForNaming: URL?
            do {
                let result = try activeSession.stopAndFinalize()
                sessionDirectory = result.sessionDirectory
                audioForNaming = result.backupM4A ?? result.userM4A
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSaving = false
                    let saved = result.userM4A ?? result.backupM4A
                    self.lastSavedURL = saved
                    self.lastSavedSessionDirectory = result.sessionDirectory
                    self.lastSavedName = saved?.deletingPathExtension().lastPathComponent
                        ?? result.sessionDirectory.lastPathComponent
                    // The file name is its own control now, so the banner is
                    // left for what actually needs saying.
                    if !result.warnings.isEmpty {
                        self.statusMessage = "⚠ " + result.warnings.joined(separator: "\n⚠ ")
                    } else {
                        self.statusMessage = nil
                    }
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
            // Naming comes last: it needs the finished file and, when there was
            // one, the complete transcript.
            if let sessionDirectory {
                await MainActor.run { [weak self] in
                    self?.startNaming(
                        sessionDirectory: sessionDirectory, audioURL: audioForNaming
                    )
                }
            }
        }
    }

    // MARK: - Naming

    /// Derives a content-based name for the recording just saved and applies it.
    /// Every failure path here is silent: the recording keeps its timestamp name.
    private func startNaming(sessionDirectory: URL, audioURL: URL?) {
        guard autoNameRecordings else { return }
        let namer = makeNamer()
        // With no transcriber, no live transcript and no summary there is
        // nothing to read.
        let liveTranscript = TranscriptStore.dialogue(insightsModel.utterances)
        let summary = insightsModel.summary
        guard namer.transcriber != nil || !liveTranscript.isEmpty || !summary.isEmpty else {
            return
        }
        let inputs = RecordingNamer.Inputs(
            audioURL: audioURL,
            liveTranscript: liveTranscript,
            summary: summary
        )
        let destination = userDestination
        isNaming = true
        namingTask = Task { [weak self] in
            let proposed = await namer.proposeName(inputs)
            guard !Task.isCancelled else {
                await MainActor.run { self?.isNaming = false }
                return
            }
            var applied: SessionRenamer.Outcome?
            if let proposed {
                applied = try? SessionRenamer.rename(
                    SessionRenamer.Request(
                        sessionDirectory: sessionDirectory,
                        userDestinationRoot: destination,
                        newName: proposed
                    ),
                    allowSuffix: true,
                    limit: RecordingTitler.maxLength
                )
            }
            await MainActor.run {
                guard let self else { return }
                self.isNaming = false
                guard !Task.isCancelled, let applied else { return }
                self.apply(applied, sessionDirectory: sessionDirectory)
            }
        }
    }

    private func makeNamer() -> RecordingNamer {
        var llm: (any LLMClient)?
        var titleModelID: String?
        if let configuration = insightsConfiguration, let factory = llmClientFactory {
            llm = factory(configuration)
            // The deep model, not the fast one. Naming is one short call per
            // recording, and the difference in quality is stark: asked to name a
            // talk about childhood labels, nova-lite answers "Impact of
            // Childhood Labels" (26 characters) while Claude answers "Broken
            // Brain". A cheap model is the right call for the live suggestion
            // lane, which runs every few seconds; it is the wrong one here.
            titleModelID = configuration.deepModelID.isEmpty
                ? configuration.fastModelID
                : configuration.deepModelID
        }
        return RecordingNamer(
            transcriber: makeNamingTranscriber(),
            llm: llm,
            titleModelID: titleModelID,
            maxTranscriptionDuration: Self.namingTranscriptionWindow
        )
    }

    private func makeNamingTranscriber() -> (any NamingTranscriber)? {
        switch namingBackend {
        case .transcriptOnly:
            return nil
        case .onDevice:
            return LocalSpeechTranscriber()
        case .amazonTranscribe:
            guard cloudNamingConsentGranted,
                  let configuration = insightsConfiguration,
                  let factory = cloudNamingTranscriberFactory
            else { return nil }
            return factory(configuration)
        }
    }

    private func cancelNaming() {
        namingTask?.cancel()
        namingTask = nil
        isNaming = false
    }

    /// Checks whether the selected backend can actually run, so the settings row
    /// can explain a denial or a missing model rather than staying silent.
    public func refreshNamingAvailability() {
        guard namingBackend == .onDevice else {
            namingAvailabilityNote = nil
            return
        }
        Task { [weak self] in
            let result = await LocalSpeechTranscriber.availability()
            await MainActor.run {
                guard let self, self.namingBackend == .onDevice else { return }
                switch result {
                case .success:
                    self.namingAvailabilityNote = nil
                case let .failure(error):
                    self.namingAvailabilityNote = error.localizedDescription
                }
            }
        }
    }

    /// Records consent to send a window of audio to Amazon Transcribe, and
    /// switches to that backend. Revocable by switching away.
    public func grantCloudNamingConsent() {
        cloudNamingConsentGranted = true
        UserDefaults.standard.set(true, forKey: Self.cloudNamingConsentKey)
        showCloudNamingConsent = false
        namingBackend = .amazonTranscribe
    }

    public func declineCloudNamingConsent() {
        showCloudNamingConsent = false
    }

    // MARK: - Renaming

    /// Applies a hand-typed name to the recording shown at the bottom of the
    /// Record tab. Reports failures, unlike automatic naming.
    public func renameLastRecording(to newName: String) {
        guard !isRecording, !isSaving, !isRenaming,
              let sessionDirectory = lastSavedSessionDirectory
        else { return }
        // A typed name wins over one still being generated.
        cancelNaming()
        rename(sessionDirectory: sessionDirectory, to: newName) { [weak self] outcome in
            guard let self, let outcome else { return }
            self.apply(outcome, sessionDirectory: sessionDirectory)
        }
    }

    /// Renames a past recording from the History tab. `completion` reports
    /// success so the list can refresh.
    public func rename(
        _ item: HistoryItem,
        to newName: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isRecording, !isSaving, !isRenaming else {
            completion?(false)
            return
        }
        rename(sessionDirectory: item.directory, to: newName) { [weak self] outcome in
            if let self, let outcome, self.isLastSaved(item.directory) {
                self.apply(outcome, sessionDirectory: item.directory)
            }
            completion?(outcome != nil)
        }
    }

    private func rename(
        sessionDirectory: URL,
        to newName: String,
        then handler: @escaping @MainActor (SessionRenamer.Outcome?) -> Void
    ) {
        let request = SessionRenamer.Request(
            sessionDirectory: sessionDirectory,
            userDestinationRoot: userDestination,
            newName: newName
        )
        isRenaming = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try SessionRenamer.rename(request, allowSuffix: false) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRenaming = false
                switch result {
                case let .success(outcome):
                    if outcome.warnings.isEmpty {
                        self.statusMessage = nil
                    } else {
                        self.statusMessage = "⚠ " + outcome.warnings.joined(separator: "\n⚠ ")
                    }
                    handler(outcome)
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                    handler(nil)
                }
            }
        }
    }

    /// Reflects a completed rename in the UI.
    private func apply(_ outcome: SessionRenamer.Outcome, sessionDirectory: URL) {
        guard isLastSaved(sessionDirectory) else { return }
        lastSavedName = outcome.name
        // Prefer the copy in the user's folder, as the save banner does.
        lastSavedURL = outcome.userAudioURL ?? outcome.backupAudioURL ?? lastSavedURL
    }

    /// Path comparison, not URL equality: the same directory arrives with and
    /// without a trailing slash depending on whether it came from a session or
    /// from a directory scan.
    private func isLastSaved(_ directory: URL) -> Bool {
        guard let current = lastSavedSessionDirectory else { return false }
        return current.standardizedFileURL.path == directory.standardizedFileURL.path
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
