import Foundation
import Synchronization

/// Rolling transcript of the conversation, merged across sources.
///
/// Thread-safe: utterances arrive from two concurrent transcription streams.
/// Kept sorted by timestamp, since "Me" and "Them" finalize independently and
/// can land slightly out of order.
public final class TranscriptStore: @unchecked Sendable {
    private let storage = Mutex<[Utterance]>([])

    public init() {}

    public func append(_ utterance: Utterance) {
        storage.withLock { utterances in
            // Utterances are nearly ordered; walk back from the end.
            var index = utterances.endIndex
            while index > utterances.startIndex,
                  utterances[index - 1].timestamp > utterance.timestamp {
                index -= 1
            }
            utterances.insert(utterance, at: index)
        }
    }

    public var all: [Utterance] {
        storage.withLock { $0 }
    }

    public var isEmpty: Bool {
        storage.withLock { $0.isEmpty }
    }

    public var count: Int {
        storage.withLock { $0.count }
    }

    /// Utterances from the trailing window, for prompt context.
    public func window(minutes: Double, now: Date = Date()) -> [Utterance] {
        let cutoff = now.addingTimeInterval(-minutes * 60)
        return storage.withLock { utterances in
            guard let start = utterances.firstIndex(where: { $0.timestamp >= cutoff }) else {
                return []
            }
            return Array(utterances[start...])
        }
    }

    /// Renders utterances as dialogue lines: "Me: …" / "Them: …".
    public static func dialogue(_ utterances: [Utterance]) -> String {
        utterances
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Coalesces bursts of events into a single trailing invocation: the action
/// runs `interval` after the *last* trigger. Used so a rapid exchange of
/// utterances produces one fast-lane analysis call, not five.
@MainActor
public final class AsyncDebouncer {
    private let interval: Duration
    private let action: @MainActor () async -> Void
    private var pending: Task<Void, Never>?

    public init(interval: Duration, action: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.action = action
    }

    public func trigger() {
        pending?.cancel()
        pending = Task { [interval, action] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
