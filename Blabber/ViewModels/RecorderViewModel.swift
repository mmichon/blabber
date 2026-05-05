import Foundation
import Combine

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var audioLevel: Float = 0.0
    @Published var errorMessage: String?
    @Published var sessionTitle: String = "New Recording"
    @Published var hasSpeech: Bool = false
    @Published var sensitivityThreshold: Float = -45.0

    private let audioService = AudioService.shared
    private let locationService = LocationService.shared
    private let storageService = StorageService.shared

    private var currentRecordingID: UUID?
    private var currentTempURL: URL?
    private var sessionStartDate: Date?

    private var cancellables = Set<AnyCancellable>()

    init() {
        audioService.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$state)

        audioService.$currentLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        audioService.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        audioService.$hasSpeech
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasSpeech)

        $sensitivityThreshold
            .sink { [weak self] value in
                self?.audioService.vadConfig.speechThresholdDB = value
            }
            .store(in: &cancellables)
        audioService.vadConfig.speechThresholdDB = sensitivityThreshold
    }

    // MARK: - Actions

    func startSession() {
        guard state == .idle else { return }
        let id = UUID()
        let url = storageService.newTempAudioURL()
        currentRecordingID = id
        currentTempURL = url
        sessionStartDate = Date()
        sessionTitle = "New Recording"

        Task {
            sessionTitle = await locationService.fetchLocationTitle()
        }

        do {
            try audioService.startSession(outputURL: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        switch state {
        case .listening, .detecting, .speaking:
            audioService.pauseSession()
        case .paused:
            audioService.resumeSession()
        case .idle:
            break
        }
    }

    func endSession() {
        guard let id = currentRecordingID, let tempURL = currentTempURL else { return }

        let duration = audioService.endSession()

        guard duration > 0.5 else {
            try? FileManager.default.removeItem(at: tempURL)
            currentRecordingID = nil
            currentTempURL = nil
            return
        }

        let finalURL = storageService.finalAudioURL(for: id)
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return
        }

        let recording = Recording(
            id: id,
            title: sessionTitle,
            date: sessionStartDate ?? Date(),
            duration: duration,
            filename: "rec-\(id.uuidString).m4a"
        )
        storageService.addRecording(recording)
        currentRecordingID = nil
        currentTempURL = nil
    }

    func cancelSession() {
        audioService.cancelSession()
        currentRecordingID = nil
        currentTempURL = nil
    }

    // MARK: - Computed helpers

    var isActive: Bool { state != .idle }

    var startPauseIcon: String {
        switch state {
        case .idle:                          return "play.fill"
        case .listening, .detecting, .speaking: return "pause.fill"
        case .paused:                        return "play.fill"
        }
    }

    var statusText: String {
        switch state {
        case .idle:       return "Tap to start recording"
        case .listening:  return "Listening..."
        case .detecting:  return "Identifying..."
        case .speaking:   return "Recording speech..."
        case .paused:     return "Paused"
        }
    }
}
