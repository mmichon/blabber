import Foundation

enum RecordingState: Equatable {
    case idle
    case listening
    case detecting
    case speaking
    case paused
}
