import AVFoundation
import Foundation

enum VideoProcessingError: Error {
    case missingTracks
    case compositionFailed
    case exportFailed
}

@MainActor
final class VideoService: NSObject, ObservableObject {
    static let shared = VideoService()

    @Published var cameraAuthorized = false

    // nonisolated(unsafe) so CameraPreviewView and sessionQueue can access without actor hop
    nonisolated(unsafe) let captureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.blabber.video.session")

    // Persistent output — configured once, reused for every recording.
    private nonisolated(unsafe) var movieOutput: AVCaptureMovieFileOutput?
    private nonisolated(unsafe) var videoRecordingStartDate: Date?
    private var recordingFinishedContinuation: CheckedContinuation<URL?, Never>?

    // Tracks whether didStartRecordingTo has fired for the in-flight recording.
    // Cleared at startRecording, set true in the start delegate. Used by the finish
    // delegate to distinguish "started then stopped" from "rejected at start".
    private nonisolated(unsafe) var didStartRecordingFired = false
    private nonisolated(unsafe) var currentRecordingURL: URL?
    private nonisolated(unsafe) var startRecordingRetryCount = 0
    private static let maxStartRecordingRetries = 2

    private override init() { super.init() }

    // MARK: - Authorization

    func checkAndRequestAuthorization() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            cameraAuthorized = false
        }
        if cameraAuthorized {
            sessionQueue.async { [weak self] in self?.configurePersistentSession() }
        }
    }

    // MARK: - Persistent session setup (called once after authorization)
    //
    // The capture session stays running for the lifetime of the app so that:
    //   • 2x zoom is set once and never resets between recordings.
    //   • AVCaptureMovieFileOutput.startRecording / stopRecording can be called
    //     repeatedly on the same output without rebuilding inputs/outputs.

    private nonisolated func configurePersistentSession() {
        guard movieOutput == nil else {
            appendLog("[VideoService] configurePersistentSession: already configured")
            return
        }

        captureSession.beginConfiguration()
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            appendLog("[VideoService] configurePersistentSession: failed to create camera input")
            return
        }
        captureSession.addInput(input)

        let output = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            appendLog("[VideoService] configurePersistentSession: failed to add output")
            return
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        // Observers must be installed before startRunning so we don't miss an early
        // wasInterruptedNotification (e.g. another client owning the camera at app launch).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleSessionWasInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: captureSession)
        nc.addObserver(self, selector: #selector(handleSessionInterruptionEnded(_:)),
                       name: AVCaptureSession.interruptionEndedNotification, object: captureSession)
        nc.addObserver(self, selector: #selector(handleSessionRuntimeError(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: captureSession)

        captureSession.startRunning()

        // Disable audio track — audio comes from AVAudioEngine with voice processing.
        // (This is a no-op when there is no audio input in the session, but kept for safety.)
        output.connection(with: .audio)?.isEnabled = false

        // Bake horizontal flip into the recorded file (front camera records unmirrored by default).
        if let videoConn = output.connection(with: .video) {
            if videoConn.isVideoMirroringSupported {
                videoConn.isVideoMirrored = true
            }
            // Anti-shake: use the most aggressive stabilization for bumpy environments.
            if videoConn.isVideoStabilizationSupported {
                videoConn.preferredVideoStabilizationMode = .cinematicExtended
                appendLog("[VideoService] video stabilization set to cinematicExtended")
            }
        }

        // 2x zoom via hardware sensor crop — set once here, persists for all recordings.
        if (try? camera.lockForConfiguration()) != nil {
            camera.videoZoomFactor = min(2.0, camera.activeFormat.videoMaxZoomFactor)
            camera.unlockForConfiguration()
        }

        movieOutput = output
        appendLog("[VideoService] configurePersistentSession: session running, zoom set")
    }

    // MARK: - Recording Lifecycle

    func startSession(tempURL: URL) {
        guard cameraAuthorized else {
            appendLog("[VideoService] startSession skipped — not authorized")
            return
        }
        videoRecordingStartDate = nil
        appendLog("[VideoService] startSession → \(tempURL.lastPathComponent)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let output = self.movieOutput else {
                appendLog("[VideoService] startSession: output not ready")
                return
            }
            guard !output.isRecording else {
                appendLog("[VideoService] startSession: output already recording, skipped")
                return
            }
            // AVCaptureSession can stop running due to system interruptions
            // (FaceID, audio session conflicts, brief backgrounding, another client
            // grabbing the camera). startRecording on a stopped session fails
            // immediately with "Cannot Record" and no didStartRecordingTo callback.
            if !self.captureSession.isRunning {
                appendLog("[VideoService] startSession: session not running, restarting")
                self.captureSession.startRunning()
                appendLog("[VideoService] startSession: session restart returned, isRunning=\(self.captureSession.isRunning)")
            }
            // Even with isRunning=true the session may be mid-interruption — startRecording
            // will then fail with "Cannot Record" and no didStartRecordingTo. Brief poll for
            // the interruption to clear before recording.
            var waited = 0.0
            while self.captureSession.isInterrupted, waited < 1.0 {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
            let audio = AVAudioSession.sharedInstance()
            appendLog("[VideoService] startSession: pre-record state isRunning=\(self.captureSession.isRunning) isInterrupted=\(self.captureSession.isInterrupted) waitedForInterruption=\(waited)s audioCat=\(audio.category.rawValue) audioMode=\(audio.mode.rawValue) audioRoute=\(AudioService.routeSummary())")
            guard self.captureSession.isRunning, !self.captureSession.isInterrupted else {
                appendLog("[VideoService] startSession: aborting — session not in a recordable state")
                return
            }
            self.didStartRecordingFired = false
            self.currentRecordingURL = tempURL
            self.startRecordingRetryCount = 0
            output.startRecording(to: tempURL, recordingDelegate: self)
        }
    }

    func stopSession() async -> URL? {
        guard let output = movieOutput else {
            appendLog("[VideoService] stopSession: no output")
            return nil
        }
        return await withCheckedContinuation { continuation in
            recordingFinishedContinuation = continuation
            sessionQueue.async { [weak self] in
                guard let self else {
                    Task { @MainActor in continuation.resume(returning: nil) }
                    return
                }
                if output.isRecording {
                    output.stopRecording()
                    // delegate will resume the continuation
                } else {
                    // Already stopped — no delegate will fire; resolve now.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        recordingFinishedContinuation?.resume(returning: nil)
                        recordingFinishedContinuation = nil
                    }
                }
            }
        }
    }

    func cancelSession() {
        // Resolve any pending continuation immediately so stopSession() callers get nil.
        recordingFinishedContinuation?.resume(returning: nil)
        recordingFinishedContinuation = nil
        videoRecordingStartDate = nil
        sessionQueue.async { [weak self] in
            guard let self, let output = self.movieOutput, output.isRecording else { return }
            output.stopRecording()
            // didFinishRecordingTo will fire but recordingFinishedContinuation is nil — no-op.
        }
    }

    // MARK: - Session Interruption Handling

    @objc private nonisolated func handleSessionWasInterrupted(_ notification: Notification) {
        let reasonRaw = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
        let reasonName: String
        switch AVCaptureSession.InterruptionReason(rawValue: reasonRaw) {
        case .videoDeviceNotAvailableInBackground: reasonName = "notAvailableInBackground"
        case .audioDeviceInUseByAnotherClient:    reasonName = "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient:    reasonName = "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: reasonName = "notAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure: reasonName = "notAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated: reasonName = "sensitiveContentMitigationActivated"
        default: reasonName = "unknown(\(reasonRaw))"
        }
        appendLog("[VideoService] session wasInterrupted reason=\(reasonName)")
    }

    @objc private nonisolated func handleSessionInterruptionEnded(_ notification: Notification) {
        appendLog("[VideoService] session interruptionEnded — restarting if needed")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                appendLog("[VideoService] interruptionEnded: restart returned, isRunning=\(self.captureSession.isRunning)")
            }
        }
    }

    @objc private nonisolated func handleSessionRuntimeError(_ notification: Notification) {
        let err = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        appendLog("[VideoService] session runtimeError: \(err?.localizedDescription ?? "<no error>")")
        // Try once to recover. AVError code .mediaServicesWereReset is the typical recoverable case.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                appendLog("[VideoService] runtimeError: restart returned, isRunning=\(self.captureSession.isRunning)")
            }
        }
    }

    // MARK: - Post-processing

    nonisolated private func appendLog(_ msg: String) {
        let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("video_log.txt")
        let line = msg + "\n"
        print(line, terminator: "")
        if var existing = try? String(contentsOf: logURL) {
            existing += line
            try? existing.write(to: logURL, atomically: true, encoding: .utf8)
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func processAndSave(
        tempVideoURL: URL,
        audioURL: URL,
        segments: [SpeakingSegment],
        sessionStart: Date,
        sampleRate: Double,
        outputURL: URL
    ) async throws {
        let capturedVideoStart = videoRecordingStartDate
        let videoStartOffset = capturedVideoStart.map { $0.timeIntervalSince(sessionStart) } ?? 0
        appendLog("[VideoService] processAndSave start — segments: \(segments.count), sampleRate: \(sampleRate), videoStartOffset from sessionStart: \(videoStartOffset)s")
        appendLog("[VideoService] tempVideoURL exists: \(FileManager.default.fileExists(atPath: tempVideoURL.path))")
        appendLog("[VideoService] audioURL exists: \(FileManager.default.fileExists(atPath: audioURL.path))")

        let videoAsset = AVURLAsset(url: tempVideoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        appendLog("[VideoService] videoTracks: \(videoTracks.count), audioTracks: \(audioTracks.count)")

        guard let videoTrack = videoTracks.first,
              let audioTrack = audioTracks.first
        else {
            try? FileManager.default.removeItem(at: tempVideoURL)
            throw VideoProcessingError.missingTracks
        }

        let videoAssetDuration = try await videoAsset.load(.duration)
        let audioAssetDuration = try await audioAsset.load(.duration)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let assetEndSec = CMTimeGetSeconds(videoAssetDuration)
        let audioAssetEndSec = CMTimeGetSeconds(audioAssetDuration)
        appendLog("[VideoService] video asset duration: \(assetEndSec)s, audio asset duration: \(audioAssetEndSec)s")

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            try? FileManager.default.removeItem(at: tempVideoURL)
            throw VideoProcessingError.compositionFailed
        }

        compVideo.preferredTransform = preferredTransform

        var insertTime = CMTime.zero

        for (i, segment) in segments.enumerated() {
            guard let segEnd = segment.end else {
                appendLog("[VideoService] segment \(i): no end, skipping")
                continue
            }

            var audioStartSec = Double(segment.audioStartFrame) / sampleRate
            // Clamp to actual encoded file duration — AAC encoder delay means the M4A
            // container reports slightly fewer frames than writtenFrames counted.
            let audioEndSec = min(Double(segment.audioEndFrame) / sampleRate, audioAssetEndSec)

            // Use the moment the video file actually started recording (not sessionStart,
            // which is set before camera initialization and can be 200–500 ms earlier).
            let videoRef = capturedVideoStart ?? sessionStart
            let videoStartRaw = segment.videoStart.timeIntervalSince(videoRef)
            // Preroll may extend before the video file started — trim audio to match so both
            // tracks start at the same real-world moment.
            if videoStartRaw < 0 {
                audioStartSec = min(audioStartSec - videoStartRaw, audioEndSec)
            }
            let videoStartSec = max(0, videoStartRaw)
            let videoEndSec = segEnd.timeIntervalSince(videoRef)

            appendLog("[VideoService] segment \(i): audio [\(audioStartSec)s – \(audioEndSec)s], audioFrames [\(segment.audioStartFrame) – \(segment.audioEndFrame)], assetEnd: \(audioAssetEndSec)s")

            guard audioEndSec > audioStartSec else {
                appendLog("[VideoService] segment \(i): zero audio duration, skipping")
                continue
            }

            let audioStart = CMTimeMakeWithSeconds(audioStartSec, preferredTimescale: 44100)
            let audioDur = CMTimeMakeWithSeconds(audioEndSec - audioStartSec, preferredTimescale: 44100)
            let clampedStart = min(videoStartSec, assetEndSec)
            let clampedEnd = min(videoEndSec, assetEndSec)
            appendLog("[VideoService] segment \(i): video [\(videoStartSec)s – \(videoEndSec)s], clamped [\(clampedStart)s – \(clampedEnd)s]")

            if clampedEnd > clampedStart {
                let vStart = CMTimeMakeWithSeconds(clampedStart, preferredTimescale: 600)
                let vDur = CMTimeMakeWithSeconds(clampedEnd - clampedStart, preferredTimescale: 600)
                do {
                    try compVideo.insertTimeRange(CMTimeRange(start: vStart, duration: vDur),
                                                  of: videoTrack, at: insertTime)
                    appendLog("[VideoService] segment \(i): video inserted OK")
                } catch {
                    appendLog("[VideoService] segment \(i): video insert failed: \(error)")
                }
            } else {
                appendLog("[VideoService] segment \(i): video range empty, skipping video insert")
            }

            do {
                try compAudio.insertTimeRange(CMTimeRange(start: audioStart, duration: audioDur),
                                              of: audioTrack, at: insertTime)
                appendLog("[VideoService] segment \(i): audio inserted OK")
            } catch {
                appendLog("[VideoService] segment \(i): audio insert failed: \(error)")
                throw error
            }
            insertTime = CMTimeAdd(insertTime, audioDur)
        }

        appendLog("[VideoService] composition duration: \(CMTimeGetSeconds(composition.duration))s")

        guard composition.duration > .zero else {
            appendLog("[VideoService] composition is empty, aborting export")
            try? FileManager.default.removeItem(at: tempVideoURL)
            return
        }

        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        appendLog("[VideoService] compatible presets: \(compatiblePresets)")
        let preferredPresets = [
            AVAssetExportPresetHEVC1920x1080,
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetLowQuality
        ]
        guard let chosenPreset = preferredPresets.first(where: { compatiblePresets.contains($0) }),
              let exporter = AVAssetExportSession(asset: composition, presetName: chosenPreset)
        else {
            appendLog("[VideoService] no compatible export preset found")
            try? FileManager.default.removeItem(at: tempVideoURL)
            throw VideoProcessingError.exportFailed
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        appendLog("[VideoService] starting export with preset \(chosenPreset) to \(outputURL.lastPathComponent)")
        await exporter.export()
        appendLog("[VideoService] export status: \(exporter.status.rawValue), error: \(exporter.error?.localizedDescription ?? "none")")
        try? FileManager.default.removeItem(at: tempVideoURL)
        if let error = exporter.error { throw error }
        appendLog("[VideoService] export complete, file exists: \(FileManager.default.fileExists(atPath: outputURL.path))")
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        videoRecordingStartDate = Date()
        didStartRecordingFired = true
        appendLog("[VideoService] didStartRecordingTo: \(fileURL.lastPathComponent), videoRecordingStartDate set")
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // AVFoundation fires this delegate with AVErrorRecordingSuccessfullyFinished even on
        // a clean stop — it's not a real error. Only treat it as failure for other error codes.
        let nsError = error as NSError?
        let successfullyFinished = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        let isSuccess = error == nil || successfullyFinished
        let errCodeStr = nsError.map { "domain=\($0.domain) code=\($0.code)" } ?? "no-error"
        appendLog("[VideoService] didFinishRecordingTo: \(outputFileURL.lastPathComponent), error: \(error?.localizedDescription ?? "none") [\(errCodeStr)], isSuccess: \(isSuccess), didStartFired=\(didStartRecordingFired)")
        appendLog("[VideoService] output file exists: \(FileManager.default.fileExists(atPath: outputFileURL.path))")

        // "Cannot Record" without ever firing didStartRecordingTo means the output rejected
        // the start. AVCaptureMovieFileOutput state seems to recover on its own after this
        // failed completion — retrying immediately on the same output works in practice.
        let rejectedAtStart = !isSuccess && !didStartRecordingFired
        if rejectedAtStart, let movieOut = movieOutput, let originalURL = currentRecordingURL,
           startRecordingRetryCount < Self.maxStartRecordingRetries {
            startRecordingRetryCount += 1
            let attempt = startRecordingRetryCount
            appendLog("[VideoService] retrying startRecording (attempt \(attempt)/\(Self.maxStartRecordingRetries)) for \(originalURL.lastPathComponent)")
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                guard !movieOut.isRecording else {
                    appendLog("[VideoService] retry: output already recording, skipping retry")
                    return
                }
                guard self.captureSession.isRunning, !self.captureSession.isInterrupted else {
                    appendLog("[VideoService] retry: session not recordable, giving up")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        recordingFinishedContinuation?.resume(returning: nil)
                        recordingFinishedContinuation = nil
                    }
                    return
                }
                self.didStartRecordingFired = false
                movieOut.startRecording(to: originalURL, recordingDelegate: self)
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // If no one is awaiting the result (e.g., RecorderViewModel cancelled the
            // session because audio was too short), the file is orphaned. Delete it so
            // temp files don't accumulate in the app's Documents directory.
            if recordingFinishedContinuation == nil,
               FileManager.default.fileExists(atPath: outputFileURL.path) {
                try? FileManager.default.removeItem(at: outputFileURL)
                appendLog("[VideoService] removed orphan temp video \(outputFileURL.lastPathComponent)")
            }
            recordingFinishedContinuation?.resume(returning: isSuccess ? outputFileURL : nil)
            recordingFinishedContinuation = nil
        }
    }
}
