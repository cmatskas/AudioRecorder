import Accelerate
import CoreAudio
import Foundation
import Synchronization

/// Captures microphone and/or system audio through a single, clock-synchronized
/// aggregate device.
///
/// System audio is captured with a Core Audio process tap (macOS 14.4+), which
/// removes any need for virtual loopback drivers. The microphone (if selected)
/// is added to the same aggregate device with drift compensation enabled, so
/// both sources share one sample clock and arrive sample-aligned in a single
/// real-time IOProc.
///
/// Output is interleaved Float32 frames:
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
    private static let maxOutputChannels = 4

    public let meters = LevelMeters()

    public private(set) var configuration: Configuration?
    public private(set) var sampleRate: Double = 48_000
    /// Interleaved output channel count (2 or 4).
    public private(set) var outputChannels: Int = 0
    public private(set) var hasMic = false
    public private(set) var hasSystemAudio = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    /// For each output channel, the flattened input channel index it maps from (-1 = silence).
    private var outputMap: [Int] = []
    /// Interleave scratch buffer used inside the IOProc.
    private var scratch: UnsafeMutablePointer<Float>?
    /// Per-output-channel source pointers, refreshed each IO cycle (preallocated).
    private var sourceBase = [UnsafeMutableRawPointer?](repeating: nil, count: maxOutputChannels)
    private var sourceStride = [Int](repeating: 0, count: maxOutputChannels)
    private var sourceOffset = [Int](repeating: 0, count: maxOutputChannels)

    /// Destinations for captured audio while recording. Guarded by `sinksLock`.
    private var sinks: [RingBuffer] = []
    private let sinksLock: UnsafeMutablePointer<os_unfair_lock_s>

    /// Total frames dropped because a sink ring buffer was full.
    private let droppedFrames = Atomic<Int>(0)

    public init() {
        sinksLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        sinksLock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        stop()
        teardown()
        scratch?.deallocate()
        sinksLock.deallocate()
    }

    public var framesDropped: Int { droppedFrames.load(ordering: .relaxed) }

    // MARK: - Lifecycle

    /// Builds the tap and aggregate device for the given configuration.
    public func prepare(_ config: Configuration) throws {
        guard config.micDevice != nil || config.captureSystemAudio else {
            throw CoreAudioError.osStatus(-1, "preparing capture: no sources selected")
        }
        stop()
        teardown()

        hasMic = config.micDevice != nil
        hasSystemAudio = config.captureSystemAudio

        // 1. System audio process tap (native replacement for loopback drivers).
        var tapUUIDString: String?
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
            tapUUIDString = description.uuid.uuidString
        }

        // 2. Aggregate device containing mic sub-device and/or the tap,
        //    both with drift compensation so they share one clock.
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRecorder Capture",
            kAudioAggregateDeviceUIDKey: "audio-recorder-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        if let mic = config.micDevice {
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: mic.uid,
                    kAudioSubDeviceDriftCompensationKey: true,
                ]
            ]
        }
        if let tapUUIDString {
            aggregateDescription[kAudioAggregateDeviceTapListKey] = [
                [
                    kAudioSubTapUIDKey: tapUUIDString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ]
            aggregateDescription[kAudioAggregateDeviceTapAutoStartKey] = true
        }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
            "creating aggregate capture device"
        )
        aggregateID = newAggregateID

        // 3. Sample rate: whatever the aggregate reports.
        sampleRate = (try? caGetValue(
            aggregateID,
            kAudioDevicePropertyNominalSampleRate,
            initial: Double(48_000),
            what: "reading aggregate sample rate"
        )) ?? 48_000

        // 4. Channel map. Sub-device streams come before tap streams,
        //    in the order listed in the aggregate description.
        var map: [Int] = []
        if let mic = config.micDevice {
            let micChannels = mic.channels
            map.append(0)                                   // out L <- mic ch 0
            map.append(micChannels > 1 ? 1 : 0)             // out R <- mic ch 1 (or duplicate mono)
        }
        if config.captureSystemAudio {
            let base = config.micDevice?.channels ?? 0      // skip all mic channels
            map.append(base)                                // out L <- tap ch 0
            map.append(base + 1)                            // out R <- tap ch 1
        }
        outputMap = map
        outputChannels = map.count

        scratch?.deallocate()
        scratch = UnsafeMutablePointer<Float>.allocate(
            capacity: Self.maxFramesPerCycle * outputChannels
        )

        configuration = config
    }

    public func start() throws {
        guard configuration != nil, aggregateID != kAudioObjectUnknown, !running else { return }
        var procID: AudioDeviceIOProcID?
        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
                [unowned self] _, inputData, _, _, _ in
                self.handleInput(inputData)
            },
            "creating IO proc"
        )
        ioProcID = procID
        try caCheck(AudioDeviceStart(aggregateID, ioProcID), "starting capture device")
        running = true
    }

    public func stop() {
        guard running, let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
        running = false
        meters.reset()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        configuration = nil
        outputChannels = 0
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

    // MARK: - Real-time path

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let scratch else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard bufferList.count > 0 else { return }

        // Resolve each output channel's source pointer from the flattened
        // input channel layout, and determine the common frame count.
        var frames = Int.max
        var flatBase = 0
        for i in 0..<Self.maxOutputChannels {
            sourceBase[i] = nil
        }
        for buffer in bufferList {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            frames = min(frames, bufferFrames)
            for out in 0..<outputChannels {
                let flat = outputMap[out]
                if flat >= flatBase && flat < flatBase + channels {
                    sourceBase[out] = data
                    sourceStride[out] = channels
                    sourceOffset[out] = flat - flatBase
                }
            }
            flatBase += channels
        }
        guard frames != Int.max, frames > 0 else { return }
        let frameCount = min(frames, Self.maxFramesPerCycle)
        let channelCount = outputChannels

        // Interleave into scratch.
        for out in 0..<channelCount {
            if let base = sourceBase[out] {
                let src = base.assumingMemoryBound(to: Float.self)
                let stride = sourceStride[out]
                let offset = sourceOffset[out]
                for frame in 0..<frameCount {
                    scratch[frame * channelCount + out] = src[frame * stride + offset]
                }
            } else {
                for frame in 0..<frameCount {
                    scratch[frame * channelCount + out] = 0
                }
            }
        }

        // Levels.
        var pairOffset = 0
        if hasMic {
            var left: Float = 0
            var right: Float = 0
            vDSP_rmsqv(scratch, vDSP_Stride(channelCount), &left, vDSP_Length(frameCount))
            vDSP_rmsqv(scratch + 1, vDSP_Stride(channelCount), &right, vDSP_Length(frameCount))
            meters.setMic(left: left, right: right)
            pairOffset = 2
        }
        if hasSystemAudio {
            var left: Float = 0
            var right: Float = 0
            vDSP_rmsqv(scratch + pairOffset, vDSP_Stride(channelCount), &left, vDSP_Length(frameCount))
            vDSP_rmsqv(scratch + pairOffset + 1, vDSP_Stride(channelCount), &right, vDSP_Length(frameCount))
            meters.setSystem(left: left, right: right)
        }

        // Feed recording sinks.
        os_unfair_lock_lock(sinksLock)
        for sink in sinks {
            if !sink.write(scratch, count: frameCount * channelCount) {
                _ = droppedFrames.wrappingAdd(frameCount, ordering: .relaxed)
            }
        }
        os_unfair_lock_unlock(sinksLock)
    }
}
