import Foundation

/// Which parts of the video and the external audio end up in the merged file.
public struct MergePlan: Sendable, Equatable {
    /// First kept video second.
    public var videoStart: Double
    /// Audio-file second that plays together with `videoStart`.
    public var audioStart: Double
    /// Length of the common interval.
    public var duration: Double

    public init(videoStart: Double, audioStart: Double, duration: Double) {
        self.videoStart = videoStart
        self.audioStart = audioStart
        self.duration = duration
    }
}

public enum MergePlanner {
    /// Trims both tracks to the interval where video and audio exist together.
    ///
    /// - Parameter offset: `audioTime - videoTime`, in seconds.
    /// - Returns: `nil` if the overlap is shorter than `minimumDuration`.
    public static func plan(
        video: ClosedRange<Double>,
        audio: ClosedRange<Double>,
        offset: Double,
        minimumDuration: Double = 0.5
    ) -> MergePlan? {
        let start = max(video.lowerBound, audio.lowerBound - offset)
        let end = min(video.upperBound, audio.upperBound - offset)
        guard end - start >= minimumDuration else { return nil }
        return MergePlan(videoStart: start, audioStart: start + offset, duration: end - start)
    }
}
