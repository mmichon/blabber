import Foundation

final class StorageService {
    static let shared = StorageService()

    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        indexURL = docs.appendingPathComponent("recordings.json")
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
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        var all = loadRecordings()
        all.removeAll { $0.id == recording.id }
        saveRecordings(all)
    }

    func newTempAudioURL() -> URL {
        docsDir().appendingPathComponent("temp_\(UUID().uuidString).m4a")
    }

    func finalAudioURL(for id: UUID) -> URL {
        docsDir().appendingPathComponent("rec-\(id.uuidString).m4a")
    }

    private func docsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
