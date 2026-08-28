import Foundation

/// Checks GitHub Releases for a newer version and reports it to the UI.
///
/// Deliberately notification-only: it never downloads or installs anything, so
/// there is no auto-update machinery, no third-party dependency, and no extra
/// signing key. The only network activity is an unauthenticated GET of the
/// repository's latest-release metadata; nothing about the user or their
/// recordings is transmitted.
public final class UpdateChecker: @unchecked Sendable {
    public struct Update: Equatable, Sendable {
        public let version: String
        public let releaseURL: URL
        public let notes: String?
    }

    public enum CheckError: LocalizedError {
        case badResponse(Int)
        case noVersionInResponse

        public var errorDescription: String? {
            switch self {
            case let .badResponse(code):
                return "Update check failed (HTTP \(code))"
            case .noVersionInResponse:
                return "Update check returned no version"
            }
        }
    }

    /// Shape of the parts of the GitHub release payload we use.
    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/cmatskas/AudioRecorder/releases/latest"
    )!
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    /// Don't hit the API more than once a day.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    private let session: URLSession
    private let defaults: UserDefaults
    private let currentVersion: AppVersion?

    public init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        currentVersion: String? = Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String
    ) {
        self.session = session
        self.defaults = defaults
        self.currentVersion = currentVersion.flatMap(AppVersion.init)
    }

    /// Returns a newer release if one exists and has not been skipped.
    /// `force` bypasses the daily throttle (for a manual "Check for Updates").
    public func check(force: Bool = false) async throws -> Update? {
        if !force, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return nil
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AudioRecorder", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CheckError.badResponse(http.statusCode)
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)

        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let latest = AppVersion(payload.tagName) else {
            throw CheckError.noVersionInResponse
        }

        // Newer than what is running?
        if let currentVersion, latest <= currentVersion { return nil }
        // Explicitly skipped by the user?
        if let skipped = defaults.string(forKey: Self.skippedVersionKey),
           let skippedVersion = AppVersion(skipped), latest <= skippedVersion {
            return nil
        }

        return Update(
            version: latest.description,
            releaseURL: payload.htmlURL,
            notes: payload.body?.isEmpty == false ? payload.body : nil
        )
    }

    /// Suppresses notifications for this version and anything older.
    public func skip(_ update: Update) {
        defaults.set(update.version, forKey: Self.skippedVersionKey)
    }
}
