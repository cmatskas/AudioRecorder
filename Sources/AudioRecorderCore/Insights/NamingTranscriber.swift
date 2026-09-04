import Foundation

/// Produces text from a finished recording for the sole purpose of naming it.
///
/// Naming is the only consumer, so the result is plain text: no speaker
/// attribution, no timings, nothing persisted. Implementations are chosen by the
/// user — one that keeps audio on the machine (`LocalSpeechTranscriber`) and one
/// that streams a bounded window to Amazon Transcribe (in `AudioRecorderInsights`).
public protocol NamingTranscriber: Sendable {
    /// - Parameters:
    ///   - audioURL: the finished merged recording.
    ///   - maxDuration: how much of its beginning may be transcribed.
    /// - Returns: transcribed text, empty if the window contained no speech.
    func transcribe(audioURL: URL, maxDuration: TimeInterval) async throws -> String
}

/// Why a naming transcription could not run. These are surfaced as settings
/// captions, never as error banners: naming failing is not a recording failing.
public enum NamingTranscriberError: LocalizedError, Equatable {
    /// The user has not granted speech recognition access.
    case notAuthorized
    /// No on-device model for this language, or the OS is too old.
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access was denied, so recordings cannot be named automatically."
        case let .unavailable(reason):
            return "On-device transcription is unavailable: \(reason)"
        case let .failed(reason):
            return "Transcription failed: \(reason)"
        }
    }
}
