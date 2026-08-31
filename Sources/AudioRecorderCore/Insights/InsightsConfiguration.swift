import Foundation
import Security

/// Non-secret configuration for live insights, persisted in UserDefaults.
/// Secrets (manually entered access keys) live in the Keychain, never here.
public struct InsightsConfiguration: Codable, Equatable, Sendable {
    public enum CredentialSource: Codable, Equatable, Sendable {
        /// A named profile from ~/.aws (resolved by the AWS SDK's chain).
        case profile(name: String)
        /// Access keys entered in the app, stored in the macOS Keychain.
        case keychain
    }

    public var credentialSource: CredentialSource
    public var region: String
    /// Model for the per-utterance fast lane (live follow-up suggestions).
    public var fastModelID: String
    /// Model for the periodic deep pass (summary, recommendations).
    public var deepModelID: String

    public static let defaultFastModelID = "us.amazon.nova-lite-v1:0"
    public static let defaultDeepModelID = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

    public init(
        credentialSource: CredentialSource,
        region: String = "us-east-1",
        fastModelID: String = InsightsConfiguration.defaultFastModelID,
        deepModelID: String = InsightsConfiguration.defaultDeepModelID
    ) {
        self.credentialSource = credentialSource
        self.region = region
        self.fastModelID = fastModelID
        self.deepModelID = deepModelID
    }

    // MARK: - Persistence

    private static let defaultsKey = "insightsConfiguration"

    public static func load(from defaults: UserDefaults = .standard) -> InsightsConfiguration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(InsightsConfiguration.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Discovers named profiles in ~/.aws/credentials and ~/.aws/config so
/// developers with existing AWS setups get a picker instead of a paste box.
public enum AWSProfileDiscovery {
    public static func profileNames(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var names: Set<String> = []
        let credentials = home.appendingPathComponent(".aws/credentials")
        let config = home.appendingPathComponent(".aws/config")
        names.formUnion(sectionNames(in: credentials, stripProfilePrefix: false))
        names.formUnion(sectionNames(in: config, stripProfilePrefix: true))
        return names.sorted { lhs, rhs in
            if lhs == "default" { return true }
            if rhs == "default" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func sectionNames(in file: URL, stripProfilePrefix: Bool) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { continue }
            var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if stripProfilePrefix, name.hasPrefix("profile ") {
                name = String(name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty { names.append(name) }
        }
        return names
    }
}

/// Keychain-backed storage for manually entered AWS access keys.
public struct InsightsKeychain: Sendable {
    public struct Keys: Equatable, Sendable {
        public let accessKeyID: String
        public let secretAccessKey: String

        public init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus, String)

        public var errorDescription: String? {
            switch self {
            case let .status(code, operation):
                return "Keychain \(operation) failed (\(code))"
            }
        }
    }

    private let service: String

    public init(service: String = "dev.cmatskas.AudioRecorder.insights") {
        self.service = service
    }

    public func save(_ keys: Keys) throws {
        try setItem(account: "aws-access-key-id", value: keys.accessKeyID)
        try setItem(account: "aws-secret-access-key", value: keys.secretAccessKey)
    }

    public func load() -> Keys? {
        guard
            let accessKey = getItem(account: "aws-access-key-id"),
            let secret = getItem(account: "aws-secret-access-key")
        else { return nil }
        return Keys(accessKeyID: accessKey, secretAccessKey: secret)
    }

    public func delete() {
        deleteItem(account: "aws-access-key-id")
        deleteItem(account: "aws-secret-access-key")
    }

    // MARK: - Keychain plumbing

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func setItem(account: String, value: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.status(status, "write")
        }
    }

    private func getItem(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteItem(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
