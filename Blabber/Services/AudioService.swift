import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis

struct VADConfiguration {
    var speechThresholdDB: Float = -45.0
    var speechOnsetDuration: TimeInterval = 0.05
    var silenceDuration: TimeInterval = 1.0
    var prerollDuration: TimeInterval = 5.0
    var speechConfidenceThreshold: Float = 0.2
    var detectingTimeout: TimeInterval = 2.0
    var detectingSilenceTimeout: TimeInterval = 1.5
}

private final class SpeechObserver: NSObject, SNResultsObserving {
    var onConfidence: (Float) -> Void
    init(_ handler: @escaping (Float) -> Void) { onConfidence = handler }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult,
              let cls = r.classification(forIdentifier: "speech") else { return }
        onConfidence(Float(cls.confidence))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
}

@MainActor
final class AudioService: NSObject, ObservableObject {
    static let shared = AudioService()

    @Published var currentLevel: Float = 0.0
    @Published var state: RecordingState = .idle
    @Published var errorMessage: String?
    @Published var hasSpeech: Bool = false

    var vadConfig = VADConfiguration()

    private let engine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { engine.inputNode }

    private var audioFile: AVAudioFile?
    private var outputURL: URL?

    // VAD state — accessed from audio tap thread; use nonisolated(unsafe) + lock
    private let vadLock = NSLock()
    private nonisolated(unsafe) var tapState: RecordingState = .idle
    private nonisolated(unsafe) var speechOnsetStart: Date?
    private nonisolated(unsafe) var lastSpeechTime: Date = .distantPast
    private nonisolated(unsafe) var prerollBuffer: [(AVAudioPCMBuffer, AVAudioTime)] = []
    private nonisolated(unsafe) var prerollAccumulatedFrames: AVAudioFrameCount = 0
    private nonisolated(unsafe) var prerollMaxFrames: AVAudioFrameCount = 0
    private nonisolated(unsafe) var writtenFrames: Int64 = 0
    private nonisolated(unsafe) var speechConfidence: Float = 0.0
    private nonisolated(unsafe) var detectingStart: Date?
    private nonisolated(unsafe) var detectingSilenceStart: Date?
    private nonisolated(unsafe) var speakingSegments: [SpeakingSegment] = []
    var recordingSampleRate: Double = 44100.0

    // SoundAnalysis
    private var soundAnalyzer: SNAudioStreamAnalyzer?
    private var speechObserver: SpeechObserver?
    private let analysisQueue = DispatchQueue(label: "com.blabber.soundanalysis", qos: .userInitiated)

    private override init() { super.init() }

    // MARK: - Session Lifecycle

    func startSession(outputURL: URL) throws {
        self.outputURL = outputURL

        try configureAudioSession()
        try setupEngine(outputURL: outputURL)

        writtenFrames = 0
        updateThreadState(.listening)
        state = .listening

        try engine.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    func pauseSession() {
        guard state == .listening || state == .detecting || state == .speaking else { return }
        engine.pause()
        updateThreadState(.paused)
        state = .paused
    }

    func resumeSession() {
        guard state == .paused else { return }
        do {
            try engine.start()
            updateThreadState(.listening)
            state = .listening
        } catch {
            errorMessage = "Failed to resume: \(error.localizedDescription)"
        }
    }

    func endSession() -> (TimeInterval, [SpeakingSegment]) {
        engine.stop()
        inputNode.removeTap(onBus: 0)

        let sampleRate = recordingSampleRate
        let frames = writtenFrames
        audioFile = nil

        if !speakingSegments.isEmpty && speakingSegments[speakingSegments.count - 1].end == nil {
            speakingSegments[speakingSegments.count - 1].end = Date()
            speakingSegments[speakingSegments.count - 1].audioEndFrame = frames
        }
        let segments = speakingSegments

        analysisQueue.sync { self.soundAnalyzer = nil }
        speechObserver = nil

        teardownAudioSession()
        resetVADState()
        updateThreadState(.idle)
        state = .idle

        NotificationCenter.default.removeObserver(self)

        return (sampleRate > 0 ? Double(frames) / sampleRate : 0, segments)
    }

    func cancelSession() {
        let url = outputURL
        _ = endSession()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    private func teardownAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Engine Setup

    private func setupEngine(outputURL: URL) throws {
        inputNode.removeTap(onBus: 0)

        // Voice processing enables AGC, noise suppression, and acoustic echo cancellation.
        // Must be set before installing the tap so the input format reflects the processed signal.
        try inputNode.setVoiceProcessingEnabled(true)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 44100.0
        recordingSampleRate = sampleRate

        prerollMaxFrames = AVAudioFrameCount(vadConfig.prerollDuration * sampleRate)
        prerollBuffer = []
        prerollAccumulatedFrames = 0

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        audioFile = try AVAudioFile(forWriting: outputURL, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processTapBuffer(buffer, time: time)
        }

        setupSoundAnalysis(format: inputFormat)
    }

    private func setupSoundAnalysis(format: AVAudioFormat) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            do {
                let analyzer = SNAudioStreamAnalyzer(format: format)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.overlapFactor = 0.9
                let observer = SpeechObserver { [weak self] confidence in
                    guard let self else { return }
                    self.vadLock.lock()
                    self.speechConfidence = confidence
                    self.vadLock.unlock()
                }
                try analyzer.add(request, withObserver: observer)
                self.soundAnalyzer = analyzer
                self.speechObserver = observer
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "SoundAnalysis unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - VAD Core (audio thread)

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let rms = computeRMS(buffer)
        let rmsDB = 20 * log10(max(rms, 1e-9))
        let normalized = min(1.0, max(0.0, (rmsDB + 60) / 60))

        DispatchQueue.main.async { [weak self] in
            self?.currentLevel = normalized
        }

        // Feed every buffer to SoundAnalysis (fire-and-forget)
        let sampleTime = time.sampleTime
        analysisQueue.async { [weak self] in
            self?.soundAnalyzer?.analyze(buffer, atAudioFramePosition: sampleTime)
        }

        let isSpeech = rmsDB > vadConfig.speechThresholdDB
        let now = Date()
        let currentState = readThreadState()

        switch currentState {
        case .idle, .paused:
            return

        case .listening:
            appendToPreroll(buffer, time: time)
            if isSpeech {
                if speechOnsetStart == nil {
                    speechOnsetStart = now
                } else if now.timeIntervalSince(speechOnsetStart!) >= vadConfig.speechOnsetDuration {
                    updateThreadState(.detecting)
                    detectingStart = now
                    speechOnsetStart = nil
                    DispatchQueue.main.async { [weak self] in self?.state = .detecting }
                }
            } else {
                speechOnsetStart = nil
            }

        case .detecting:
            appendToPreroll(buffer, time: time)
            vadLock.lock()
            let confidence = speechConfidence
            vadLock.unlock()
            let elapsed = detectingStart.map { now.timeIntervalSince($0) } ?? 0

            if isSpeech {
                detectingSilenceStart = nil
            } else if detectingSilenceStart == nil {
                detectingSilenceStart = now
            }
            let silentFor = detectingSilenceStart.map { now.timeIntervalSince($0) } ?? 0

            if confidence >= vadConfig.speechConfidenceThreshold {
                updateThreadState(.speaking)
                let prerollSec = recordingSampleRate > 0 ? Double(prerollAccumulatedFrames) / recordingSampleRate : 0
                speakingSegments.append(SpeakingSegment(
                    videoStart: Date(timeIntervalSinceNow: -prerollSec),
                    audioStartFrame: writtenFrames
                ))
                flushPreroll()
                lastSpeechTime = now
                detectingStart = nil
                detectingSilenceStart = nil
                DispatchQueue.main.async { [weak self] in
                    self?.state = .speaking
                    self?.hasSpeech = true
                }
            } else if silentFor > vadConfig.detectingSilenceTimeout || elapsed > vadConfig.detectingTimeout {
                updateThreadState(.listening)
                prerollBuffer = []
                prerollAccumulatedFrames = 0
                detectingStart = nil
                detectingSilenceStart = nil
                DispatchQueue.main.async { [weak self] in self?.state = .listening }
            }

        case .speaking:
            writeBuffer(buffer)
            if isSpeech {
                lastSpeechTime = now
            } else {
                if now.timeIntervalSince(lastSpeechTime) >= vadConfig.silenceDuration {
                    if !speakingSegments.isEmpty && speakingSegments[speakingSegments.count - 1].end == nil {
                        speakingSegments[speakingSegments.count - 1].end = now
                        speakingSegments[speakingSegments.count - 1].audioEndFrame = writtenFrames
                    }
                    updateThreadState(.listening)
                    prerollBuffer = []
                    prerollAccumulatedFrames = 0
                    speechOnsetStart = nil
                    DispatchQueue.main.async { [weak self] in self?.state = .listening }
                }
            }
        }
    }

    // MARK: - Preroll Ring Buffer

    private func appendToPreroll(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        prerollBuffer.append((buffer, time))
        prerollAccumulatedFrames += buffer.frameLength

        while prerollAccumulatedFrames > prerollMaxFrames, !prerollBuffer.isEmpty {
            let dropped = prerollBuffer.removeFirst()
            prerollAccumulatedFrames -= dropped.0.frameLength
        }
    }

    private func flushPreroll() {
        for (buf, _) in prerollBuffer {
            writeBuffer(buf)
        }
        prerollBuffer = []
        prerollAccumulatedFrames = 0
    }

    // MARK: - File Writing

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        do {
            try file.write(from: buffer)
            writtenFrames += Int64(buffer.frameLength)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Write error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - RMS

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return 0 }
        var sumSquares: Float = 0
        vDSP_svesq(channelData, 1, &sumSquares, vDSP_Length(buffer.frameLength))
        return sqrt(sumSquares / Float(buffer.frameLength))
    }

    // MARK: - Thread-safe state accessors

    private func readThreadState() -> RecordingState {
        vadLock.lock()
        defer { vadLock.unlock() }
        return tapState
    }

    private func updateThreadState(_ newState: RecordingState) {
        vadLock.lock()
        tapState = newState
        vadLock.unlock()
    }

    private func resetVADState() {
        speechOnsetStart = nil
        lastSpeechTime = .distantPast
        prerollBuffer = []
        prerollAccumulatedFrames = 0
        writtenFrames = 0
        hasSpeech = false
        speechConfidence = 0.0
        detectingStart = nil
        detectingSilenceStart = nil
        speakingSegments = []
    }

    // MARK: - Interruption / Route Change

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        Task { @MainActor in
            switch type {
            case .began:
                if self.state == .listening || self.state == .detecting || self.state == .speaking {
                    self.pauseSession()
                }
            case .ended:
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    self.resumeSession()
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        Task { @MainActor in
            if reason == .oldDeviceUnavailable,
               self.state == .listening || self.state == .detecting || self.state == .speaking {
                self.pauseSession()
            }
        }
    }
}
