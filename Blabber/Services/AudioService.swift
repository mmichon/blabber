import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis
import os

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

    static let log = Logger(subsystem: "com.mmichon.blabber", category: "audio")

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

        Self.log.notice("startSession begin url=\(outputURL.lastPathComponent, privacy: .public)")
        dumpAudioState(label: "startSession entry")

        do {
            try configureAudioSession()
        } catch {
            Self.log.error("configureAudioSession threw: \(Self.describe(error), privacy: .public)")
            dumpAudioState(label: "configureAudioSession failure")
            throw Self.userFacingError(stage: "configuring audio session", underlying: error)
        }

        do {
            try setupEngine(outputURL: outputURL)
        } catch {
            Self.log.error("setupEngine threw: \(Self.describe(error), privacy: .public)")
            dumpAudioState(label: "setupEngine failure")
            throw Self.userFacingError(stage: "setting up the recorder", underlying: error)
        }

        writtenFrames = 0
        updateThreadState(.listening)
        state = .listening

        do {
            try engine.start()
            Self.log.notice("engine.start succeeded")
        } catch {
            Self.log.error("engine.start threw: \(Self.describe(error), privacy: .public)")
            dumpAudioState(label: "engine.start failure")
            throw Self.userFacingError(stage: "starting the audio engine", underlying: error)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil
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

        let carPlay = Self.isCarPlayActive(session: session)
        Self.log.notice("configureAudioSession carPlay=\(carPlay, privacy: .public) route=\(Self.routeSummary(session: session), privacy: .public)")

        // voiceChat tries to force the route to HFP (mono telephony). When CarPlay owns the
        // audio route this conflicts and the input node ends up with no valid format,
        // causing engine.start() to fail with the AVAudioEngine '!dat' error (560226676).
        // Use .default under CarPlay; keep voiceChat (echo cancellation tuning) otherwise.
        let mode: AVAudioSession.Mode = carPlay ? .default : .voiceChat

        // .defaultToSpeaker forces output to the iPhone speaker — incompatible with CarPlay
        // holding the output route. .mixWithOthers keeps the car's music/maps audio playing
        // when we activate the session.
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        if !carPlay {
            options.insert(.defaultToSpeaker)
        }

        Self.log.notice("setCategory playAndRecord mode=\(mode.rawValue, privacy: .public) options=\(options.rawValue)")
        try session.setCategory(.playAndRecord, mode: mode, options: options)

        // Force the built-in mic. CarPlay sometimes advertises the car's mic as an input,
        // but the car's mic doesn't always deliver a format compatible with voice processing.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            do {
                try session.setPreferredInput(builtIn)
                Self.log.info("Preferred input set to builtInMic")
            } catch {
                Self.log.warning("setPreferredInput failed: \(Self.describe(error), privacy: .public)")
            }
        } else {
            Self.log.warning("No builtInMic in availableInputs=\(session.availableInputs?.map(\.portName) ?? [], privacy: .public)")
        }

        try session.setActive(true)
        Self.log.notice("Audio session active. sr=\(session.sampleRate) ioBuf=\(session.ioBufferDuration)")
    }

    private func teardownAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Engine Setup

    private func setupEngine(outputURL: URL) throws {
        inputNode.removeTap(onBus: 0)

        // Wireless CarPlay can return 0ch/0Hz immediately after setActive(true); the route
        // takes a beat to propagate. Poll briefly so we don't try to toggle VPIO or install
        // a tap against a not-yet-ready input.
        let preFmt = waitForUsableInputFormat(timeout: 0.5)
        Self.log.notice("input format pre-VP: sr=\(preFmt.sampleRate) ch=\(preFmt.channelCount)")

        // Voice processing enables AGC, noise suppression, and acoustic echo cancellation.
        // Must be set before installing the tap so the input format reflects the processed signal.
        // It can fail when the current route doesn't support it (some CarPlay configurations).
        // Fall back to plain input rather than aborting the recording.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            Self.log.info("Voice processing enabled")
        } catch {
            Self.log.warning("setVoiceProcessingEnabled(true) failed, continuing without it: \(Self.describe(error), privacy: .public)")
        }

        // Toggling VPIO rebuilds the input audio unit asynchronously; wait for the new
        // format to settle before reading it.
        let inputFormat = waitForUsableInputFormat(timeout: 0.5)
        Self.log.notice("input format post-VP: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) vpEnabled=\(self.inputNode.isVoiceProcessingEnabled)")

        // A zero-channel / zero-Hz input format means the route isn't actually delivering
        // input data. Installing a tap and calling engine.start() on this will fail with
        // the AVAudioEngine '!dat' error. Refuse with a readable message instead.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            Self.log.error("Input format invalid (ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)). Aborting.")
            throw NSError(domain: "Blabber.AudioService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Microphone input isn't available in the current audio route (\(Self.routeSummary())). Try disconnecting CarPlay briefly, or switch the car to Bluetooth-only."
            ])
        }

        let sampleRate = inputFormat.sampleRate
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

        Self.log.info("routeChange reason=\(reasonValue) route=\(Self.routeSummary(), privacy: .public)")

        Task { @MainActor in
            if reason == .oldDeviceUnavailable,
               self.state == .listening || self.state == .detecting || self.state == .speaking {
                self.pauseSession()
            }
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        // The audio server died and was restarted. AVAudioEngine and AVAudioSession are
        // both invalid. Surface this so we can see it in logs and pause the session.
        Self.log.error("mediaServicesWereReset received — engine and session are invalid")
        Task { @MainActor in
            if self.state != .idle {
                self.pauseSession()
                self.errorMessage = "Audio system was reset by iOS. Tap pause/play to restart."
            }
        }
    }

    /// Poll inputNode.outputFormat until channelCount and sampleRate are both non-zero,
    /// or the timeout fires. Returns the latest format read regardless — the caller decides
    /// how to handle an invalid format.
    private func waitForUsableInputFormat(timeout: TimeInterval) -> AVAudioFormat {
        let deadline = Date().addingTimeInterval(timeout)
        var fmt = inputNode.outputFormat(forBus: 0)
        var attempts = 0
        while (fmt.channelCount == 0 || fmt.sampleRate == 0) && Date() < deadline {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.05)
            fmt = inputNode.outputFormat(forBus: 0)
        }
        if attempts > 0 {
            Self.log.info("waitForUsableInputFormat settled after \(attempts) retries: sr=\(fmt.sampleRate) ch=\(fmt.channelCount)")
        }
        return fmt
    }

    // MARK: - Diagnostics

    /// Decode an Error as "<domain> code <n> ('<fourCharCode>'): <description>".
    /// CoreAudio errors are positive 32-bit integers whose bytes spell a 4-char tag.
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let code = ns.code
        var fcc = ""
        // Heuristic: printable-ASCII four-char codes typically fall in this range.
        if code > 0x20000000, code <= 0x7FFFFFFF {
            var v = UInt32(code)
            var bytes = [UInt8]()
            for _ in 0..<4 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            if bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
               let s = String(bytes: bytes, encoding: .ascii) {
                fcc = " ('\(s)')"
            }
        }
        return "\(ns.domain) code \(code)\(fcc): \(ns.localizedDescription)"
    }

    /// Wrap an underlying error with a human-readable `localizedDescription` so the alert
    /// shown by `RecorderViewModel` (which uses `error.localizedDescription`) is actionable
    /// instead of "(com.apple.coreaudio.avfaudio error 560226676.)".
    nonisolated static func userFacingError(stage: String, underlying: Error) -> NSError {
        let ns = underlying as NSError
        let route = routeSummary()
        let detail = describe(underlying)
        let hint: String
        if isCarPlayActive() {
            hint = " CarPlay is connected (\(route)) — try unplugging CarPlay or switching the car to Bluetooth-only and retry."
        } else {
            hint = " Route: \(route)"
        }
        let message = "Couldn't start recording (failed while \(stage)). \(detail).\(hint)"
        return NSError(domain: "Blabber.AudioService", code: ns.code, userInfo: [
            NSLocalizedDescriptionKey: message,
            NSUnderlyingErrorKey: underlying
        ])
    }

    nonisolated static func isCarPlayActive(session: AVAudioSession = .sharedInstance()) -> Bool {
        let route = session.currentRoute
        return route.outputs.contains { $0.portType == .carAudio }
            || route.inputs.contains { $0.portType == .carAudio }
    }

    nonisolated static func routeSummary(session: AVAudioSession = .sharedInstance()) -> String {
        let route = session.currentRoute
        let outs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let ins = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "out=[\(outs)] in=[\(ins)]"
    }

    private func dumpAudioState(label: String) {
        let session = AVAudioSession.sharedInstance()
        Self.log.notice("[\(label, privacy: .public)] cat=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) opts=\(session.categoryOptions.rawValue) sr=\(session.sampleRate) ioBuf=\(session.ioBufferDuration) route=\(Self.routeSummary(session: session), privacy: .public) preferredInput=\(session.preferredInput?.portName ?? "<nil>", privacy: .public)")
        let fmt = inputNode.outputFormat(forBus: 0)
        Self.log.notice("[\(label, privacy: .public)] inputNode: sr=\(fmt.sampleRate) ch=\(fmt.channelCount) commonFmt=\(fmt.commonFormat.rawValue) vp=\(self.inputNode.isVoiceProcessingEnabled) engineRunning=\(self.engine.isRunning)")
    }
}
