import Accelerate
import CoreAudio
import Foundation
import os

/// Captures microphone and/or system audio as two **independent** tracks.
///
/// Each source has its own IO path:
///  - Microphone: an IOProc on the mic device itself, which runs continuously.
///  - System audio: a Core Audio process tap (macOS 14.4+) inside a private
///    aggregate device paired with the tapped output device.
///
/// They are deliberately not combined into a single aggregate device. A process
/// tap emits no buffers until some process renders audio, and a tap placed in
/// an aggregate gates that aggregate's entire IO cycle — with the mic in the
/// same aggregate the mic was starved until system audio happened to play.
///
/// Nor are the two streams merged on the real-time thread. Each track is
/// delivered to its own destinations at its own native sample rate, tagged with
/// a host-time anchor (see `CaptureTrack`), and merged offline at finalize.
/// This keeps the sources fully decoupled: a Bluetooth dropout on one cannot
/// disturb the other, and alignment is recomputed from timestamps afterwards
/// rather than guessed at live.
public final class CaptureEngine: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var micDevice: AudioInputDevice?
        public var captureSystemAudio: Bool

        public init(micDevice: AudioInputDevice?, captureSystemAudio: Bool) {
            self.micDevice = micDevice
            self.captureSystemAudio = captureSystemAudio
        }
    }

    /// Max frames per IO cycle we are prepared to handle.
    private static let maxFramesPerCycle = 16384

    public let meters = LevelMeters()

    /// Microphone track, present only while a mic is configured.
    public private(set) var micTrack: CaptureTrack?
    /// System audio track, present only while system capture is configured.
    public private(set) var systemTrack: CaptureTrack?

    public private(set) var configuration: Configuration?
    public private(set) var hasMic = false
    public private(set) var hasSystemAudio = false

    // MARK: Microphone path

    private var micDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var micProcID: AudioDeviceIOProcID?
    private var micStarted = false

    // MARK: System audio path

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapAggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapProcID: AudioDeviceIOProcID?
    private var tapStarted = false

    // MARK: Scratch (preallocated; the IO paths never allocate)

    private var micScratch: UnsafeMutablePointer<Float>?
    private var tapScratch: UnsafeMutablePointer<Float>?

    private let logger = Logger(subsystem: "dev.cmatskas.AudioRecorder", category: "capture")

    public init() {}

    deinit {
        stop()
        teardown()
        micScratch?.deallocate()
        tapScratch?.deallocate()
    }

    /// The highest sample rate among active tracks — the rate a merged
    /// recording will be produced at.
    public var mergedSampleRate: Double {
        max(micTrack?.sampleRate ?? 0, systemTrack?.sampleRate ?? 0)
    }

    public var framesDropped: Int {
        (micTrack?.framesDropped ?? 0) + (systemTrack?.framesDropped ?? 0)
    }

    public var framesGapFilled: Int {
        (micTrack?.framesGapFilled ?? 0) + (systemTrack?.framesGapFilled ?? 0)
    }

    public var micFramesMuted: Int { micTrack?.framesMuted ?? 0 }
    public var systemFramesMuted: Int { systemTrack?.framesMuted ?? 0 }

    /// Replaces a source's audio with silence without disturbing capture.
    /// Unlike changing the source configuration, this is safe mid-recording:
    /// the IO procs, ring buffers, writers and host-time anchors are untouched.
    public func setMuted(_ muted: Bool, forSource label: String) {
        switch label {
        case "mic": micTrack?.setMuted(muted)
        case "system": systemTrack?.setMuted(muted)
        default: break
        }
    }

    // MARK: - Lifecycle

    public func prepare(_ config: Configuration) throws {
        guard config.micDevice != nil || config.captureSystemAudio else {
            throw CoreAudioError.osStatus(-1, "preparing capture: no sources selected")
        }
        stop()
        teardown()

        hasMic = config.micDevice != nil
        hasSystemAudio = config.captureSystemAudio

        // 1. Microphone device, re-resolved by UID (IDs are not stable).
        if let mic = config.micDevice {
            guard let resolved = AudioDeviceList.deviceID(forUID: mic.uid) else {
                throw CoreAudioError.osStatus(-1, "locating microphone '\(mic.name)'")
            }
            micDeviceID = resolved
            let rate = (try? caGetValue(
                resolved,
                kAudioDevicePropertyNominalSampleRate,
                initial: Double(48_000),
                what: "reading microphone sample rate"
            )) ?? 48_000
            micTrack = CaptureTrack(label: "mic", sampleRate: rate)
        }

        // 2. System audio: process tap inside an aggregate paired with the
        //    tapped output device, which drives that aggregate's IO cycle.
        //    The aggregate keeps its own native rate — it is no longer forced
        //    to match the mic, since merging happens offline.
        if config.captureSystemAudio {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "AudioRecorder System Audio Tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(
                AudioHardwareCreateProcessTap(description, &newTapID),
                "creating system audio tap (check System Audio Recording permission)"
            )
            tapID = newTapID

            var aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AudioRecorder System Audio",
                kAudioAggregateDeviceUIDKey: "audio-recorder-capture-\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            if let outputID = AudioDeviceList.defaultOutputDeviceID()
                ?? AudioDeviceList.builtInOutputDeviceID(),
               let outputUID = try? caGetString(
                   outputID, kAudioDevicePropertyDeviceUID, what: "output device UID"
               ) {
                aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
                aggregate[kAudioAggregateDeviceSubDeviceListKey] = [
                    [kAudioSubDeviceUIDKey: outputUID]
                ]
            }

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregateID),
                "creating system audio aggregate device"
            )
            tapAggregateID = newAggregateID

            let rate = (try? caGetValue(
                newAggregateID,
                kAudioDevicePropertyNominalSampleRate,
                initial: Double(48_000),
                what: "reading aggregate sample rate"
            )) ?? 48_000
            systemTrack = CaptureTrack(label: "system", sampleRate: rate)
        }

        micScratch?.deallocate()
        tapScratch?.deallocate()
        micScratch = .allocate(capacity: Self.maxFramesPerCycle * 2)
        tapScratch = .allocate(capacity: Self.maxFramesPerCycle * 2)

        logger.info("prepare: mic=\(config.micDevice?.name ?? "none", privacy: .public) micRate=\(self.micTrack?.sampleRate ?? 0, privacy: .public) tap=\(config.captureSystemAudio, privacy: .public) tapRate=\(self.systemTrack?.sampleRate ?? 0, privacy: .public)")

        configuration = config
    }

    public func start() throws {
        guard configuration != nil else { return }

        if hasMic, micDeviceID != kAudioObjectUnknown, !micStarted {
            var procID: AudioDeviceIOProcID?
            try caCheck(
                AudioDeviceCreateIOProcIDWithBlock(&procID, micDeviceID, nil) {
                    [unowned self] _, inputData, inputTime, _, _ in
                    self.handleMicInput(inputData, inputTime)
                },
                "creating microphone IO proc"
            )
            micProcID = procID
            try caCheck(AudioDeviceStart(micDeviceID, procID), "starting microphone")
            micStarted = true
        }

        if hasSystemAudio, tapAggregateID != kAudioObjectUnknown, !tapStarted {
            var procID: AudioDeviceIOProcID?
            try caCheck(
                AudioDeviceCreateIOProcIDWithBlock(&procID, tapAggregateID, nil) {
                    [unowned self] _, inputData, inputTime, _, _ in
                    self.handleTapInput(inputData, inputTime)
                },
                "creating system audio IO proc"
            )
            tapProcID = procID
            try caCheck(AudioDeviceStart(tapAggregateID, procID), "starting system audio capture")
            tapStarted = true
        }
    }

    public func stop() {
        if micStarted, let procID = micProcID {
            AudioDeviceStop(micDeviceID, procID)
            AudioDeviceDestroyIOProcID(micDeviceID, procID)
        }
        micProcID = nil
        micStarted = false

        if tapStarted, let procID = tapProcID {
            AudioDeviceStop(tapAggregateID, procID)
            AudioDeviceDestroyIOProcID(tapAggregateID, procID)
        }
        tapProcID = nil
        tapStarted = false

        meters.reset()
    }

    private func teardown() {
        if tapAggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(tapAggregateID)
            tapAggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        micDeviceID = AudioObjectID(kAudioObjectUnknown)
        micTrack = nil
        systemTrack = nil
        configuration = nil
    }

    /// Attaches recording destinations per source. Empty arrays detach.
    public func setSinks(mic: [RingBuffer], system: [RingBuffer]) {
        micTrack?.setSinks(mic)
        systemTrack?.setSinks(system)
    }

    // MARK: - Real-time paths

    /// Extracts interleaved stereo from a device's input buffer list. Mono
    /// sources are duplicated; multi-channel sources use the first two channels.
    @inline(__always)
    private func extractStereo(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        into dest: UnsafeMutablePointer<Float>
    ) -> Int {
        var leftBase: UnsafeMutablePointer<Float>?
        var leftStride = 1
        var rightBase: UnsafeMutablePointer<Float>?
        var rightStride = 1
        var frames = 0
        var flatIndex = 0

        for buffer in bufferList {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let raw = buffer.mData else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            guard bufferFrames > 0 else { continue }
            let base = raw.assumingMemoryBound(to: Float.self)
            frames = max(frames, bufferFrames)

            for channel in 0..<channels {
                switch flatIndex {
                case 0:
                    leftBase = base + channel
                    leftStride = channels
                case 1:
                    rightBase = base + channel
                    rightStride = channels
                default:
                    break
                }
                flatIndex += 1
            }
            if flatIndex >= 2 { break }
        }

        guard let leftBase, frames > 0 else { return 0 }
        let frameCount = min(frames, Self.maxFramesPerCycle)
        let right = rightBase ?? leftBase
        let rStride = rightBase == nil ? leftStride : rightStride
        for frame in 0..<frameCount {
            dest[frame * 2] = leftBase[frame * leftStride]
            dest[frame * 2 + 1] = right[frame * rStride]
        }
        return frameCount
    }

    /// Publishes levels for a source. A muted source reads zero: the meter
    /// describes what is being recorded, so showing live levels while silence
    /// is written would misrepresent the recording.
    @inline(__always)
    private func publishMeter(_ data: UnsafePointer<Float>, frames: Int, isMic: Bool) {
        var left: Float = 0
        var right: Float = 0
        let muted = isMic ? (micTrack?.isMuted ?? false) : (systemTrack?.isMuted ?? false)
        if !muted {
            vDSP_rmsqv(data, 2, &left, vDSP_Length(frames))
            vDSP_rmsqv(data + 1, 2, &right, vDSP_Length(frames))
        }
        if isMic {
            meters.setMic(left: left, right: right)
        } else {
            meters.setSystem(left: left, right: right)
        }
    }

    @inline(__always)
    private func hostTime(from timestamp: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let stamp = timestamp.pointee
        if stamp.mFlags.contains(.hostTimeValid) {
            return stamp.mHostTime
        }
        return mach_absolute_time()
    }

    private func handleMicInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        _ inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let micScratch, let micTrack else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frames = extractStereo(from: bufferList, into: micScratch)
        guard frames > 0 else { return }
        publishMeter(micScratch, frames: frames, isMic: true)
        micTrack.append(micScratch, frameCount: frames, hostTime: hostTime(from: inputTime))
    }

    private func handleTapInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        _ inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let tapScratch, let systemTrack else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frames = extractStereo(from: bufferList, into: tapScratch)
        guard frames > 0 else { return }
        publishMeter(tapScratch, frames: frames, isMic: false)
        systemTrack.append(tapScratch, frameCount: frames, hostTime: hostTime(from: inputTime))
    }
}
