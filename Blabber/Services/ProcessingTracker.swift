import Foundation

@MainActor
final class ProcessingTracker: ObservableObject {
    static let shared = ProcessingTracker()
    @Published var activeIDs: Set<UUID> = []
    private init() {}
}
