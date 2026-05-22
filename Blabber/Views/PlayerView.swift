import AVFoundation
import AVKit
import Photos
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
    @State private var savedToPhotos: Bool = false

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
            ZStack {
                dragHandle
                if UIDevice.current.userInterfaceIdiom == .pad {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                        .padding(.trailing, 20)
                    }
                }
            }
            .padding(.top, 12)

            titleSection
                .padding(.top, 16)
                .padding(.horizontal, 28)

            waveformDecor
                .frame(maxHeight: geo.size.height * (UIDevice.current.userInterfaceIdiom == .pad ? 0.78 : 0.58))
                .padding(.top, 16)
                .padding(.horizontal, 16)

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

            HStack(alignment: .center) {
                // Share
                let shareURL = vm.hasVideo ? recording.videoFileURL : recording.fileURL
                ShareLink(item: shareURL, preview: SharePreview(recording.title)) {
                    actionIcon("square.and.arrow.up")
                }

                Spacer()

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

                Spacer()

                // Save to Photos (video only)
                if vm.hasVideo {
                    Button { saveToPhotos() } label: {
                        actionIcon(savedToPhotos ? "checkmark" : "square.and.arrow.down")
                            .foregroundColor(savedToPhotos ? .green : .white)
                    }
                } else {
                    actionIcon("square.and.arrow.up").hidden()
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .glassCard(cornerRadius: 22)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t)/60, Int(t)%60)
    }

    private func actionIcon(_ name: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 48, height: 48)
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func saveToPhotos() {
        let url = recording.videoFileURL
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                if success {
                    DispatchQueue.main.async { savedToPhotos = true }
                }
            }
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
