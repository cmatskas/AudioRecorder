import SwiftUI

/// First-run (and reconfigure) sheet for Live Insights. Collects credentials
/// and region, proves them with a test call, and states plainly that enabling
/// this streams audio off the machine — the one thing this app otherwise
/// never does.
struct InsightsSetupSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum CredentialChoice: Hashable {
        case profile
        case keys
    }

    @State private var choice: CredentialChoice = .profile
    @State private var profiles: [String] = []
    @State private var selectedProfile = "default"
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var region = "us-east-1"
    @State private var fastModelID = InsightsConfiguration.defaultFastModelID
    @State private var deepModelID = InsightsConfiguration.defaultDeepModelID
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    private static let regions = [
        "us-east-1", "us-east-2", "us-west-2",
        "eu-central-1", "eu-west-1", "eu-west-2",
        "ap-northeast-1", "ap-southeast-2",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable Live Insights")
                .font(.title3.bold())
            Text("Transcribes your recording and suggests follow-up questions in real time, using Amazon Transcribe and Bedrock in your AWS account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            privacyNote

            credentialsSection

            HStack {
                Text("Region")
                Picker("Region", selection: $region) {
                    ForEach(Self.regions, id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
            }

            DisclosureGroup("Advanced: models") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Suggestions (fast)") {
                        TextField("model ID", text: $fastModelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                    }
                    LabeledContent("Summary (deep)") {
                        TextField("model ID", text: $deepModelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                    }
                    Text("Both models must be enabled for your account in the chosen region.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
            .font(.callout)

            testRow

            Divider()

            HStack {
                if state.insightsConfiguration != nil {
                    Button("Forget credentials", role: .destructive) {
                        state.resetInsightsConfiguration()
                        dismiss()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(state.insightsConfiguration == nil ? "Enable" : "Save") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: populate)
    }

    // MARK: - Sections

    private var privacyNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text("While insights are on, audio from a recording is streamed to AWS under your account. The recording itself always stays fully local, and insights can be paused at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    @ViewBuilder
    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credentials").font(.headline)
            if !profiles.isEmpty {
                Picker("", selection: $choice) {
                    Text("AWS profile").tag(CredentialChoice.profile)
                    Text("Access keys").tag(CredentialChoice.keys)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            switch choice {
            case .profile:
                HStack {
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(profiles, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Text("from ~/.aws")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .keys:
                VStack(spacing: 6) {
                    TextField("Access key ID", text: $accessKeyID)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    SecureField("Secret access key", text: $secretAccessKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    Text("Stored in your macOS Keychain, never on disk in plain text.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            Button("Test connection") { runTest() }
                .disabled(!isComplete || testing || state.insightsValidator == nil)
            if testing {
                ProgressView().controlSize(.small)
            } else if let result = testResult {
                switch result {
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .lineLimit(2)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
    }

    // MARK: - Logic

    private var isComplete: Bool {
        let modelsOK = !fastModelID.trimmingCharacters(in: .whitespaces).isEmpty
            && !deepModelID.trimmingCharacters(in: .whitespaces).isEmpty
        switch choice {
        case .profile:
            return !selectedProfile.isEmpty && modelsOK
        case .keys:
            return !accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
                && !secretAccessKey.trimmingCharacters(in: .whitespaces).isEmpty
                && modelsOK
        }
    }

    private func populate() {
        profiles = AWSProfileDiscovery.profileNames()
        if profiles.isEmpty {
            choice = .keys
        }
        if let config = state.insightsConfiguration {
            region = config.region
            fastModelID = config.fastModelID
            deepModelID = config.deepModelID
            switch config.credentialSource {
            case let .profile(name):
                choice = .profile
                selectedProfile = profiles.contains(name) ? name : (profiles.first ?? name)
            case .keychain:
                choice = .keys
                if let keys = InsightsKeychain().load() {
                    accessKeyID = keys.accessKeyID
                    secretAccessKey = keys.secretAccessKey
                }
            }
        } else if let first = profiles.first {
            selectedProfile = profiles.contains("default") ? "default" : first
        }
    }

    private func buildConfiguration() throws -> InsightsConfiguration {
        let source: InsightsConfiguration.CredentialSource
        switch choice {
        case .profile:
            source = .profile(name: selectedProfile)
        case .keys:
            try InsightsKeychain().save(
                .init(
                    accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces),
                    secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespaces)
                )
            )
            source = .keychain
        }
        return InsightsConfiguration(
            credentialSource: source,
            region: region,
            fastModelID: fastModelID.trimmingCharacters(in: .whitespaces),
            deepModelID: deepModelID.trimmingCharacters(in: .whitespaces)
        )
    }

    private func runTest() {
        guard let validator = state.insightsValidator else { return }
        testing = true
        testResult = nil
        Task {
            do {
                let config = try buildConfiguration()
                let message = try await validator.validate(config)
                testResult = .success(message)
            } catch {
                testResult = .failure(error)
            }
            testing = false
        }
    }

    private func apply() {
        do {
            let config = try buildConfiguration()
            state.applyInsightsConfiguration(config)
        } catch {
            testResult = .failure(error)
        }
    }
}
