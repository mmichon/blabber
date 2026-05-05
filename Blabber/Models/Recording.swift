import Foundation

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let date: Date
    var duration: TimeInterval
    let filename: String

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }
}
