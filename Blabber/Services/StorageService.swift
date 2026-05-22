import Foundation

final class StorageService {
    static let shared = StorageService()

    private(set) var indexURL: URL
    private(set) var mediaDirectory: URL

    private let localDocsDir: URL
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [Any] = []

    private static let iCloudContainerID = "iCloud.com.mmichon.blabber"

    private init() {
        localDocsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        indexURL = localDocsDir.appendingPathComponent("recordings.json")
        mediaDirectory = localDocsDir
        clearStuckProcessingFlags()
        setupiCloud()
    }

    // MARK: - iCloud Setup

    private func setupiCloud() {
        Task.detached(priority: .utility) {
            guard let containerURL = FileManager.default.url(
                forUbiquityContainerIdentifier: Self.iCloudContainerID
            ) else { return }

            let docsURL = containerURL.appendingPathComponent("Documents")
            try? FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)

            await MainActor.run {
                self.switchToiCloud(docsURL: docsURL)
            }
        }
    }

    @MainActor
    private func switchToiCloud(docsURL: URL) {
        let recordings = loadRecordings()
        for recording in recordings {
            migrateFile(named: recording.filename, from: localDocsDir, to: docsURL)
            if recording.hasVideo {
                migrateFile(named: recording.videoFilename, from: localDocsDir, to: docsURL)
            }
        }

        let localIndex = localDocsDir.appendingPathComponent("recordings.json")
        let cloudIndex = docsURL.appendingPathComponent("recordings.json")
        if FileManager.default.fileExists(atPath: localIndex.path),
           !FileManager.default.fileExists(atPath: cloudIndex.path) {
            try? FileManager.default.moveItem(at: localIndex, to: cloudIndex)
        }

        mediaDirectory = docsURL
        indexURL = cloudIndex
        startMetadataQuery()
        NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
    }

    private func migrateFile(named filename: String, from src: URL, to dst: URL) {
        let srcURL = src.appendingPathComponent(filename)
        let dstURL = dst.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: srcURL.path),
              !FileManager.default.fileExists(atPath: dstURL.path) else { return }
        try? FileManager.default.moveItem(at: srcURL, to: dstURL)
    }

    // MARK: - NSMetadataQuery

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)

        let handleUpdate = { [weak self] in self?.handleMetadataQueryUpdate() }

        metadataObservers.append(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
            ) { _ in handleUpdate() }
        )
        metadataObservers.append(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in handleUpdate() }
        )

        metadataQuery = query
        query.start()
    }

    private func handleMetadataQueryUpdate() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var indexNeedsDownload = false
        var indexJustArrived = false
        var mediaFinishedDownloading = false

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }

            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let isCurrent = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
            let name = url.lastPathComponent

            if name == "recordings.json" {
                if isCurrent {
                    indexJustArrived = true
                } else {
                    indexNeedsDownload = true
                }
            } else if name.hasPrefix("rec-") && isCurrent {
                // A media file just finished downloading — let the list refresh so
                // the cloud icon clears and playback becomes available.
                mediaFinishedDownloading = true
            }
        }

        if indexNeedsDownload {
            guard let item = (0..<query.resultCount)
                .compactMap({ query.result(at: $0) as? NSMetadataItem })
                .first(where: { ($0.value(forAttribute: NSMetadataItemFSNameKey) as? String) == "recordings.json" }),
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { return }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        if indexJustArrived || mediaFinishedDownloading {
            NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
        }
    }

    // MARK: - Download on Demand

    func isAvailableLocally(_ recording: Recording) -> Bool {
        guard isURLAvailableLocally(recording.fileURL) else { return false }
        if recording.hasVideo {
            guard isURLAvailableLocally(recording.videoFileURL) else { return false }
        }
        return true
    }

    func isURLAvailableLocally(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values?.ubiquitousItemDownloadingStatus {
            return status == .current
        }
        return true
    }

    func requestDownload(_ recording: Recording) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: recording.fileURL)
        if recording.hasVideo {
            try? FileManager.default.startDownloadingUbiquitousItem(at: recording.videoFileURL)
        }
        NotificationCenter.default.post(name: .recordingDownloadRequested, object: recording.id)
    }

    // MARK: - CRUD

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

    // MARK: - URLs

    func newTempAudioURL() -> URL {
        localDocsDir.appendingPathComponent("temp_\(UUID().uuidString).m4a")
    }

    func newTempVideoURL() -> URL {
        localDocsDir.appendingPathComponent("temp_video_\(UUID().uuidString).mp4")
    }

    func finalAudioURL(for id: UUID) -> URL {
        mediaDirectory.appendingPathComponent("rec-\(id.uuidString).m4a")
    }

    func finalVideoURL(for id: UUID) -> URL {
        mediaDirectory.appendingPathComponent("rec-\(id.uuidString).mp4")
    }
}
