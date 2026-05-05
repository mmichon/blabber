import SwiftUI

struct WaveformView: View {
    var level: Float
    var isActive: Bool
    var state: RecordingState

    @State private var pulseScale: CGFloat = 1.0
    @State private var barHeights: [CGFloat] = Array(repeating: 4, count: 20)
    @State private var idleTimer: Timer?

    private let barCount = 20

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(ringColor(for: i), lineWidth: 1.5)
                    .frame(width: 160 + CGFloat(i) * 28,
                           height: 160 + CGFloat(i) * 28)
                    .scaleEffect(pulseScale)
                    .opacity(isActive ? (0.6 - Double(i) * 0.15) : 0.08)
                    .animation(
                        .easeInOut(duration: 1.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.25),
                        value: pulseScale
                    )
            }

            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: 3, height: barHeights[i])
                        .animation(.easeInOut(duration: 0.08), value: barHeights[i])
                }
            }
            .frame(width: 100, height: 60)
            .opacity(isActive ? 1.0 : 0.2)
        }
        .onAppear {
            pulseScale = 1.1
            startIdleBreathing()
        }
        .onDisappear {
            idleTimer?.invalidate()
            idleTimer = nil
        }
        .onChange(of: level) { _, newLevel in
            if isActive {
                updateBars(level: newLevel)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                resetBars()
            }
        }
    }

    private var barColor: Color {
        switch state {
        case .speaking:   return .green
        case .detecting:  return .orange
        case .listening:  return .blue
        case .paused:     return .yellow
        case .idle:       return Color.white.opacity(0.25)
        }
    }

    private func ringColor(for index: Int) -> Color {
        switch state {
        case .speaking:   return Color.green.opacity(0.5 - Double(index) * 0.1)
        case .detecting:  return Color.orange.opacity(0.5 - Double(index) * 0.1)
        case .listening:  return Color.blue.opacity(0.5 - Double(index) * 0.1)
        case .paused:     return Color.yellow.opacity(0.4 - Double(index) * 0.1)
        case .idle:       return Color.white.opacity(0.15 - Double(index) * 0.03)
        }
    }

    private func updateBars(level: Float) {
        let centerHeight = CGFloat(level) * 52 + 4
        for i in 0..<barCount {
            let distance = abs(i - barCount / 2)
            let factor = 1.0 - Double(distance) / Double(barCount / 2)
            let noise = CGFloat.random(in: 0.65...1.35)
            barHeights[i] = max(4, centerHeight * CGFloat(factor) * noise)
        }
    }

    private func resetBars() {
        for i in 0..<barCount { barHeights[i] = 4 }
    }

    private func startIdleBreathing() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            Task { @MainActor in
                if !self.isActive {
                    for i in 0..<self.barCount {
                        self.barHeights[i] = CGFloat.random(in: 3...8)
                    }
                }
            }
        }
    }
}
