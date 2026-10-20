import Foundation

/// Asks a long recording whether it should keep going.
///
/// A recording left running by accident — a meeting that ended, a Mac that was
/// walked away from — costs disk space and turns a useful file into hours of
/// silence to scrub through. After two hours the user is asked to confirm, and
/// hourly after that.
///
/// The check-in fails *closed*: no answer within the response window stops the
/// recording, exactly as answering "No" does. That is the deliberate choice
/// between two imperfect defaults — a recording nobody is attending is stopped
/// and safely finalized, rather than running until the disk fills.
///
/// Deadlines are wall-clock `Date`s derived from the recording's start, not a
/// chain of sleeps, so a long system suspension cannot push the two-hour mark
/// out to three. Sleeps are sliced so cancellation and a resumed machine are
/// both noticed quickly.
@MainActor
public final class LongRecordingPrompt {
    /// Why a recording is being stopped, so the UI can explain itself — or stay
    /// quiet when the user already knows.
    public enum StopReason: Sendable, Equatable {
        /// The user answered "No".
        case declined
        /// The response window passed with no answer.
        case unanswered
    }

    public struct Tuning: Sendable {
        /// How long a recording may run before the first check-in.
        public var firstCheckIn: TimeInterval
        /// Gap between check-ins after the user confirms.
        public var repeatInterval: TimeInterval
        /// How long the user has to answer before the recording is stopped.
        public var responseWindow: TimeInterval

        public init(
            firstCheckIn: TimeInterval = 2 * 60 * 60,
            repeatInterval: TimeInterval = 60 * 60,
            responseWindow: TimeInterval = 30
        ) {
            self.firstCheckIn = firstCheckIn
            self.repeatInterval = repeatInterval
            self.responseWindow = responseWindow
        }

        /// Shipping timings, with optional overrides so the two-hour path can be
        /// exercised in minutes instead of an afternoon:
        ///
        /// ```
        /// defaults write dev.cmatskas.AudioRecorder longRecordingCheckInMinutes 2
        /// defaults write dev.cmatskas.AudioRecorder longRecordingRepeatMinutes 1
        /// defaults write dev.cmatskas.AudioRecorder longRecordingResponseSeconds 15
        /// ```
        ///
        /// Only positive values are honoured, so a stray or cleared key leaves
        /// the shipping behaviour intact.
        public static func resolved(from defaults: UserDefaults = .standard) -> Tuning {
            var tuning = Tuning()
            let checkInMinutes = defaults.double(forKey: "longRecordingCheckInMinutes")
            if checkInMinutes > 0 {
                tuning.firstCheckIn = checkInMinutes * 60
            }
            let repeatMinutes = defaults.double(forKey: "longRecordingRepeatMinutes")
            if repeatMinutes > 0 {
                tuning.repeatInterval = repeatMinutes * 60
            }
            let responseSeconds = defaults.double(forKey: "longRecordingResponseSeconds")
            if responseSeconds > 0 {
                tuning.responseWindow = responseSeconds
            }
            return tuning
        }
    }

    public let tuning: Tuning

    /// True while the user is being asked.
    public private(set) var isAsking = false
    /// When an unanswered question stops the recording; drives the countdown.
    public private(set) var responseDeadline: Date?

    private var task: Task<Void, Never>?
    private var onAsk: (@MainActor () -> Void)?
    private var onStop: (@MainActor (StopReason) -> Void)?
    /// Set when the user answers "Yes" while the question is on screen.
    private var continuationConfirmed = false

    /// Longest a single sleep may last, so cancellation and clock jumps are
    /// noticed promptly rather than at the end of an hour-long nap.
    private static let sliceLimit: TimeInterval = 2

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Begins watching a recording that started at `startedAt`.
    ///
    /// - Parameters:
    ///   - ask: presents the question. Called on the main actor.
    ///   - stop: ends the recording, because the user said no or said nothing.
    public func start(
        startedAt: Date,
        ask: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor (StopReason) -> Void
    ) {
        cancel()
        onAsk = ask
        onStop = stop
        task = Task { [weak self] in
            guard let self else { return }
            var deadline = startedAt.addingTimeInterval(self.tuning.firstCheckIn)
            while !Task.isCancelled {
                guard await Self.sleep(until: deadline) else { return }
                guard await self.askAndAwaitAnswer() else { return }
                deadline = Date().addingTimeInterval(self.tuning.repeatInterval)
            }
        }
    }

    /// The user confirmed: keep recording, and ask again after the interval.
    public func confirmContinue() {
        guard isAsking else { return }
        continuationConfirmed = true
        isAsking = false
        responseDeadline = nil
    }

    /// The user declined. The recording is stopped through the same path an
    /// unanswered question takes.
    public func decline() {
        guard isAsking else { return }
        isAsking = false
        responseDeadline = nil
        let stop = onStop
        cancel()
        stop?(.declined)
    }

    /// Stops watching — the recording ended for some other reason.
    public func cancel() {
        task?.cancel()
        task = nil
        isAsking = false
        responseDeadline = nil
        continuationConfirmed = false
        onAsk = nil
        onStop = nil
    }

    // MARK: - Internals

    /// Shows the question and waits for an answer. Returns true if the user
    /// confirmed (so watching continues), false if the recording was stopped or
    /// the wait was cancelled.
    private func askAndAwaitAnswer() async -> Bool {
        continuationConfirmed = false
        isAsking = true
        responseDeadline = Date().addingTimeInterval(tuning.responseWindow)
        onAsk?()

        let deadline = responseDeadline ?? Date()
        while Date() < deadline {
            if Task.isCancelled { return false }
            if continuationConfirmed { return true }
            // Finer-grained than the deadline sleep: an answer should end the
            // wait immediately, not up to two seconds later.
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
            if !isAsking && !continuationConfirmed {
                // `decline()` or `cancel()` ran.
                return false
            }
        }
        if continuationConfirmed { return true }
        guard isAsking, !Task.isCancelled else { return false }

        // Nobody answered: stop the recording, as if they had said no.
        isAsking = false
        responseDeadline = nil
        let stop = onStop
        onAsk = nil
        onStop = nil
        stop?(.unanswered)
        return false
    }

    /// Sleeps until `deadline`, in slices. Returns false if cancelled.
    private static func sleep(until deadline: Date) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return true }
            do {
                try await Task.sleep(for: .seconds(min(remaining, sliceLimit)))
            } catch {
                return false
            }
        }
    }
}
