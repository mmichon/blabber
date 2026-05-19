import SwiftUI

struct WaveformView: View {
    var level: Float
    var isActive: Bool
    var state: RecordingState

    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 50)
    @State private var idlePhase: Double = 0
    @State private var idleTimer: Timer?

    private let barCount = 50
    private let maxBarHeight: CGFloat = 52
    private let barWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Single subtle ring — just enough to indicate state
                Circle()
                    .stroke(barColor.opacity(isActive ? 0.18 : 0.06), lineWidth: 1)
                    .frame(
                        width: min(geo.size.width, geo.size.height) * 0.62,
                        height: min(geo.size.width, geo.size.height) * 0.62
                    )

                // Mirrored waveform
                VStack(spacing: 0) {
                    waveformBars(geo: geo, flipped: true)
                        .frame(height: maxBarHeight)

                    Rectangle()
                        .fill(barColor.opacity(0.2))
                        .frame(height: 1)

                    waveformBars(geo: geo, flipped: false)
                        .frame(height: maxBarHeight)
                }
                .padding(.horizontal, 24)
                .opacity(isActive ? 1.0 : 0.3)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            startIdleBreathing()
        }
        .onDisappear {
            idleTimer?.invalidate()
            idleTimer = nil
        }
        .onChange(of: level) { _, newLevel in
            if isActive { updateBars(level: newLevel) }
        }
        .onChange(of: isActive) { _, active in
            if !active { resetBars() }
        }
    }

    // MARK: - Bar helpers

    @ViewBuilder
    private func waveformBars(geo: GeometryProxy, flipped: Bool) -> some View {
        let padding: CGFloat = 48
        let available = geo.size.width - padding
        let spacing = max(1.5, (available - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))

        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                VStack(spacing: 0) {
                    if !flipped { Spacer(minLength: 0) }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barGradient(flipped: flipped))
                        .frame(width: barWidth, height: barHeights[i])
                        .animation(.easeOut(duration: 0.07), value: barHeights[i])
                    if flipped { Spacer(minLength: 0) }
                }
                .frame(height: maxBarHeight)
            }
        }
    }

    private func barGradient(flipped: Bool) -> LinearGradient {
        // Both halves fade to transparent at the far edge (away from center)
        if flipped {
            LinearGradient(colors: [barColor, barColor.opacity(0.06)],
                           startPoint: .bottom, endPoint: .top)
        } else {
            LinearGradient(colors: [barColor.opacity(0.06), barColor],
                           startPoint: .bottom, endPoint: .top)
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

    // MARK: - Animation

    private func updateBars(level: Float) {
        let center = Double(barCount) / 2.0
        for i in 0..<barCount {
            let dist = abs(Double(i) - center) / center
            let envelope = pow(1.0 - dist, 1.6)
            let noise = CGFloat.random(in: 0.45...1.55)
            barHeights[i] = max(3, CGFloat(level) * maxBarHeight * CGFloat(envelope) * noise)
        }
    }

    private func resetBars() {
        withAnimation(.easeOut(duration: 0.3)) {
            for i in 0..<barCount { barHeights[i] = 3 }
        }
    }

    private func startIdleBreathing() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            Task { @MainActor in
                guard !self.isActive else { return }
                self.idlePhase += 0.04
                let t = self.idlePhase
                let breathe = sin(t * 0.28) * 0.2 + 0.5  // gentle, slow
                for i in 0..<self.barCount {
                    let x = Double(i) / Double(self.barCount)
                    let wave = sin(x * .pi * 2.5 + t) * 0.5 + 0.5
                    self.barHeights[i] = max(3, CGFloat(wave * breathe) * 6 + 3)
                }
            }
        }
    }
}
