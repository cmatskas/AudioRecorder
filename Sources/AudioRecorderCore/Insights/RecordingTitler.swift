import Foundation

/// Turns a conversation into a short, human-readable recording name.
///
/// Everything here is pure and offline: prompt text, response parsing, name
/// shortening, and a keyword-frequency fallback used when no model is reachable
/// (or configured). The one or two network calls that sit between `user(...)`
/// and `parse(...)` are made by the caller, so this type stays testable and
/// `AudioRecorderCore` stays free of network code.
///
/// The hard part is not asking for a title, it is getting a *short* one. Models
/// routinely ignore a 14-character limit — asked to name a talk about childhood
/// labels, `nova-lite` answers "Impact of Childhood Labels". So the budget is
/// defended three times over: the prompt shows examples at the right length, the
/// caller offers one retry when the answer is too long, and `compress` shortens
/// whatever still arrives by dropping words rather than cutting mid-phrase.
/// Cutting produced fragments like "Impact of", which is how this was found.
public enum RecordingTitler {
    /// Names must be readable at a glance in Finder and in the app's own list,
    /// so generated ones are kept under 15 characters.
    public static let maxLength = 14

    /// How much dialogue is worth sending: the opening of a conversation
    /// establishes its topic, and a shorter prompt is cheaper and faster.
    public static let promptCharacterLimit = 4_000

    // MARK: - Prompt

    public static let system = """
        You name audio recording files. Given a description of a recorded \
        conversation, reply with a file name for it.

        Hard limit: \(maxLength) characters including spaces. A longer answer is \
        unusable and will be thrown away.

        Rules:
        - One or two short words. Never three.
        - Name the most concrete, memorable thing in the conversation, not the \
        abstract theme.
        - Letters, digits, spaces and hyphens only.
        - Never start with "The", "A" or "An". Never end with a preposition such \
        as "of", "for" or "on".
        - No dates, times, speaker names, quotes, or trailing punctuation.

        Examples of the required length and style:
        - a discussion of next quarter's pricing strategy -> Pricing Plan
        - a story about a boy told he had a broken brain after a head injury -> Broken Brain
        - a vendor walking through their onboarding product -> Vendor Demo
        - a retro on why the data migration slipped three weeks -> Migration Slip
        - a debate about how childhood nicknames shape adult confidence -> Child Labels

        Reply with the file name only.
        """

    public static func user(summary: String, transcript: String) -> String {
        var parts = context(summary: summary, transcript: transcript)
        parts.append("Reply with the file name only.")
        return parts.joined(separator: "\n\n")
    }

    /// Second and final attempt, quoting the rejected answer back. Models are
    /// poor at counting characters but good at shortening something concrete:
    /// "Checkout Outage" becomes "Checkout Down", "Analytics Product Tour"
    /// becomes "Analytics Overview".
    public static func retryUser(
        summary: String, transcript: String, previous: String
    ) -> String {
        var parts = context(summary: summary, transcript: transcript)
        parts.append(
            """
            Your previous answer, "\(previous)", was \(previous.count) characters — \
            too long. The limit is \(maxLength) characters including spaces. Reply \
            with a shorter file name for the same conversation, still one or two \
            real words.
            """
        )
        parts.append("Reply with the file name only.")
        return parts.joined(separator: "\n\n")
    }

    private static func context(summary: String, transcript: String) -> [String] {
        var parts: [String] = []
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            // The deep-lane briefing is already distilled, so it earns its place
            // ahead of raw dialogue.
            parts.append("Summary of the conversation:\n\(trimmedSummary)")
        }
        let head = String(transcript.prefix(promptCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty {
            parts.append("Conversation:\n\(head)")
        }
        return parts
    }

    // MARK: - Parsing

    /// A usable name from a model response, tolerating the wrappers models like
    /// to add: markdown fences, quotes, a `Title:` prefix, a trailing period.
    /// Shortened to the budget if needed. Nil when nothing usable survives.
    public static func parse(_ response: String) -> String? {
        guard let candidate = candidate(in: response) else { return nil }
        return compress(candidate)
    }

    /// The model's answer, cleaned but *not* shortened — what the caller shows
    /// the model when asking for something shorter, and what it measures to
    /// decide whether to ask at all.
    public static func candidate(in response: String) -> String? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown fences, keeping the first non-empty line inside.
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            text = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }

        // A model that explains itself gets only its first line read.
        if let firstLine = text.split(separator: "\n").first {
            text = String(firstLine)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["title:", "name:", "filename:", "file name:"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`“”‘’.!?:;,"))
        let cleaned = clean(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Whether a candidate can be used as-is.
    public static func fits(_ name: String, maxLength: Int = maxLength) -> Bool {
        !name.isEmpty && name.count <= maxLength
    }

    // MARK: - Cleaning and shortening

    /// Filesystem-safe, single-line, single-spaced — but any length.
    public static func clean(_ raw: String) -> String {
        var allowed = ""
        var scalars = Array(raw.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let character = Character(scalars[index])
            if character == "'" || character == "’" {
                // Possessives read badly once the apostrophe is stripped
                // ("Jims Label"), so drop the whole suffix: "Jim's" → "Jim".
                if index + 1 < scalars.count, Character(scalars[index + 1]) == "s" {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if character.isLetter || character.isNumber || character == "-" {
                allowed.append(character)
            } else {
                // Separators — and the path characters we must never emit —
                // become spaces so words stay apart.
                allowed.append(" ")
            }
            index += 1
        }

        let collapsed = allowed
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }

    /// Shortens a cleaned name to the budget by removing whole words, in order
    /// of how little they carry: leading articles, then function words, then
    /// filler nouns like "discussion". Only a single word longer than the whole
    /// budget is ever cut mid-word.
    public static func compress(_ raw: String, maxLength: Int = maxLength) -> String? {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }

        var words = cleaned.split(separator: " ").map(String.init)
        // A leading article never earns its characters.
        if words.count > 1, articles.contains(words[0].lowercased()) {
            words.removeFirst()
        }
        if let fitting = joined(words, within: maxLength) { return fitting }

        let withoutFunctionWords = keep(words) { !functionWords.contains($0.lowercased()) }
        if let fitting = joined(withoutFunctionWords, within: maxLength) { return fitting }

        let withoutFiller = keep(withoutFunctionWords) { !fillerWords.contains($0.lowercased()) }
        if let fitting = joined(withoutFiller, within: maxLength) { return fitting }

        // Best adjacent pair: keeps a real phrase ("Broken Brain") instead of a
        // fragment, preferring the pair carrying the most letters.
        let candidates = withoutFiller
        if candidates.count > 1 {
            var best: (words: String, letters: Int)?
            for index in 0..<(candidates.count - 1) {
                let pair = "\(candidates[index]) \(candidates[index + 1])"
                guard pair.count <= maxLength else { continue }
                let letters = candidates[index].count + candidates[index + 1].count
                if best == nil || letters > best!.letters {
                    best = (pair, letters)
                }
            }
            if let best { return best.words }
        }

        // Single most substantial word that fits.
        if let longest = candidates
            .filter({ $0.count <= maxLength })
            .max(by: { lhs, rhs in lhs.count < rhs.count }) {
            return longest
        }

        // One word longer than the entire budget: cut it.
        let fallback = String((candidates.first ?? cleaned).prefix(maxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return fallback.isEmpty ? nil : fallback
    }

    /// Canonical cleanup plus shortening — the entry point callers use.
    public static func sanitize(_ raw: String, maxLength: Int = maxLength) -> String? {
        compress(raw, maxLength: maxLength)
    }

    private static func joined(_ words: [String], within maxLength: Int) -> String? {
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        return joined.count <= maxLength ? joined : nil
    }

    /// Filters `words`, but never returns nothing: if every word would be
    /// dropped, the input is kept as it was.
    private static func keep(_ words: [String], where predicate: (String) -> Bool) -> [String] {
        let kept = words.filter(predicate)
        return kept.isEmpty ? words : kept
    }

    // MARK: - Offline fallback

    /// A name derived from the transcript itself, with no model involved: the
    /// most frequent salient words, title-cased, in order of first appearance.
    ///
    /// Deliberately simple and deterministic — this runs when the model call
    /// failed or no credentials exist, and a predictable "Pricing Budget" beats
    /// falling back to a timestamp.
    public static func heuristicTitle(from transcript: String) -> String? {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var index = 0

        for rawWord in transcript.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(rawWord)
            index += 1
            guard word.count >= 4, !stopWords.contains(word) else { continue }
            counts[word, default: 0] += 1
            if firstSeen[word] == nil { firstSeen[word] = index }
        }
        guard !counts.isEmpty else { return nil }

        let ranked = counts.keys.sorted { lhs, rhs in
            let leftCount = counts[lhs] ?? 0
            let rightCount = counts[rhs] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
        }

        var words: [String] = []
        var length = 0
        for word in ranked.prefix(4) {
            let capitalized = word.prefix(1).uppercased() + word.dropFirst()
            let added = words.isEmpty ? capitalized.count : capitalized.count + 1
            if length + added > maxLength { continue }
            words.append(capitalized)
            length += added
        }
        guard !words.isEmpty else {
            // One very long dominant word: cut it rather than give up.
            return compress(ranked[0])
        }
        return compress(words.joined(separator: " "))
    }

    // MARK: - Word lists

    private static let articles: Set<String> = ["the", "a", "an"]

    /// Grammatical glue: never worth characters in a 14-character label, and the
    /// source of the dangling names this feature shipped with.
    private static let functionWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "his", "her",
        "in", "into", "is", "it", "its", "of", "on", "or", "our", "that", "the",
        "their", "them", "they", "this", "to", "was", "were", "with", "your",
    ]

    /// Words that describe the *container* rather than the content. Dropped only
    /// when something more specific remains, so "Pricing Discussion" becomes
    /// "Pricing" rather than "Discussion".
    private static let fillerWords: Set<String> = [
        "chat", "conversation", "discussion", "item", "meeting", "narrative",
        "notes", "overview", "part", "recording", "session", "story", "stuff",
        "talk", "thing", "topic", "update",
    ]

    /// Small, fixed English stop list for the offline heuristic. Kept short on
    /// purpose: it only needs to stop conversational filler from becoming a file
    /// name.
    private static let stopWords: Set<String> = [
        "about", "actually", "after", "again", "against", "alright", "also",
        "always", "another", "anything", "around", "back", "basically", "because",
        "been", "before", "being", "both", "cannot", "could", "didn", "does",
        "doesn", "doing", "done", "down", "each", "else", "even", "ever", "every",
        "exactly", "from", "gonna", "good", "great", "guess", "have", "haven",
        "having", "hear", "hello", "here", "into", "just", "kind", "know", "last",
        "less", "like", "little", "look", "lots", "made", "make", "many", "maybe",
        "mean", "might", "more", "most", "much", "need", "never", "next", "nice",
        "okay", "only", "other", "over", "people", "perfect", "pretty", "probably",
        "really", "right", "said", "same", "says", "seen", "session", "should",
        "since", "some", "something", "sorry", "sound", "sounds", "still", "sure",
        "take", "talk", "than", "thanks", "that", "them", "then", "there",
        "these", "they", "thing", "things", "think", "this", "those", "though",
        "thought", "through", "time", "today", "totally", "under", "very", "want",
        "wasn", "well", "went", "were", "what", "when", "where", "which", "while",
        "will", "with", "won", "would", "yeah", "your", "yours",
    ]
}
