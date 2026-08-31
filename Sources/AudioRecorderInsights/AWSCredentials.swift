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
