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
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    var videoFilename: String { "rec-\(id.uuidString).mp4" }

    var videoFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(videoFilename)
    }
}
