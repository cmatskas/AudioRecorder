import AWSBedrockRuntime
import AudioRecorderCore
import Foundation

/// `LLMClient` backed by the Bedrock Converse API, which gives one request
/// shape across model families (Nova for the fast lane, Claude for the deep
/// pass) so model IDs stay a pure configuration concern.
struct BedrockLLMClient: LLMClient {
    private let client: BedrockRuntimeClient

    init(configuration: InsightsConfiguration) async throws {
        let config = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            awsCredentialIdentityResolver: AWSCredentials.resolver(for: configuration),
            region: configuration.region
        )
        client = BedrockRuntimeClient(config: config)
    }

    func complete(modelID: String, system: String, user: String) async throws -> String {
        let input = ConverseInput(
            inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration(
                maxTokens: 1024,
                temperature: 0.2
            ),
            messages: [
                BedrockRuntimeClientTypes.Message(
                    content: [.text(user)],
                    role: .user
                )
            ],
            modelId: modelID,
            system: [.text(system)]
        )
        let output = try await client.converse(input: input)
        guard
            case let .message(message) = output.output,
            let content = message.content
        else { return "" }
        return content
            .compactMap { block -> String? in
                if case let .text(text) = block { return text }
                return nil
            }
            .joined(separator: "\n")
    }
}
