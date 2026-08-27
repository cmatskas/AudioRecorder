import AVFoundation
import Foundation
import SwiftUI

/// Main-actor view model owning the capture engine and recording lifecycle.
@MainActor
public final class AppState: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var devices: [AudioInputDevice] = []
    @Published public var selectedMicUID: String? {
        didSet { if oldValue != selectedMicUID { rebuildEngine() } }
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
    @Published public private(set) var recoveryItems: [RecoveryManager.RecoveryItem] = []
    @Published public private(set) var userDestination: URL?

    // MARK: - Internals

    public let backupRoot: URL
    private var engine: CaptureEngine?
    private var session: RecordingSession?
    private var stopObservingDevices: (() -> Void)?
    private static let destinationDefaultsKey = "userDestinationPath"

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

    private func handleDeviceListChange() {
        guard !isRecording else { return }
        refreshDevices()
        if selectedMicUID == nil || !devices.contains(where: { $0.uid == selectedMicUID }) {
            selectedMicUID = defaultMicUID()
        } else {
            rebuildEngine()
        }
    }

    private func rebuildEngine() {
        guard !isRecording else { return }
        engine?.stop()
        engine = nil
        meterRef = nil

        let config = CaptureEngine.Configuration(
            micDevice: selectedMic,
            captureSystemAudio: systemAudioEnabled
        )
        guard config.micDevice != nil || config.captureSystemAudio else {
            statusMessage = "Select a microphone or enable system audio"
            return
        }
        let newEngine = CaptureEngine()
        do {
            try newEngine.prepare(config)
            try newEngine.start()
            engine = newEngine
            meterRef = newEngine.meters
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
        guard let engine else { return }
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
                    var message = "Saved: \(saved?.path ?? result.sessionDirectory.path)"
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
}
