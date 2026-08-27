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
                let newSession = try RecordingSession(
                    engine: engine,
                    backupRoot: backupRoot,
                    userDestinationRoot: userDestination,
                    micName: selectedMic?.name,
                    systemAudio: systemAudioEnabled
                )
                newSession.start()
                session = newSession
                isRecording = true
                recordingStart = Date()
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
        }
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

    public func revealLastSaved() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
