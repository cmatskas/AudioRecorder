import SwiftUI

/// A vertical VU bar with a decaying peak indicator.
struct VUMeterBar: View {
    /// Level 0...1.
    var level: Float
    @State private var peak: Float = 0

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color(white: 0.15))
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0),
                                .init(color: .green, location: 0.6),
                                .init(color: .yellow, location: 0.8),
                                .init(color: .red, location: 1),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: height * CGFloat(min(1, level)))
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 2)
                    .offset(y: -height * CGFloat(min(1, peak)) + 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onChange(of: level) { _, newLevel in
            peak = max(newLevel, peak - 0.01)
        }
    }
}

/// A stereo VU meter pair with a dB readout.
struct StereoVUMeter: View {
    var title: String
    /// Raw RMS levels 0...1 for left and right.
    var left: Float
    var right: Float
    var enabled: Bool

    private var averageRMS: Float { (left + right) / 2 }

    private var dbText: String {
        guard enabled, averageRMS > 0 else { return "-∞ dB" }
        let db = max(-60, min(0, 20 * log10(averageRMS)))
        return String(format: "%.1f dB", db)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                VUMeterBar(level: enabled ? min(1, left * 5) : 0)
                VUMeterBar(level: enabled ? min(1, right * 5) : 0)
            }
            .frame(width: 44, height: 120)
            Text(dbText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level")
        .accessibilityValue(dbText)
    }
}
