import AVFoundation
import Foundation
import Speech

/// Transcribes the head of a recording **on this Mac**, with no network and no
/// credentials, so recordings can be named by content even when Live Insights is
/// off and nothing is streamed to AWS.
///
/// Two implementations behind one door:
///
///  - macOS 26 and later: `SpeechAnalyzer` + `SpeechTranscriber`, Apple's
///    current on-device engine (the one Notes and Voice Memos use). Faster and
///    more accurate, and its language assets are managed by the OS.
///  - macOS 15: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
///    That flag is not optional here — without it Apple's recognizer may send
///    audio to Apple's servers, which is exactly the promise this backend
///    exists to keep.
public struct LocalSpeechTranscriber: NamingTranscriber {
    private let locale: Locale

    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    /// Whether this backend can be offered at all, so settings can explain
    /// itself instead of failing silently later.
    public static func availability(
        locale: Locale = Locale.current
    ) async -> Result<Void, NamingTranscriberError> {
        if #available(macOS 26, *) {
            if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
                return .success(())
            }
            // Fall through: the older recognizer may still cover this language.
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .failure(.unavailable("no speech model for \(locale.identifier)"))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .failure(
                .unavailable("this Mac has no offline model for \(locale.identifier)")
            )
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return .failure(.notAuthorized)
        default:
            return .success(())
        }
    }

    public func transcribe(audioURL: URL, maxDuration: TimeInterval) async throws -> String {
        // Trim first: a 90-minute recording is not worth decoding in full to
        // name it, and both engines take a file.
        let head = try AudioFileChunker.head(of: audioURL, maxDuration: maxDuration)
        defer {
            if head.isTemporary {
                try? FileManager.default.removeItem(at: head.url)
            }
        }

        if #available(macOS 26, *) {
            if let text = try await modernTranscribe(url: head.url) {
                return text
            }
        }
        return try await legacyTranscribe(url: head.url)
    }

    // MARK: - macOS 26+

    /// Returns nil when this language has no `SpeechTranscriber` support, so the
    /// caller can try the older recognizer instead of giving up.
    @available(macOS 26, *)
    private func modernTranscribe(url: URL) async throws -> String? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)

        // Language assets are installed on demand by the OS. Downloading one
        // is acceptable here (it is one-time and local), but a failure is not
        // fatal — the legacy recognizer may already have a model.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
        } catch {
            return nil
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw NamingTranscriberError.failed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                pieces.append(String(result.text.characters))
            }
            return pieces
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw NamingTranscriberError.failed(error.localizedDescription)
        }

        do {
            return try await collector.value.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw NamingTranscriberError.failed(error.localizedDescription)
        }
    }

    // MARK: - macOS 15

    private func legacyTranscribe(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw NamingTranscriberError.unavailable("no speech model for \(locale.identifier)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw NamingTranscriberError.unavailable(
                "this Mac has no offline model for \(locale.identifier)"
            )
        }
        try await requestAuthorization()

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true  // never send audio to Apple
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            // The recognizer calls back more than once in some conditions;
            // resume exactly once.
            let finished = Locked(false)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if finished.exchange(true) == false {
                        continuation.resume(
                            throwing: NamingTranscriberError.failed(error.localizedDescription)
                        )
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if finished.exchange(true) == false {
                    continuation.resume(
                        returning: result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        }
    }

    private func requestAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw NamingTranscriberError.notAuthorized
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw NamingTranscriberError.notAuthorized }
        @unknown default:
            throw NamingTranscriberError.notAuthorized
        }
    }
}

/// Minimal mutable box for the one place a completion handler must be made
/// idempotent across threads.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    /// Sets a new value and returns the previous one.
    func exchange(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let previous = value
        value = newValue
        return previous
    }
}
