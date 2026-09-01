import AudioRecorderCore
import Foundation

/// Defers Bedrock client construction to the first completion call, so the
/// insights pipeline can go live the instant transcription connects instead
/// of gating on SDK client setup. The client is built once and cached;
/// a failed construction is not cached, so the next call retries.
actor LazyBedrockClient: LLMClient {
    private let configuration: InsightsConfiguration
    private var client: BedrockLLMClient?

    init(configuration: InsightsConfiguration) {
        self.configuration = configuration
    }

    func complete(modelID: String, system: String, user: String) async throws -> String {
        let client = try await resolvedClient()
        return try await client.complete(modelID: modelID, system: system, user: user)
    }

    private func resolvedClient() async throws -> BedrockLLMClient {
        if let client { return client }
        let created = try await BedrockLLMClient(configuration: configuration)
        client = created
        return created
    }
}
