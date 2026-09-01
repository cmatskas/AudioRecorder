import AWSSDKIdentity
import AWSSTS
import AudioRecorderCore
import Foundation
import SmithyIdentity

/// Builds the credential identity resolver described by the user's insights
/// configuration. Secrets entered in-app come from the Keychain; profiles are
/// resolved from ~/.aws by the SDK.
enum AWSCredentials {
    enum CredentialError: LocalizedError {
        case missingKeychainKeys

        var errorDescription: String? {
            switch self {
            case .missingKeychainKeys:
                return "No AWS access keys found in the Keychain. Re-enter them in Live Insights setup."
            }
        }
    }

    static func resolver(
        for configuration: InsightsConfiguration
    ) throws -> any AWSCredentialIdentityResolver {
        switch configuration.credentialSource {
        case let .profile(name):
            // Resolve inline keys ourselves (case-insensitive, so console
            // paste style `AWS_ACCESS_KEY_ID = …` works like it does in the
            // CLI). Profiles without inline keys — SSO, credential_process,
            // role assumption — fall through to the SDK's resolver.
            if let keys = AWSProfileDiscovery.staticCredentials(forProfile: name) {
                return StaticAWSCredentialIdentityResolver(
                    AWSCredentialIdentity(
                        accessKey: keys.accessKeyID,
                        secret: keys.secretAccessKey,
                        sessionToken: keys.sessionToken
                    )
                )
            }
            return ProfileAWSCredentialIdentityResolver(profileName: name)
        case .keychain:
            guard let keys = InsightsKeychain().load() else {
                throw CredentialError.missingKeychainKeys
            }
            return StaticAWSCredentialIdentityResolver(
                AWSCredentialIdentity(
                    accessKey: keys.accessKeyID,
                    secret: keys.secretAccessKey
                )
            )
        }
    }

    /// Raw credentials for request presigning (the Transcribe WebSocket URL
    /// is signed by us, not by the SDK). Same resolution order as
    /// `resolver(for:)`; profiles without inline keys go through the SDK's
    /// chain and are unwrapped to their raw form.
    static func rawCredentials(
        for configuration: InsightsConfiguration
    ) async throws -> RawAWSCredentials {
        switch configuration.credentialSource {
        case let .profile(name):
            if let keys = AWSProfileDiscovery.staticCredentials(forProfile: name) {
                return RawAWSCredentials(
                    accessKeyID: keys.accessKeyID,
                    secretAccessKey: keys.secretAccessKey,
                    sessionToken: keys.sessionToken
                )
            }
            let identity = try await ProfileAWSCredentialIdentityResolver(profileName: name)
                .getIdentity(identityProperties: nil)
            return RawAWSCredentials(
                accessKeyID: identity.accessKey,
                secretAccessKey: identity.secret,
                sessionToken: identity.sessionToken
            )
        case .keychain:
            guard let keys = InsightsKeychain().load() else {
                throw CredentialError.missingKeychainKeys
            }
            return RawAWSCredentials(
                accessKeyID: keys.accessKeyID,
                secretAccessKey: keys.secretAccessKey,
                sessionToken: nil
            )
        }
    }
}

/// "Test connection" for the setup sheet: a call to STS GetCallerIdentity,
/// the cheapest possible proof that credentials, region, and network work.
public struct STSCredentialsValidator: InsightsCredentialsValidating {
    public init() {}

    public func validate(_ configuration: InsightsConfiguration) async throws -> String {
        let config = try await STSClient.STSClientConfiguration(
            awsCredentialIdentityResolver: AWSCredentials.resolver(for: configuration),
            region: configuration.region
        )
        let client = STSClient(config: config)
        let identity = try await client.getCallerIdentity(input: GetCallerIdentityInput())
        let account = identity.account ?? "unknown account"
        let arn = identity.arn ?? ""
        let shortIdentity = arn.split(separator: "/").last.map(String.init) ?? arn
        return "Connected as \(shortIdentity) (account \(account))"
    }
}
