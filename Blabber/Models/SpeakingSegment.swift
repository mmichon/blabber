import Foundation

struct SpeakingSegment {
    let videoStart: Date      // wall-clock start of this segment in the video (includes preroll)
    let audioStartFrame: Int64 // frame offset in the audio file where this segment begins
    var end: Date?
    var audioEndFrame: Int64 = 0
}
