import AppKit
import SwiftUI

/// Export sheet: pick a format, choose what to include, save. Speaker and
/// timestamp attribution can be stripped here because it is preserved on disk —
/// the reverse would not be recoverable.
public struct TranscriptExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let content: TranscriptExporter.Content

    @State private var format: TranscriptExporter.Format = .plainText
    @State private var options = TranscriptExporter.Options()
    @State private var errorMessage: String?

    public init(content: TranscriptExporter.Content) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export transcript")
                .font(.title3.bold())
            Text("\(content.utterances.count) utterances from \(content.title)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Format", selection: $format) {
                ForEach(TranscriptExporter.Format.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                Text("Include").font(.headline)
                Toggle("Speaker labels", isOn: $options.includeSpeakers)
                Toggle("Timestamps", isOn: $options.includeTimestamps)
                    .disabled(!format.honoursTimestampOption)
                    .help(
                        format.honoursTimestampOption
                            ? "Prefixes each line with its position in the recording"
                            : "Subtitle formats always carry timings"
                    )
                Toggle("Summary", isOn: $options.includeSummary)
                    .disabled(!format.supportsInsights || content.summary.isEmpty)
                Toggle("Suggested follow-ups", isOn: $options.includeSuggestions)
                    .disabled(!format.supportsInsights || content.suggestions.isEmpty)
            }
            .toggleStyle(.checkbox)

            if format.requiresOffsets, !hasOffsets {
                Label(
                    "This recording has no per-utterance timings, so subtitles cannot be generated.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            previewSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save…") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(content.utterances.isEmpty || (format.requiresOffsets && !hasOffsets))
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var hasOffsets: Bool {
        content.utterances.contains { $0.startOffset != nil }
    }

    private var rendered: String {
        TranscriptExporter.export(content, format: format, options: options)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                Text(rendered.isEmpty ? "(empty)" : String(rendered.prefix(1500)))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptExporter.suggestedFileName(
            for: content.title, format: format
        )
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(rendered.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
