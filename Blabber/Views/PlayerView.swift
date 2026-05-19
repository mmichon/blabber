import AVFoundation
import AVKit
import SwiftUI

private struct VideoPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> _PlayerUIView {
        let view = _PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: _PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    class _PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct PlayerView: View {
    let recording: Recording
    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MeshBackground()

                if geo.size.width > geo.size.height {
                    landscapeLayout(geo: geo)
                } else {
                    portraitLayout(geo: geo)
                }
            }
        }
        .onAppear {
            vm.load(recording)
            vm.togglePlayPause()
        }
        .onDisappear { vm.stop() }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Portrait

    @ViewBuilder
    private func portraitLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            dragHandle
                .padding(.top, 12)

            titleSection
                .padding(.top, 20)
                .padding(.horizontal, 28)

            Spacer()

            waveformDecor
                .frame(maxHeight: geo.size.height * 0.38)
                .padding(.vertical, 16)

            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controlsSection
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Landscape

    @ViewBuilder
    private func landscapeLayout(geo: GeometryProxy) -> some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(spacing: 16) {
                titleSection
                waveformDecor
            }
            .frame(maxWidth: geo.size.width * 0.45)
            .padding(.leading, geo.safeAreaInsets.leading + 24)

            controlsSection
                .frame(maxWidth: .infinity)
                .padding(.trailing, geo.safeAreaInsets.trailing + 24)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Sub-views

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.25))
            .frame(width: 40, height: 4)
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text(recording.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(white: 0.80)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .multilineTextAlignment(.center)

            Text(recording.date.formatted(date: .long, time: .shortened))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    @ViewBuilder
    private var waveformDecor: some View {
        if vm.hasVideo, let player = vm.player {
            VideoPlayerLayerView(player: player)
                .aspectRatio(9/16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue.opacity(vm.isPlaying ? 0.55 : 0.15),
                                 Color.purple.opacity(vm.isPlaying ? 0.40 : 0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .animation(.easeInOut(duration: 0.5), value: vm.isPlaying)
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 14) {
            // Scrubber
            Slider(
                value: Binding(get: { vm.currentTime }, set: { vm.seek(to: $0) }),
                in: 0...max(vm.duration, 0.001)
            )
            .tint(.blue)

            HStack {
                Text(timeString(vm.currentTime))
                Spacer()
                Text(timeString(vm.duration))
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.45))

            // Play/Pause
            Button { vm.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color.blue, Color.blue.opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 76, height: 76)
                        .shadow(color: .blue.opacity(0.55), radius: 22, x: 0, y: 6)

                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .offset(x: vm.isPlaying ? 0 : 3)
                }
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 6)
        }
        .padding(20)
        .glassCard(cornerRadius: 22)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t)/60, Int(t)%60)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
