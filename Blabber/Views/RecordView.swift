import SwiftUI

struct RecordView: View {
    @StateObject private var vm = RecorderViewModel()
    @ObservedObject private var videoService = VideoService.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showCancelConfirm = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MeshBackground()

                if geo.size.width > geo.size.height {
                    landscapeLayout(geo: geo)
                } else {
                    portraitLayout(geo: geo)
                }

                if vm.isActive && videoService.cameraAuthorized {
                    cameraPreviewPip(geo: geo)
                }
            }
        }
        .preferredColorScheme(.dark)
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

            VStack(spacing: 28) {
                WaveformView(
                    level: vm.audioLevel,
                    isActive: vm.state == .listening || vm.state == .detecting || vm.state == .speaking,
                    state: vm.state
                )
                sensitivityRow
                    .padding(.horizontal, 28)
            }
            .padding(.top, 36)

            Spacer()

            VStack(spacing: 0) {
                statusLabel
                djButtonRow
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 36)
            }
        }
    }

    // MARK: - Landscape

    @ViewBuilder
    private func landscapeLayout(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            // Left: header + sensitivity + status
            VStack(spacing: 12) {
                headerView
                Spacer()
                sensitivityRow
                    .padding(.horizontal, 8)
                statusLabel
                Spacer()
            }
            .frame(maxWidth: geo.size.width * 0.38)
            .padding(.leading, geo.safeAreaInsets.leading + 24)

            // Center: waveform
            WaveformView(
                level: vm.audioLevel,
                isActive: vm.state == .listening || vm.state == .detecting || vm.state == .speaking,
                state: vm.state
            )
            .frame(maxWidth: .infinity)

            // Right: buttons stacked vertically
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
        VStack(spacing: 5) {
            Text("Blabber")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(white: 0.78)],
                                   startPoint: .top, endPoint: .bottom)
                )
            if vm.isActive {
                Text(vm.sessionTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.isActive)
    }

    private var statusLabel: some View {
        Text(vm.statusText)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(statusColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .glassCard(cornerRadius: 12)
            .animation(.easeInOut, value: vm.state)
    }

    private var sensitivityRow: some View {
        let normalizedThreshold = Double((vm.sensitivityThreshold + 60) / 60)
        let normalizedLevel = Double(vm.audioLevel)
        let aboveThreshold = normalizedLevel > normalizedThreshold

        return VStack(spacing: 6) {
            HStack {
                Text("Sensitivity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("\(Int(vm.sensitivityThreshold)) dB")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(aboveThreshold ? Color.green : Color.blue)
                        .frame(width: g.size.width * normalizedLevel, height: 5)
                        .animation(.easeOut(duration: 0.05), value: normalizedLevel)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 11)
                        .offset(x: g.size.width * normalizedThreshold - 1)
                }
                .frame(height: 11)
            }
            .frame(height: 11)

            Slider(value: $vm.sensitivityThreshold, in: -60 ... -20, step: 1)
                .tint(.white.opacity(0.7))
        }
    }

    // Horizontal row for portrait
    private var djButtonRow: some View {
        HStack(spacing: 0) {
            cancelButton.frame(maxWidth: .infinity)
            startPauseButton.frame(maxWidth: .infinity)
            endButton.frame(maxWidth: .infinity)
        }
    }

    // Vertical column for landscape
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
        Button {
            if vm.state == .idle { vm.startSession() }
            else { vm.togglePause() }
        } label: {
            djButton(icon: vm.startPauseIcon, size: 92,
                     foreground: .white,
                     background: Color.blue.opacity(0.80),
                     glowColor: .blue)
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
                          glowColor: Color? = nil) -> some View {
        ZStack {
            if size >= 88 {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 2)
                    .frame(width: size + 14, height: size + 14)
            }
            Circle()
                .fill(background)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))

            Image(systemName: icon)
                .font(.system(size: size * 0.33, weight: .bold))
                .foregroundColor(foreground)
                .offset(x: icon == "play.fill" ? 3 : 0)
        }
        .shadow(color: (glowColor ?? .clear).opacity(glowColor != nil ? 0.6 : 0),
                radius: 24, x: 0, y: 6)
    }

    private var statusColor: Color {
        switch vm.state {
        case .idle:       return .white.opacity(0.45)
        case .listening:  return .blue
        case .detecting:  return .orange
        case .speaking:   return .green
        case .paused:     return .yellow
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
