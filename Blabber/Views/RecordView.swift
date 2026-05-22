import SwiftUI

struct RecordView: View {
    @StateObject private var vm = RecorderViewModel()
    @ObservedObject private var videoService = VideoService.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showCancelConfirm = false
    @State private var sessionStart: Date? = nil
    @State private var outerRingPulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MeshBackground()

                if geo.size.width > geo.size.height {
                    landscapeLayout(geo: geo)
                    if videoService.cameraAuthorized {
                        cameraPreviewPip(geo: geo)
                    }
                } else {
                    portraitLayout(geo: geo)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: vm.isActive) { _, active in
            sessionStart = active ? .now : nil
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog("Discard this recording?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { vm.cancelSession() }
            Button("Keep Recording", role: .cancel) { }
        }
    }

    // MARK: - Portrait

    @ViewBuilder
    private func portraitLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            headerView
                .padding(.top, geo.safeAreaInsets.top + 16)

            Spacer(minLength: 0)

            bigStatusView

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                sensitivityRow
                    .padding(.horizontal, 28)

                djButtonRow
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 36)
            }
        }
    }

    // MARK: - Landscape

    @ViewBuilder
    private func landscapeLayout(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                headerView
                Spacer()
                bigStatusView
                Spacer()
                sensitivityRow
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: geo.size.width * 0.5)
            .padding(.leading, geo.safeAreaInsets.leading + 24)

            VStack(spacing: 20) {
                Spacer()
                djButtonColumn
                Spacer()
            }
            .padding(.trailing, geo.safeAreaInsets.trailing + 28)
        }
        .padding(.vertical, 16)
    }

    // MARK: - Camera Preview PiP

    @ViewBuilder
    private func cameraPreviewPip(geo: GeometryProxy) -> some View {
        let isLandscape = geo.size.width > geo.size.height
        VStack {
            HStack {
                Spacer()
                CameraPreviewView(session: videoService.captureSession)
                    .frame(width: 72, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .padding(.top, geo.safeAreaInsets.top + (isLandscape ? 10 : 6))
            .padding(.trailing, (isLandscape ? geo.safeAreaInsets.trailing : 0) + 16)
            Spacer()
        }
    }

    // MARK: - Sub-views

    private var headerView: some View {
        let iconSize: CGFloat = 100
        let showCamera = videoService.cameraAuthorized

        return VStack(spacing: 10) {
            ZStack {
                Image("AppLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: iconSize, height: iconSize)

                if showCamera {
                    CameraPreviewView(session: videoService.captureSession)
                        .frame(width: iconSize, height: iconSize)
                        .transition(.opacity)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2232, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: iconSize * 0.2232, style: .continuous)
                    .stroke(Color.white.opacity(showCamera ? 0.22 : 0), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.3), value: showCamera)

            if vm.isActive {
                HStack(spacing: 8) {
                    RecDot()
                    TimelineView(.periodic(from: sessionStart ?? .now, by: 1)) { tl in
                        let elapsed = sessionStart.map { Int(tl.date.timeIntervalSince($0)) } ?? 0
                        Text(formatElapsed(elapsed))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.isActive)
    }

    private var bigStatusView: some View {
        let color = statusColor
        return Text(statusDisplayText)
            .font(.system(size: 54, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.75), radius: 28, x: 0, y: 0)
            .shadow(color: color.opacity(0.35), radius: 56, x: 0, y: 0)
            .animation(.easeInOut(duration: 0.2), value: vm.state)
    }

    private var statusDisplayText: String {
        switch vm.state {
        case .idle:      return "Ready"
        case .listening: return "Listening"
        case .detecting: return "Detecting"
        case .speaking:  return "Recording"
        case .paused:    return "Paused"
        }
    }

    private var sensitivityRow: some View {
        let normalizedThreshold = CGFloat((vm.sensitivityThreshold + 60) / 60)
        let normalizedLevel = CGFloat(vm.audioLevel)
        let aboveThreshold = normalizedLevel > normalizedThreshold

        return VStack(spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Mic Sensitivity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text("\(Int(vm.sensitivityThreshold)) dB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }

            // Level meter + threshold marker overlaid on the slider track
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                        .offset(y: 16) // align with slider track center

                    // Live level fill
                    Capsule()
                        .fill(aboveThreshold ? Color.green.opacity(0.55) : Color.white.opacity(0.18))
                        .frame(width: g.size.width * normalizedLevel, height: 4)
                        .offset(y: 16)
                        .animation(.easeOut(duration: 0.05), value: normalizedLevel)

                    // Threshold tick mark
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: 18)
                        .offset(x: g.size.width * normalizedThreshold - 1, y: 7)

                    Slider(value: $vm.sensitivityThreshold, in: -60 ... -20, step: 1)
                        .tint(.clear)
                }
            }
            .frame(height: 32)
        }
    }

    private var djButtonRow: some View {
        HStack(spacing: 0) {
            cancelButton.frame(maxWidth: .infinity)
            startPauseButton.frame(maxWidth: .infinity)
            endButton.frame(maxWidth: .infinity)
        }
    }

    private var djButtonColumn: some View {
        VStack(spacing: 16) {
            cancelButton
            startPauseButton
            endButton
        }
    }

    private var cancelButton: some View {
        Button {
            if vm.hasSpeech { showCancelConfirm = true } else { vm.cancelSession() }
        } label: {
            djButton(icon: "xmark", size: 60, foreground: .red,
                     background: Color.white.opacity(0.07))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!vm.isActive)
        .opacity(vm.isActive ? 1.0 : 0.22)
    }

    private var startPauseButton: some View {
        let isIdle = vm.state == .idle
        let icon: String = isIdle ? "record.circle.fill" : vm.startPauseIcon
        let bg: Color = isIdle ? Color.red.opacity(0.82) : Color.white.opacity(0.12)
        let glow: Color = isIdle ? .red : .clear

        return Button {
            if vm.state == .idle { vm.startSession() }
            else { vm.togglePause() }
        } label: {
            djButton(icon: icon, size: 92, foreground: .white, background: bg, glowColor: glow)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var endButton: some View {
        Button { vm.endSession() } label: {
            djButton(icon: "stop.fill", size: 60, foreground: .green,
                     background: Color.white.opacity(0.07))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!vm.isActive)
        .opacity(vm.hasSpeech ? 1.0 : 0.22)
    }

    @ViewBuilder
    private func djButton(icon: String, size: CGFloat,
                          foreground: Color, background: Color,
                          glowColor: Color? = nil,
                          glowRadius: CGFloat = 22,
                          glowOpacity: Double = 0.55) -> some View {
        ZStack {
            // Outer accent ring (large buttons only)
            if size >= 88 {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.white.opacity(0.18), .clear, .white.opacity(0.08), .clear],
                            center: .center
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: size + 16, height: size + 16)
            }

            // Main circle
            Circle()
                .fill(background)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

            Image(systemName: icon)
                .font(.system(size: size * 0.33, weight: .bold))
                .foregroundColor(foreground)
                .offset(x: icon == "play.fill" ? 3 : 0)
        }
        .shadow(
            color: (glowColor ?? .clear).opacity(glowColor != nil ? glowOpacity : 0),
            radius: glowRadius, x: 0, y: 4
        )
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch vm.state {
        case .idle:       return .white.opacity(0.4)
        case .listening:  return Color(red: 0.3, green: 0.6, blue: 1.0)
        case .detecting:  return .orange
        case .speaking:   return .green
        case .paused:     return .yellow
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Supporting views

private struct RecDot: View {
    @State private var visible = true

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .shadow(color: .red.opacity(0.7), radius: 4)
            .opacity(visible ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.87 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
