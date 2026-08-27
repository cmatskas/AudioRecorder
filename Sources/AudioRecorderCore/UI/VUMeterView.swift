import SwiftUI

/// A vertical segmented LED-style meter bar with a decaying peak-hold marker.
struct VUMeterBar: View {
    /// Level 0...1.
    var level: Float
    @State private var peak: Float = 0

    private static let segmentCount = 20
    /// Zone boundaries in segment indices: green below, yellow, red at top.
    private static let yellowStart = 13
    private static let redStart = 17

    private func segmentColor(_ index: Int, lit: Bool) -> Color {
        let base: Color = index >= Self.redStart ? .red
            : index >= Self.yellowStart ? .yellow
            : .green
        return lit ? base : base.opacity(0.12)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let gap: CGFloat = 2
            let segmentHeight = (height - gap * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount)
            let litCount = Int((CGFloat(min(1, level)) * CGFloat(Self.segmentCount)).rounded())
            let peakIndex = min(Self.segmentCount - 1, Int(CGFloat(min(1, peak)) * CGFloat(Self.segmentCount)))

            VStack(spacing: gap) {
                ForEach((0..<Self.segmentCount).reversed(), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(segmentColor(index, lit: index < litCount || (index == peakIndex && peak > 0.02)))
                        .frame(height: segmentHeight)
                }
            }
        }
        .onChange(of: level) { _, newLevel in
            peak = max(newLevel, peak - 0.012)
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// A stereo LED meter pair with a dB readout.
struct StereoVUMeter: View {
    var title: String
    /// Raw RMS levels 0...1 for left and right.
    var left: Float
    var right: Float
    var enabled: Bool

    private var averageRMS: Float { (left + right) / 2 }

    private var dbText: String {
        guard enabled, averageRMS > 0.00001 else { return "-∞ dB" }
        let db = max(-60, min(0, 20 * log10(averageRMS)))
        return String(format: "%.0f dB", db)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                VUMeterBar(level: enabled ? min(1, left * 5) : 0)
                    .frame(width: 14)
                VUMeterBar(level: enabled ? min(1, right * 5) : 0)
                    .frame(width: 14)
            }
            .frame(height: 130)
            Text(dbText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 50)
        }
        .opacity(enabled ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level")
        .accessibilityValue(dbText)
    }
}
