import Foundation

final class StorageService {
    static let shared = StorageService()

    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        indexURL = docs.appendingPathComponent("recordings.json")
        clearStuckProcessingFlags()
    }

    private func clearStuckProcessingFlags() {
        var all = loadRecordings()
        guard all.contains(where: { $0.isProcessing }) else { return }
        for i in all.indices { all[i].isProcessing = false }
        saveRecordings(all)
    }

    func loadRecordings() -> [Recording] {
        guard let data = try? Data(contentsOf: indexURL),
              let recordings = try? JSONDecoder().decode([Recording].self, from: data)
        else { return [] }
        return recordings.sorted { $0.date > $1.date }
    }

    func saveRecordings(_ recordings: [Recording]) {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func addRecording(_ recording: Recording) {
        var all = loadRecordings()
        all.insert(recording, at: 0)
        saveRecordings(all)
        NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        if recording.hasVideo {
            try? FileManager.default.removeItem(at: recording.videoFileURL)
        }
        var all = loadRecordings()
        all.removeAll { $0.id == recording.id }
        saveRecordings(all)
    }

    func updateRecordingHasVideo(id: UUID) {
        var all = loadRecordings()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].hasVideo = true
            saveRecordings(all)
            NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
        }
    }

    func updateRecordingProcessingDone(id: UUID) {
        var all = loadRecordings()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].isProcessing = false
            saveRecordings(all)
            NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
        }
    }

    func newTempAudioURL() -> URL {
        docsDir().appendingPathComponent("temp_\(UUID().uuidString).m4a")
    }

    func newTempVideoURL() -> URL {
        docsDir().appendingPathComponent("temp_video_\(UUID().uuidString).mp4")
    }

    func finalAudioURL(for id: UUID) -> URL {
        docsDir().appendingPathComponent("rec-\(id.uuidString).m4a")
    }

    func finalVideoURL(for id: UUID) -> URL {
        docsDir().appendingPathComponent("rec-\(id.uuidString).mp4")
    }

    private func docsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
