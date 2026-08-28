import Foundation

/// A dotted numeric version ("1.2.3"), tolerant of a leading "v" and of
/// missing components ("1.2" == "1.2.0").
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]
    public let original: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if candidate.lowercased().hasPrefix("v") {
            candidate.removeFirst()
        }
        // Ignore any pre-release or build suffix ("1.2.3-beta.1").
        let numeric = candidate.split(separator: "-", maxSplits: 1).first.map(String.init) ?? candidate
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
        original = trimmed
    }

    public var description: String { original }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return true
    }
}
