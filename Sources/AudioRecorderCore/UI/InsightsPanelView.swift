import SwiftUI

/// Content of the pop-out Live Insights window: live transcript for
/// reassurance, suggested follow-ups as the hero, running summary below.
/// Any pipeline failure renders as a yellow "recording unaffected" strip —
/// this window can worry the user about insights, never about audio.
public struct InsightsPanelView: View {
    @EnvironmentObject private var state: AppState
    /// Passed in and observed directly rather than reached through
    /// `AppState`: AppState holds `insightsModel` as a plain property, so
    /// mutations to it do not notify AppState's observers and the panel would
    /// never refresh during a recording (insights would appear only on stop).
    /// Taking it as an explicit dependency makes that mistake a compile error.
    @ObservedObject private var insights: InsightsModel

    public init(insights: InsightsModel) {
        self.insights = insights
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            statusStrip
            Divider()
            transcriptSection
            Divider()
            suggestionsSection
            summarySection
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 480, idealHeight: 640)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("Live Insights")
                .font(.headline)
            Spacer()
            statusBadge
            if state.insightsSessionActive {
                Button {
                    state.toggleInsightsPaused()
                } label: {
                    Image(systemName: state.insightsPaused ? "play.fill" : "pause.fill")
                }
                .help(
                    state.insightsPaused
                        ? "Resume streaming audio for analysis"
                        : "Pause — stops sending audio to AWS; recording continues"
                )
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch insights.status {
        case .idle, .stopped:
            Text("Ended").font(.caption).foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .live:
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.green)
        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .degraded:
            Label("Degraded", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if case let .degraded(message) = insights.status {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.yellow.opacity(0.15))
        } else if state.insightsPaused {
            Text("Paused — your audio is replaced with silence; nothing said is sent to AWS. Recording continues.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if insights.utterances.isEmpty {
                        Text("Waiting for speech…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(insights.utterances) { utterance in
                        utteranceRow(utterance)
                            .id(utterance.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: insights.utterances.count) {
                if let last = insights.utterances.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minHeight: 140)
    }

    private func utteranceRow(_ utterance: Utterance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(utterance.speaker.displayName)
                .font(.caption.bold())
                .foregroundStyle(utterance.speaker == .me ? Color.blue : Color.purple)
                .frame(width: 42, alignment: .trailing)
            Text(utterance.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Suggestions (the hero)

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggested follow-ups", systemImage: "lightbulb.fill")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if insights.suggestions.isEmpty {
                Text("Suggestions appear as the conversation develops.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(insights.suggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.purple)
                        Text(suggestion.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: insights.suggestions)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.purple.opacity(0.06))
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if !insights.summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Summary", systemImage: "doc.text")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let updated = insights.summaryUpdatedAt {
                        Text("updated \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ScrollView {
                    Text(insights.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .padding(12)
        }
    }
}
