import AVFoundation
import SwiftUI

/// Read-only browser over past recordings in the backup folder: play them,
/// read their transcripts and insights, reveal them in Finder. Never writes.
public struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = HistoryViewModel()
    @State private var showExport = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            if model.items.isEmpty {
                emptyState
            } else {
                list
                if let selected = model.selected {
                    detail(for: selected)
                }
            }
        }
        .onAppear { model.refresh(root: state.backupRoot) }
        .onDisappear { model.stopPlayback() }
        .sheet(isPresented: $showExport) {
            if let selected = model.selected {
                TranscriptExportSheet(
                    content: TranscriptExporter.Content(
                        title: selected.name,
                        recordedAt: selected.createdAt,
                        utterances: model.utterances,
                        summary: model.insights?.summary ?? "",
                        suggestions: model.insights?.suggestions ?? []
                    )
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No finished recordings yet")
                .foregroundStyle(.secondary)
            Text("Recordings appear here after they complete.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { item in
                    row(item)
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func row(_ item: HistoryItem) -> some View {
        Button {
            model.select(item)
        } label: {
            HStack(spacing: 8) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.monospacedDigit())
                    .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let mic = item.micName {
                        Text(mic).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if item.hasInsights || item.hasTranscript {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                        .help("Has transcript and insights")
                }
                if item.audioURL == nil {
                    Image(systemName: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("No merged audio file (PCM masters only)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(model.selected?.id == item.id ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(for item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameRow(for: item)
            HStack(spacing: 10) {
                if item.audioURL != nil {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(
                            model.isPlaying ? "Stop" : "Play",
                            systemImage: model.isPlaying ? "stop.fill" : "play.fill"
                        )
                    }
                    .controlSize(.small)
                }
                Button("Show in Finder") {
                    state.revealInFinder(item.audioURL ?? item.directory)
                }
                .controlSize(.small)
                if !model.utterances.isEmpty {
                    Button {
                        showExport = true
                    } label: {
                        Label("Export transcript…", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                }
                Spacer()
            }

            if !model.utterances.isEmpty || model.insights != nil {
                detailTabs
            } else {
                Text("No transcript for this recording — Live Insights was off.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// The recording's name, editable here as well as on the Record tab — both
    /// go through `SessionRenamer`, so the manifest and the files on disk never
    /// disagree about what a recording is called.
    @ViewBuilder
    private func nameRow(for item: HistoryItem) -> some View {
        HStack(spacing: 8) {
            if isEditingName {
                TextField("Recording name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { commitName(for: item) }
                    .frame(maxWidth: 240)
                Button("Save") { commitName(for: item) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(nameValidationMessage != nil)
                Button("Cancel") { isEditingName = false }
                    .controlSize(.small)
                if let message = nameValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    draftName = item.name
                    isEditingName = true
                    nameFieldFocused = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .controlSize(.small)
                .disabled(state.isRecording || state.isSaving || state.isRenaming)
                .accessibilityHint("Rename this recording")
            }
            Spacer()
        }
        .onChange(of: item.id) { _, _ in isEditingName = false }
    }

    private var nameValidationMessage: String? {
        switch SessionRenamer.validate(draftName) {
        case .success:
            return nil
        case let .failure(error):
            return error.errorDescription
        }
    }

    private func commitName(for item: HistoryItem) {
        guard nameValidationMessage == nil else { return }
        isEditingName = false
        state.rename(item, to: draftName) { success in
            if success {
                model.refresh(root: state.backupRoot)
            }
        }
    }

    @ViewBuilder
    private var detailTabs: some View {
        Picker("", selection: $model.detailTab) {
            if model.insights != nil {
                Text("Summary").tag(HistoryViewModel.DetailTab.summary)
            }
            if !model.utterances.isEmpty {
                Text("Transcript").tag(HistoryViewModel.DetailTab.transcript)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        ScrollView {
            switch model.detailTab {
            case .summary:
                if let insights = model.insights {
                    VStack(alignment: .leading, spacing: 8) {
                        if !insights.summary.isEmpty {
                            Text(insights.summary)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        if !insights.suggestions.isEmpty {
                            Text("Last suggested follow-ups")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(insights.suggestions) { suggestion in
                                Text("• \(suggestion.text)")
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .transcript:
                if !model.utterances.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.utterances) { utterance in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(utterance.speaker.displayName)
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        utterance.speaker == .me ? Color.blue : Color.purple
                                    )
                                    .frame(width: 42, alignment: .trailing)
                                Text(utterance.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 100, maxHeight: 220)
    }
}

/// State for the History tab. All operations are reads; playback uses its own
/// player and never touches the capture engine.
@MainActor
final class HistoryViewModel: ObservableObject {
    enum DetailTab: Hashable {
        case summary
        case transcript
    }

    @Published var items: [HistoryItem] = []
    @Published var selected: HistoryItem?
    @Published var utterances: [Utterance] = []
    @Published var insights: InsightsPersistence.InsightsFile?
    @Published var isPlaying = false
    @Published var detailTab: DetailTab = .summary

    private var player: AVAudioPlayer?

    func refresh(root: URL) {
        let scanned = HistoryScanner.scan(root: root)
        items = scanned
        if let selected, !scanned.contains(selected) {
            self.selected = nil
        }
    }

    func select(_ item: HistoryItem) {
        stopPlayback()
        selected = item
        // Prefers the append-only log, so a crashed session still reads fully.
        utterances = InsightsPersistence.readUtterances(in: item.directory)
        insights = InsightsPersistence.readInsights(in: item.directory)
        detailTab = insights != nil ? .summary : .transcript
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard let url = selected?.audioURL else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        isPlaying = player?.isPlaying ?? false
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
