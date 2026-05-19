import SwiftUI

struct WaveformView: View {
    var level: Float
    var isActive: Bool
    var state: RecordingState

    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 30)

    private let barCount = 30

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - 48
            let spacing = max(2, (available - CGFloat(barCount) * 3) / CGFloat(barCount - 1))

            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor.opacity(isActive ? 0.85 : 0.25))
                        .frame(width: 3, height: barHeights[i])
                        .animation(.easeOut(duration: 0.08), value: barHeights[i])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        }
        .onChange(of: level) { _, newLevel in
            guard isActive else { return }
            let center = Double(barCount) / 2
            for i in 0..<barCount {
                let dist = abs(Double(i) - center) / center
                let h = CGFloat(newLevel) * 52 * CGFloat(pow(1 - dist, 1.4))
                barHeights[i] = max(3, h * CGFloat.random(in: 0.6...1.4))
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                withAnimation(.easeOut(duration: 0.4)) {
                    for i in 0..<barCount { barHeights[i] = 3 }
                }
            }
        }
    }

    private var barColor: Color {
        switch state {
        case .speaking:   return .green
        case .detecting:  return .orange
        case .listening:  return Color(red: 0.3, green: 0.6, blue: 1.0)
        case .paused:     return .yellow
        case .idle:       return .white
        }
    }
}
