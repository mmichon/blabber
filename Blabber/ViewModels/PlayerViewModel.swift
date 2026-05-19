import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var hasVideo = false
    @Published var errorMessage: String?

    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: Any?

    func load(_ recording: Recording) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = "Cannot activate audio session: \(error.localizedDescription)"
            return
        }

        // Check disk directly — recording.hasVideo may be stale if video finished
        // processing after the list snapshot was taken.
        let videoExists = FileManager.default.fileExists(atPath: recording.videoFileURL.path)
        hasVideo = videoExists
        let url = videoExists ? recording.videoFileURL : recording.fileURL
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }

        Task {
            let d = try? await item.asset.load(.duration)
            duration = d.map { CMTimeGetSeconds($0) } ?? 0
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        player?.seek(to: CMTimeMakeWithSeconds(time, preferredTimescale: 600))
        currentTime = time
    }

    func stop() {
        player?.pause()
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    deinit {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
