import Accelerate
import CoreAudio
import Foundation
import os
import Synchronization

/// Captures microphone and/or system audio.
///
/// The two sources are captured by **independent** IO paths and merged in
/// software:
///
///  - Microphone: an IOProc on the mic device itself, which runs continuously.
///  - System audio: a Core Audio process tap (macOS 14.4+) inside a private
///    aggregate device paired with the tapped output device.
///
/// They are deliberately *not* combined into a single aggregate device. A
/// process tap emits no buffers until some process renders audio, and a tap
/// placed in an aggregate gates that aggregate's entire IO cycle — with the
/// mic in the same aggregate, the mic was starved until system audio happened
/// to play (verified: no IO callbacks at all while the tap was idle, across
/// several aggregate configurations). Independent paths make the microphone
/// completely unaffected by system-audio activity.
///
/// The microphone path is the timeline master when present: its callback
/// assembles output frames and pulls whatever system audio has arrived,
/// zero-filling when the tap is idle. Output is interleaved Float32:
///   - mic + system: [micL, micR, sysL, sysR]
///   - single source: [L, R]
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

    public private(set) var configuration: Configuration?
    public private(set) var sampleRate: Double = 48_000
    /// Interleaved output channel count (2 or 4).
    public private(set) var outputChannels: Int = 0
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

    /// System audio handed from the tap path to the mic (master) path.
    private var tapRing: RingBuffer?

    // MARK: Scratch buffers (preallocated; the IO paths never allocate)

    /// Interleaved output frames assembled by the master path.
    private var outputScratch: UnsafeMutablePointer<Float>?
    /// Stereo extraction buffer for the mic path.
    private var micScratch: UnsafeMutablePointer<Float>?
    /// Stereo extraction buffer for the tap path.
    private var tapScratch: UnsafeMutablePointer<Float>?

    /// Destinations for captured audio while recording. Guarded by `sinksLock`.
    private var sinks: [RingBuffer] = []
    private let sinksLock: UnsafeMutablePointer<os_unfair_lock_s>

    private let droppedFrames = Atomic<Int>(0)
    private let logger = Logger(subsystem: "dev.cmatskas.AudioRecorder", category: "capture")
    private let micCallbacks = Atomic<Int>(0)
    private let tapCallbacks = Atomic<Int>(0)

    public init() {
        sinksLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        sinksLock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        stop()
        teardown()
        outputScratch?.deallocate()
        micScratch?.deallocate()
        tapScratch?.deallocate()
        sinksLock.deallocate()
    }

    public var framesDropped: Int { droppedFrames.load(ordering: .relaxed) }

    /// IO callback counts, useful for diagnosing a stalled capture path
    /// without logging from the real-time threads.
    public var callbackCounts: (mic: Int, systemAudio: Int) {
        (micCallbacks.load(ordering: .relaxed), tapCallbacks.load(ordering: .relaxed))
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
            sampleRate = (try? caGetValue(
                resolved,
                kAudioDevicePropertyNominalSampleRate,
                initial: Double(48_000),
                what: "reading microphone sample rate"
            )) ?? 48_000
        }

        // 2. System audio: process tap inside an aggregate paired with the
        //    tapped output device (which drives that aggregate's IO cycle).
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

            if config.micDevice == nil {
                // No mic: the tap path defines the session rate.
                sampleRate = (try? caGetValue(
                    newAggregateID,
                    kAudioDevicePropertyNominalSampleRate,
                    initial: Double(48_000),
                    what: "reading aggregate sample rate"
                )) ?? 48_000
            } else {
                // Align the tap aggregate to the mic clock rate so merged
                // frames share a timebase; the tap is drift-compensated and
                // resampled onto it.
                var rate = sampleRate
                var address = caAddress(kAudioDevicePropertyNominalSampleRate)
                let status = AudioObjectSetPropertyData(
                    newAggregateID, &address, 0, nil,
                    UInt32(MemoryLayout<Double>.size), &rate
                )
                if status != noErr {
                    logger.warning("could not align tap aggregate to \(rate, privacy: .public) Hz (status \(status, privacy: .public))")
                }
            }
        }

        outputChannels = (hasMic ? 2 : 0) + (hasSystemAudio ? 2 : 0)

        // 3. Preallocate scratch and the cross-path handoff ring (2 seconds).
        outputScratch?.deallocate()
        micScratch?.deallocate()
        tapScratch?.deallocate()
        outputScratch = .allocate(capacity: Self.maxFramesPerCycle * outputChannels)
        micScratch = .allocate(capacity: Self.maxFramesPerCycle * 2)
        tapScratch = .allocate(capacity: Self.maxFramesPerCycle * 2)
        tapRing = (hasMic && hasSystemAudio)
            ? RingBuffer(capacityFloats: Int(sampleRate * 2) * 2)
            : nil

        micCallbacks.store(0, ordering: .relaxed)
        tapCallbacks.store(0, ordering: .relaxed)
        logger.info("prepare: mic=\(config.micDevice?.name ?? "none", privacy: .public) tap=\(config.captureSystemAudio, privacy: .public) outputChannels=\(self.outputChannels, privacy: .public) rate=\(self.sampleRate, privacy: .public)")

        configuration = config
    }

    public func start() throws {
        guard configuration != nil else { return }

        if hasMic, micDeviceID != kAudioObjectUnknown, !micStarted {
            var procID: AudioDeviceIOProcID?
            try caCheck(
                AudioDeviceCreateIOProcIDWithBlock(&procID, micDeviceID, nil) {
                    [unowned self] _, inputData, _, _, _ in
                    self.handleMicInput(inputData)
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
                    [unowned self] _, inputData, _, _, _ in
                    self.handleTapInput(inputData)
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
        configuration = nil
        outputChannels = 0
        tapRing = nil
    }

    // MARK: - Sinks

    /// Attach ring buffers that should receive captured audio (recording on).
    public func setSinks(_ newSinks: [RingBuffer]) {
        os_unfair_lock_lock(sinksLock)
        sinks = newSinks
        os_unfair_lock_unlock(sinksLock)
        if !newSinks.isEmpty {
            droppedFrames.store(0, ordering: .relaxed)
        }
    }

    // MARK: - Real-time paths

    /// Extracts interleaved stereo from a device's input buffer list.
    /// Mono sources are duplicated; multi-channel sources use the first two
    /// channels. Returns the frame count written to `dest`.
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

    @inline(__always)
    private func publishMeter(_ data: UnsafePointer<Float>, frames: Int, isMic: Bool) {
        var left: Float = 0
        var right: Float = 0
        vDSP_rmsqv(data, 2, &left, vDSP_Length(frames))
        vDSP_rmsqv(data + 1, 2, &right, vDSP_Length(frames))
        if isMic {
            meters.setMic(left: left, right: right)
        } else {
            meters.setSystem(left: left, right: right)
        }
    }

    /// Microphone IOProc. Master path when a mic is present: assembles output
    /// frames and merges whatever system audio has arrived.
    private func handleMicInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let micScratch, let outputScratch else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frames = extractStereo(from: bufferList, into: micScratch)
        guard frames > 0 else { return }

        // Counters only: os_log is not real-time safe, so the IO paths never log.
        _ = micCallbacks.wrappingAdd(1, ordering: .relaxed)
        publishMeter(micScratch, frames: frames, isMic: true)

        let channelCount = outputChannels
        if channelCount == 2 {
            // Mic only.
            memcpy(outputScratch, micScratch, frames * 2 * MemoryLayout<Float>.size)
        } else {
            // Mic + system audio: interleave the mic pair with system frames
            // pulled from the tap path, zero-filling when the tap is idle.
            var systemFrames = 0
            if let tapRing, let tapScratch {
                let wanted = frames * 2
                // Bound latency: if the tap path has run ahead, discard the
                // backlog beyond a few cycles rather than drifting behind.
                let backlogLimit = wanted * 4
                if tapRing.availableToRead > backlogLimit {
                    var excess = tapRing.availableToRead - backlogLimit
                    while excess > 0 {
                        let chunk = min(excess, Self.maxFramesPerCycle * 2)
                        let drained = tapRing.read(into: tapScratch, maxCount: chunk)
                        if drained == 0 { break }
                        excess -= drained
                    }
                }
                systemFrames = tapRing.read(into: tapScratch, maxCount: wanted) / 2
            }
            for frame in 0..<frames {
                let out = frame * channelCount
                outputScratch[out] = micScratch[frame * 2]
                outputScratch[out + 1] = micScratch[frame * 2 + 1]
                if frame < systemFrames, let tapScratch {
                    outputScratch[out + 2] = tapScratch[frame * 2]
                    outputScratch[out + 3] = tapScratch[frame * 2 + 1]
                } else {
                    outputScratch[out + 2] = 0
                    outputScratch[out + 3] = 0
                }
            }
        }

        writeToSinks(outputScratch, floats: frames * channelCount, frames: frames)
    }

    /// System audio IOProc. Publishes its own meter (so system levels are
    /// independent of the mic) and either hands frames to the mic master path
    /// or writes directly when it is the only source.
    private func handleTapInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapScratch else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let frames = extractStereo(from: bufferList, into: tapScratch)
        guard frames > 0 else { return }

        let count = tapCallbacks.wrappingAdd(1, ordering: .relaxed)
        _ = count
        publishMeter(tapScratch, frames: frames, isMic: false)

        if let tapRing {
            // Mic is master; hand off for merging.
            tapRing.write(tapScratch, count: frames * 2)
        } else {
            // System audio only.
            writeToSinks(tapScratch, floats: frames * 2, frames: frames)
        }
    }

    @inline(__always)
    private func writeToSinks(_ data: UnsafePointer<Float>, floats: Int, frames: Int) {
        os_unfair_lock_lock(sinksLock)
        for sink in sinks {
            if !sink.write(data, count: floats) {
                _ = droppedFrames.wrappingAdd(frames, ordering: .relaxed)
            }
        }
        os_unfair_lock_unlock(sinksLock)
    }
}
