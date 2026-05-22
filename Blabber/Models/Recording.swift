import Foundation

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let date: Date
    var duration: TimeInterval
    let filename: String
    var hasVideo: Bool = false
    var isProcessing: Bool = false

    var fileURL: URL {
        StorageService.shared.mediaDirectory.appendingPathComponent(filename)
    }

    var videoFilename: String { "rec-\(id.uuidString).mp4" }

    var videoFileURL: URL {
        StorageService.shared.mediaDirectory.appendingPathComponent(videoFilename)
    }
}
